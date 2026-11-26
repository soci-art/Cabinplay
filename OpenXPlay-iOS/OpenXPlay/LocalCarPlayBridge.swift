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

    func setFPS(_ value: Double) {
        queue.async { [weak self] in self?.fps = value }
    }

    /// CarLink 进入出画状态时：补推配置 + 请求关键帧；离开时复位计数。
    func setClinkPlaying(_ playing: Bool, requestKeyFrame: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.clinkPlaying = playing
            if playing {
                self.configPushed = false
                if let record = self.configRecord {
                    self.pushConfigNow(record)
                } else {
                    self.onLog?("帧桥：CarLink 已出画，但本机 CarPlay 的参数集还没凑齐，等帧到齐再推配置")
                }
                self.onLog?("帧桥：CarLink 已进入出画状态，已请求本机 CarPlay 吐关键帧")
                requestKeyFrame()
            } else {
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
            configRecord = record
            if clinkPlaying { pushConfigNow(record) }
        }
        guard clinkPlaying, configPushed else { return }
        let keyFrame = units.contains { codec.isRandomAccess($0) }
        if clockStart == nil { clockStart = DispatchTime.now() }
        let ptsMicros = Int64(DispatchTime.now().uptimeNanoseconds
                              - (clockStart?.uptimeNanoseconds ?? 0)) / 1000
        if CarLinkCore.shared.pushFrame(data, ptsMicros: ptsMicros, keyFrame: keyFrame) {
            pushedFrames += 1
            if pushedFrames == 1 {
                onLog?("帧桥：已向车机推送本机 CarPlay 首帧（\(data.count) 字节\(keyFrame ? "，关键帧" : "")）")
            } else if pushedFrames % 300 == 0 {
                onLog?("帧桥：已向车机推送第 \(pushedFrames) 帧")
            }
        }
    }

    private func pushConfigNow(_ record: Data) {
        let ok = CarLinkCore.shared.pushConfig(codec: currentCodec == .h265 ? 2 : 1,
                                               config: record, fps: fps)
        configPushed = ok
        onLog?(ok
            ? "帧桥：解码配置已推给车机（\(currentCodec.displayName)，\(record.count) 字节）"
            : "帧桥：解码配置推送没成功，等参数集变化或下次出画再推")
    }
}
