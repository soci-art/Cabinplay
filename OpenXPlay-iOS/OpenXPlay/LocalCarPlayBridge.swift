// SPDX-FileCopyrightText: 2026 OpenXPlay.org
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
    private var fps: Double = 30
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
        let keyFrame = units.contains { codec.isRandomAccess($0) }
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
}
