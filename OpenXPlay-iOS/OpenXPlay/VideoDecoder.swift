// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// VideoDecoder — turns the Annex-B NAL units the Rust core emits into
// CMSampleBuffers and hands them to AVSampleBufferDisplayLayer, which decodes
// H.264/HEVC itself. The decoder configuration (AVCDecoderConfigurationRecord
// or hvcC) arrives once per stream.
//
// 显示层的自愈机制照原版 H264Surface 移植（整合时曾被换成裸 enqueue，
// 失败全静默）：CarPlay 流全程只有开头一个关键帧，首帧样本一旦被显示层
// 拒收，后续 P 帧无参考帧可解、预览永久黑屏。因此必须：监听解码失败/
// 需 flush 通知 → flush 并置 awaitingKeyframe → 经 onKeyframeNeeded 让
// 接收端发 forceKeyFrame → 恢复期间只等 IDR、非关键帧一律丢弃；入队走
// requestMediaDataWhenReady 流控；每个失败点都打日志，不许静默。

import AVFoundation
import CoreMedia
import UIKit
import VideoToolbox

final class VideoDecoder {
    let layer = AVSampleBufferDisplayLayer()

    var onLog: ((String) -> Void)?
    /// 显示层丢帧、只能在新关键帧恢复时回调（上层接接收端 requestKeyFrame）。
    var onKeyframeNeeded: ((String) -> Void)?
    /// 第一个画面样本真正 enqueue 进显示层后回调（每次 reset 后重新计）。
    /// 上层据此置「已出画」——收到 AU 不算，送入显示层才算（原版口径）。
    var onFirstFrameEnqueued: (() -> Void)?

    private var format: CMVideoFormatDescription?
    private var codec: UInt32 = 1
    private var pending: [(CMSampleBuffer, Int)] = []
    private var pendingBytes = 0
    private var requesting = false
    private var hasEnqueuedFrame = false
    private var awaitingKeyframe = false
    private var lastRecovery = -Double.infinity
    private var checkingDisplaySince: TimeInterval?

    private var videoCodec: VideoCodec { codec == 2 ? .h265 : .h264 }
    private var rendererNeedsRecovery: Bool {
        layer.requiresFlushToResumeDecoding || layer.status == .failed
    }

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        NotificationCenter.default.addObserver(self, selector: #selector(decodeFailed(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode, object: layer)
        NotificationCenter.default.addObserver(self, selector: #selector(rendererFlushChanged),
            name: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange, object: layer)
    }

    @objc private func decodeFailed(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.format != nil, self.rendererNeedsRecovery,
                  ProcessInfo.processInfo.systemUptime - self.lastRecovery >= 0.5 else { return }
            let error = note.userInfo?[AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey] as? NSError
            self.recover(reason: "本机解码失败\(error.map { "（\($0.code)）" } ?? "")")
        }
    }

    @objc private func rendererFlushChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.format != nil, self.layer.requiresFlushToResumeDecoding,
                  ProcessInfo.processInfo.systemUptime - self.lastRecovery >= 0.5 else { return }
            self.recover(reason: "系统要求恢复视频解码")
        }
    }

    /// 显示层恢复：清积压、flush、只等新关键帧，并向上层要关键帧。
    private func recover(reason: String) {
        layer.stopRequestingMediaData(); requesting = false
        pending.removeAll(); pendingBytes = 0
        layer.flush()
        hasEnqueuedFrame = false
        checkingDisplaySince = nil
        lastRecovery = ProcessInfo.processInfo.systemUptime
        if !awaitingKeyframe {
            onLog?("本机预览：视频渲染器将在下一个关键帧恢复：\(reason)")
        }
        awaitingKeyframe = true
        onKeyframeNeeded?(reason)
    }

    func reset() {
        checkingDisplaySince = nil
        lastRecovery = -.infinity
        layer.stopRequestingMediaData(); requesting = false
        pending.removeAll(); pendingBytes = 0
        awaitingKeyframe = false
        hasEnqueuedFrame = false
        layer.flushAndRemoveImage()
        format = nil
    }

    func configure(codec: UInt32, config: Data) {
        self.codec = codec
        let newFormat = codec == 2 ? Self.hevcFormat(config) : Self.h264Format(config)
        guard let newFormat else {
            onLog?("本机预览：解码配置解析失败（\(codec == 2 ? "H.265" : "H.264")，\(config.count) 字节），等下一份配置")
            return
        }
        if format != nil {
            // 参数集变了：照原版清积压并 flush，旧 format 的样本不能再喂。
            layer.stopRequestingMediaData(); requesting = false
            pending.removeAll(); pendingBytes = 0
            layer.flush()
        }
        format = newFormat
    }

    func append(_ annexB: Data, ptsNanos: UInt64) {
        guard !annexB.isEmpty else { return }
        guard let units = try? AnnexB.units(in: annexB), !units.isEmpty else {
            onLog?("本机预览：收到拆不开的画面数据（\(annexB.count) 字节），已丢弃")
            return
        }
        let codecNow = videoCodec
        // 参数集只用于建 format（configure 已处理），不进样本（照原版剥法）。
        let picture = units.filter { codecNow.parameterSet($0) == nil }
        guard !picture.isEmpty else { return }
        guard let format else {
            if !awaitingKeyframe {
                awaitingKeyframe = true
                onLog?("本机预览：画面帧先于解码配置到达，已请求关键帧，等配置和 IDR")
                onKeyframeNeeded?("缺少参数集")
            }
            return
        }
        let keyframe = picture.contains { codecNow.isRandomAccess($0) }
        let now = ProcessInfo.processInfo.systemUptime
        if rendererNeedsRecovery {
            guard now - lastRecovery >= 0.5 else { return }
            recover(reason: "显示层需要恢复：\(layer.error?.localizedDescription ?? "系统状态变化")")
            guard !rendererNeedsRecovery else { return }
        } else if pending.count >= 30 || pendingBytes > 16 * 1024 * 1024 {
            recover(reason: "显示积压 \(pending.count) 帧")
        } else if #available(iOS 17.4, *) {
            if layer.isReadyForDisplay {
                checkingDisplaySince = nil
            } else if hasEnqueuedFrame {
                let started = checkingDisplaySince ?? now
                checkingDisplaySince = started
                if now - started >= 1.5, now - lastRecovery >= 1.5 {
                    recover(reason: "收到视频帧后显示层仍未就绪")
                }
            }
        }
        if awaitingKeyframe {
            guard keyframe else { return }
            awaitingKeyframe = false
        }
        guard let bytes = try? AnnexB.lengthPrefixed(picture) else {
            onLog?("本机预览：画面帧拼装失败，已丢弃")
            return
        }

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            onLog?("本机预览：视频缓冲区分配失败（状态 \(status)），已丢弃一帧")
            return
        }
        let replaceStatus = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            onLog?("本机预览：视频缓冲区写入失败（状态 \(replaceStatus)），已丢弃一帧")
            return
        }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(ptsNanos), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [bytes.count],
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            onLog?("本机预览：视频样本创建失败，已丢弃一帧")
            return
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        pending.append((sample, bytes.count))
        pendingBytes += bytes.count
        if !requesting {
            requesting = true
            layer.requestMediaDataWhenReady(on: .main) { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        while layer.isReadyForMoreMediaData, !pending.isEmpty {
            let (sample, bytes) = pending.removeFirst()
            pendingBytes -= bytes
            layer.enqueue(sample)
            if !hasEnqueuedFrame {
                hasEnqueuedFrame = true
                onFirstFrameEnqueued?()
            }
        }
        if pending.isEmpty {
            layer.stopRequestingMediaData()
            requesting = false
        }
    }

    // MARK: - Format descriptions

    private static func h264Format(_ config: Data) -> CMVideoFormatDescription? {
        let bytes = [UInt8](config)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        var sets: [[UInt8]] = []
        var cursor = 5
        let spsCount = Int(bytes[cursor] & 0x1F)
        cursor += 1
        for _ in 0..<spsCount {
            guard cursor + 2 <= bytes.count else { break }
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
            guard length > 0, cursor + length <= bytes.count else { break }
            sets.append(Array(bytes[cursor..<cursor + length]))
            cursor += length
        }
        guard cursor < bytes.count else { return nil }
        let ppsCount = Int(bytes[cursor])
        cursor += 1
        for _ in 0..<ppsCount {
            guard cursor + 2 <= bytes.count else { break }
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
            guard length > 0, cursor + length <= bytes.count else { break }
            sets.append(Array(bytes[cursor..<cursor + length]))
            cursor += length
        }
        return makeH264Description(sets)
    }

    private static func makeH264Description(_ sets: [[UInt8]]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty else { return nil }
        var description: CMVideoFormatDescription?
        var pointers: [UnsafePointer<UInt8>] = []
        var lengths: [Int] = []
        var storage: [UnsafeMutablePointer<UInt8>] = []
        defer { storage.forEach { $0.deallocate() } }
        for set in sets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            buffer.initialize(from: set, count: set.count)
            storage.append(buffer)
            pointers.append(UnsafePointer(buffer))
            lengths.append(set.count)
        }
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            lengths.withUnsafeBufferPointer { lengthBuffer in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: lengthBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    private static func hevcFormat(_ config: Data) -> CMVideoFormatDescription? {
        // hvcC: 23-byte header, then arrays of parameter set NALs (VPS/SPS/PPS).
        let bytes = [UInt8](config)
        guard bytes.count > 23 else { return nil }
        var sets: [[UInt8]] = []
        var cursor = 23
        let arrayCount = Int(bytes[22])
        for _ in 0..<arrayCount {
            guard cursor + 3 <= bytes.count else { break }
            cursor += 1 // array_completeness + NAL unit type
            let count = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
            for _ in 0..<count {
                guard cursor + 2 <= bytes.count else { break }
                let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
                cursor += 2
                guard length > 0, cursor + length <= bytes.count else { break }
                sets.append(Array(bytes[cursor..<cursor + length]))
                cursor += length
            }
        }
        guard !sets.isEmpty else { return nil }
        var description: CMVideoFormatDescription?
        var pointers: [UnsafePointer<UInt8>] = []
        var lengths: [Int] = []
        var storage: [UnsafeMutablePointer<UInt8>] = []
        defer { storage.forEach { $0.deallocate() } }
        for set in sets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            buffer.initialize(from: set, count: set.count)
            storage.append(buffer)
            pointers.append(UnsafePointer(buffer))
            lengths.append(set.count)
        }
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            lengths.withUnsafeBufferPointer { lengthBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: lengthBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }
}
