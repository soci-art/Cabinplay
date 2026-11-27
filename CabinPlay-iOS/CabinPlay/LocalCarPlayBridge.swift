// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// LocalCarPlayBridge — 帧桥：本机 CarPlay 会话（CarWithin 协议栈）的编码帧
// → CarLinkCore.pushConfig / pushFrame，送往车机。
//
// - 参数集（SPS/PPS/VPS）逐帧吸收，凑齐或变化时生成 avcC/hvcC 配置记录；
// - CarLink 没进入出画状态前，帧只吸收参数集、不推送也不积压；
// - 进入出画时先补推配置，再请源头吐一个关键帧，之后逐帧直推；
// - 会话帧没有时间戳，PTS 用单调时钟合成（微秒）。

import Foundation

final class LocalCarPlayBridge {
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "cabinplay.localcarplay.bridge")
    private var sets: VideoParameterSets?
    private var configRecord: Data?
    private var configPushed = false
    private var currentCodec: VideoCodec = .h264
    private var fps: Double = 60
    private var clinkPlaying = false
    private var pushedFrames = 0
    private var clockStart: DispatchTime?
    // 推送失败计数：以前 pushFrame 失败完全静默、pushConfig 失败后帧被
    // 闸门永久挡住，与车机侧「帧 0」对不上账。现在全部计数并打日志，
    // 配置没推成时随后续帧节流重试，不再一次失败永久停摆。
    private var configPushFailures = 0
    private var framePushFailures = 0
    private var ausSinceConfigAttempt = 0
    private var keyFrameRequester: (() -> Void)?

    func setFPS(_ value: Double) {
        queue.async { [weak self] in self?.fps = value }
    }

    /// CarLink 进入出画状态时：补推配置 + 请求关键帧；离开时复位计数。
    /// 状态回调可能重复送达 .playing，已在出画中就别再重推配置/重复
    /// 请求关键帧（会让车机画面反复闪关键帧）。
    func setClinkPlaying(_ playing: Bool, requestKeyFrame: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if playing {
                self.keyFrameRequester = requestKeyFrame
                guard !self.clinkPlaying else { return }
                self.clinkPlaying = true
                self.configPushed = false
                self.ausSinceConfigAttempt = 0
                if let record = self.configRecord {
                    self.pushConfigNow(record)
                } else {
                    self.onLog?("帧桥：CarLink 已出画，但本机 CarPlay 的参数集还没凑齐，等帧到齐再推配置")
                }
                self.onLog?("帧桥：CarLink 已进入出画状态，已请求本机 CarPlay 吐关键帧")
                requestKeyFrame()
            } else {
                self.clinkPlaying = false
                self.pushedFrames = 0
                self.clockStart = nil
                self.audioFormatKey = nil
                self.audioPacketsPushed = 0
                self.audioPushFailures = 0
                self.audioPacketsHeldBack = 0
                // 车机不再出画：声音回到本机（A2DP/扬声器）。
                CarPlayAudio.carPlaysAudio = false
            }
        }
    }

    /// 接收端队列直接调用；内部再转到桥自己的串行队列保序。
    func append(_ data: Data, codec: VideoCodec) {
        queue.async { [weak self] in self?.appendOnQueue(data, codec: codec) }
    }

    private func appendOnQueue(_ data: Data, codec: VideoCodec) {
        if sets == nil || sets?.codec != codec {
            sets = VideoParameterSets(codec: codec)
            currentCodec = codec
            configRecord = nil
            configPushed = false
        }
        // 快路径（帧桥解析瘦身，CARWITHIN-AUDIO-STUDY §6.4 第 3 条）：
        // 参数集已凑齐、配置记录已建好时，只做轻量头扫描取关键帧标
        // 记，不再每帧全量 AnnexB.units 拆包＋逐个 Data 分配——升 60
        // 帧后这笔 CPU 是翻倍的。夹带参数集的 AU（分辨率切换会换
        // SPS）与扫描拿不准的 AU 一律回落全量路径吸收，参数集变化
        // 不会被漏掉。
        let keyFrame: Bool
        if let current = sets, current.isComplete, configRecord != nil,
           let scan = AnnexB.scanHeaders(in: data, codec: codec), !scan.hasParameterSet {
            keyFrame = scan.isKeyFrame
        } else {
            guard let units = try? AnnexB.units(in: data) else { return }
            var current = sets ?? VideoParameterSets(codec: codec)
            var changed = false
            for unit in units where current.absorb(unit) { changed = true }
            sets = current
            if changed, current.isComplete,
               let record = try? current.decoderConfigurationRecord() {
                let isNewRecord = record != configRecord
                configRecord = record
                if clinkPlaying, isNewRecord {
                    pushConfigNow(record)
                    // 本机流在 CarLink 已出画之后才凑齐参数集：推完配置补请
                    // 一个关键帧，让车机从完整帧开始解（顺序兜底）。
                    if configPushed {
                        onLog?("帧桥：参数集在 CarLink 出画后才凑齐，配置已补推，再请求一个关键帧")
                        keyFrameRequester?()
                    }
                }
            }
            keyFrame = units.contains { codec.isRandomAccess($0) }
        }
        guard clinkPlaying else { return }
        // 配置还没推成：别让帧闸门永久关着——随帧流节流重试推配置。
        if !configPushed {
            ausSinceConfigAttempt += 1
            if let record = configRecord, ausSinceConfigAttempt >= 30 {
                ausSinceConfigAttempt = 0
                pushConfigNow(record)
            }
            guard configPushed else { return }
        }
        if clockStart == nil { clockStart = DispatchTime.now() }
        let ptsMicros = Int64(DispatchTime.now().uptimeNanoseconds
                              - (clockStart?.uptimeNanoseconds ?? 0)) / 1000
        if CarLinkCore.shared.pushFrame(data, ptsMicros: ptsMicros, keyFrame: keyFrame) {
            pushedFrames += 1
            if pushedFrames == 1 {
                onLog?("帧桥：已向车机推送本机 CarPlay 首帧（\(data.count) 字节\(keyFrame ? "，关键帧" : "")）")
            } else if pushedFrames % 300 == 0 {
                onLog?("帧桥：已向车机推送第 \(pushedFrames) 帧（累计推帧失败 \(framePushFailures) 次、推配置失败 \(configPushFailures) 次）")
            }
        } else {
            framePushFailures += 1
            if framePushFailures == 1 || framePushFailures % 300 == 0 {
                onLog?("帧桥：向车机推帧被拒（第 \(framePushFailures) 次）——核心没在出画状态或会话已断，帧数与 Carlink 统计对账看这里")
            }
        }
    }

    private func pushConfigNow(_ record: Data) {
        let ok = CarLinkCore.shared.pushConfig(codec: currentCodec == .h265 ? 2 : 1,
                                               config: record, fps: fps)
        configPushed = ok
        if ok {
            onLog?("帧桥：解码配置已推给车机（\(currentCodec.displayName)，\(record.count) 字节）")
        } else {
            configPushFailures += 1
            onLog?("帧桥：解码配置推送没成功（第 \(configPushFailures) 次），随后续帧继续重试，不再等参数集变化")
        }
    }

    // MARK: 音频桥（主流 AAC tap → 车机核心，与视频共用一条时间线）

    private var audioFormatKey: String?
    private var audioPacketsPushed = 0
    private var audioPushFailures = 0
    /// 车机还没进入出画状态时被静默门拦下的声音包数（以前完全静默，
    /// 日志里看不出声音到底来过没有，AUDIO-SILENT-DIFF 点名补上）。
    private var audioPacketsHeldBack = 0
    /// 非 AAC 包被桥放过的计数：以前是无声 return，若某轮主流建的
    /// 不是 AAC 流，日志里必须能看见这道门拦了多少、拦的是什么。
    private var audioPacketsNonAAC = 0

    /// 接收端 tap 到的主流 AAC 帧。hostMicros 是 CarPlayAudio 的
    /// browserTimestamp（主机开机单调时钟微秒），喂核心前必须换算到
    /// 视频帧共用的桥时间线（自 clockStart 起算的微秒）：核心用同一个
    /// offset 把音视频一起映射到传输时钟，两边 epoch 不一致声音会被
    /// 核心队列压住丢掉。本机扬声器播放是另一条路，这里只是多喂一份。
    func appendAudio(stream: Int, samples: Data, hostMicros: UInt64, format: ReceiverAudioFormat) {
        queue.async { [weak self] in
            guard let self else { return }
            // 非 AAC 的包不归这条桥（tap 只装在主流 AAC 实例上，这里
            // 只是双保险）：计数并节流打日志，不再无声放过；车机还没
            // 出画时拦下的 AAC 包同样计数打日志（AUDIO-SILENT-DIFF）。
            guard format.isAAC else {
                self.audioPacketsNonAAC += 1
                if self.audioPacketsNonAAC == 1 || self.audioPacketsNonAAC % 300 == 0 {
                    self.onLog?("音频桥：声音包不是 AAC 格式（\(format.name) \(format.sampleRate) Hz / \(format.channels) 声道），不归这条桥，已放过第 \(self.audioPacketsNonAAC) 个")
                }
                return
            }
            guard self.clinkPlaying else {
                self.audioPacketsHeldBack += 1
                if self.audioPacketsHeldBack == 1 || self.audioPacketsHeldBack % 300 == 0 {
                    self.onLog?("音频桥：车机还没进入出画状态，声音包先拦下（第 \(self.audioPacketsHeldBack) 个）——出画后开始往车机送")
                }
                return
            }
            if self.clockStart == nil { self.clockStart = DispatchTime.now() }
            let epochMicros = (self.clockStart?.uptimeNanoseconds ?? 0) / 1000
            let ptsMicros = max(0, Int64(hostMicros) - Int64(epochMicros))
            let key = "\(stream)/\(format.sampleRate)/\(format.channels)"
            if self.audioFormatKey != key {
                self.audioFormatKey = key
                // 解码 cookie 与 CarPlayAudio 解码器用的是同一组值；核心
                // 已放开采样率/声道门槛，cookie 只作记录用。
                let cookie = Data(format.sampleRate == 44100 ? [0x12, 0x10] : [0x11, 0x90])
                let ok = CarLinkCore.shared.pushAudioFormat(
                    stream: UInt32(stream), sampleRate: UInt32(format.sampleRate),
                    channels: UInt32(format.channels), config: cookie)
                onLog?("音频桥：主流声音格式已登记给车机核心（AAC-LC \(format.sampleRate) Hz / \(format.channels) 声道）；核心按这个采样率现算 ADTS 头")
                if !ok {
                    onLog?("音频桥：音频格式登记被拒（CarLink 没在跑？），后续声音包继续试")
                }
            }
            var pushCode = CarLinkCore.shared.pushAudioPacket(stream: UInt32(stream), data: samples, ptsMicros: ptsMicros)
            if pushCode == 1 {
                // 流与核心登记对不上：输入会话重置时核心会把格式
                // 登记整表清掉，而桥只在格式键变化时才登记一次，
                // 同格式的新流会被整批拦死（2026-11-27 12:02 日志：
                // 1296 个真音乐包全灭）。当场重新登记再重试这一包，
                // 后续包就又对得上了。
                let cookie = Data(format.sampleRate == 44100 ? [0x12, 0x10] : [0x11, 0x90])
                let reRegistered = CarLinkCore.shared.pushAudioFormat(
                    stream: UInt32(stream), sampleRate: UInt32(format.sampleRate),
                    channels: UInt32(format.channels), config: cookie)
                onLog?("音频桥：核心那边的格式登记被清掉了，已重新登记（流 \(stream)，AAC-LC \(format.sampleRate) Hz / \(format.channels) 声道），声音续上")
                if reRegistered {
                    pushCode = CarLinkCore.shared.pushAudioPacket(stream: UInt32(stream), data: samples, ptsMicros: ptsMicros)
                }
            }
            if pushCode == 0 {
                audioPacketsPushed += 1
                // 周期计数不在这里打了：改由核心侧按「真正写进 TS 发
                // 往车机的帧数」每 500 帧打一行「已向车机送出 N 个声音
                // 包」——那是更准的口径（这里数的只是核心收下入队的
                // 包），两边都打会重复刷屏。被拒计数仍看下面失败行。
                if audioPacketsPushed == 1 {
                    CarPlayAudio.carPlaysAudio = true
                    onLog?("音频桥：首个声音包已喂给车机核心（\(samples.count) 字节）——声音改由车机播放，本机不再起引擎")
                }
            } else {
                audioPushFailures += 1
                if audioPushFailures == 1 || audioPushFailures % 300 == 0 {
                    onLog?("音频桥：声音包被拒（第 \(audioPushFailures) 次）——核心没在出画状态或格式没登记上")
                }
            }
        }
    }
}
