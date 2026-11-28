// SPDX-FileCopyrightText: 2026 CabinPlay.org
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
import Darwin
import UIKit
import VideoToolbox

final class VideoDecoder {
    /// 显示层。默认先自建一个占位层；预览视图出现时经 attachLayer 换成
    /// 视图的后备层（layerClass 托管，照 CarWithin 原版 H264Surface——
    /// 后备层的 frame 由 UIKit 布局自动跟随视图，游离层手写同步 frame
    /// 可能停在零尺寸：enqueue 全成功、层无报错、肉眼纯黑，见诊断 B1）。
    private(set) var layer = AVSampleBufferDisplayLayer()

    var onLog: ((String) -> Void)?
    /// 显示层丢帧、只能在新关键帧恢复时回调（上层接接收端 requestKeyFrame）。
    var onKeyframeNeeded: ((String) -> Void)?
    /// 第一个画面样本真正 enqueue 进显示层后回调（每次 reset 后重新计）。
    /// 上层据此置「已出画」——收到 AU 不算，送入显示层才算（原版口径）。
    var onFirstFrameEnqueued: (() -> Void)?

    /// 画中画内容源：当前托管的显示层（与 CarWithin 原版 H264Surface 的
    /// pictureInPictureLayer 同义）。预览视图已从界面移除、显示层在根层
    /// 离屏承接，画中画就以这一层为源头。
    var pictureInPictureLayer: AVSampleBufferDisplayLayer { layer }

    /// 画中画就绪判断（照原版 H264Surface 的条件组）：有格式、非等关键
    /// 帧、渲染器健康、层已挂进视图层级；17.4+ 再看 isReadyForDisplay，
    /// 更早系统以已入队首帧为准。
    var isReadyForPictureInPicture: Bool {
        guard format != nil, !awaitingKeyframe, !rendererNeedsRecovery,
              layer.superlayer != nil else { return false }
        if #available(iOS 17.4, *) { return layer.isReadyForDisplay }
        return hasEnqueuedFrame
    }

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

    // B2 定点日志：帧流计数（每个心跳周期汇总一次）与层状态心跳。
    private var statAppends = 0
    private var statEnqueues = 0
    private var statDrops = 0
    private var heartbeatTicks = 0
    private var heartbeat: Timer?
    private var lastHostGeometryLog = ""

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        observe(layer)
        // 内存告警让路：只清本机解码积压、只等新关键帧，会话与推流不动。
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    /// 系统内存告警：打一次足迹，然后清积压、等下一个关键帧。
    @objc private func memoryWarning() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logFootprint(reason: "系统内存告警")
            self.recover(reason: "系统内存告警")
        }
    }

    /// 每 10 秒（心跳第 5 拍）记一次常驻内存与解码积压。
    private func logFootprint(reason: String? = nil) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        let line = reason.map { "本机内存：" + $0 + "——" } ?? "本机内存："
        onLog?(line + "常驻 " + String(format: "%.1f", mb) + " MB，待入队 " + String(pending.count) + " 帧 / " + String(format: "%.1f", Double(pendingBytes) / 1_048_576) + " MB")
    }

    private func observe(_ target: AVSampleBufferDisplayLayer) {
        NotificationCenter.default.addObserver(self, selector: #selector(decodeFailed(_:)),
            name: .AVSampleBufferDisplayLayerFailedToDecode, object: target)
        NotificationCenter.default.addObserver(self, selector: #selector(rendererFlushChanged),
            name: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange, object: target)
    }

    /// 预览视图（后备层托管）出现时把它的显示层接管过来：之后的解码、
    /// 恢复、入队全走这一层。换层时旧层的失败监听摘掉、新层重挂。
    func attachLayer(_ newLayer: AVSampleBufferDisplayLayer) {
        guard newLayer !== layer else { return }
        NotificationCenter.default.removeObserver(self,
            name: .AVSampleBufferDisplayLayerFailedToDecode, object: layer)
        NotificationCenter.default.removeObserver(self,
            name: .AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange, object: layer)
        layer.stopRequestingMediaData()
        requesting = false
        layer = newLayer
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        layer.flushAndRemoveImage()
        observe(layer)
        onLog?("本机预览：显示层已改为预览视图的后备层托管（layerClass），frame \(Self.describe(layer.frame))，superlayer \(layer.superlayer != nil ? "在" : "不在")")
    }

    /// B2 托管几何日志：宿主视图 bounds 变化时才打，避免刷屏。
    func logHostGeometry(bounds: CGRect) {
        let line = "宿主视图 bounds \(Self.describe(bounds))，显示层 frame \(Self.describe(layer.frame))，superlayer \(layer.superlayer != nil ? "在" : "不在")"
        guard line != lastHostGeometryLog else { return }
        lastHostGeometryLog = line
        onLog?("本机预览：\(line)")
    }

    /// B2 窗口在场日志：宿主视图进/出窗口时打。
    func logHostWindow(_ inWindow: Bool) {
        onLog?("本机预览：宿主视图\(inWindow ? "已进入窗口" : "不在窗口里")（window \(inWindow ? "非空" : "为空")）")
    }

    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.width))×\(Int(rect.height))@(\(Int(rect.origin.x)),\(Int(rect.origin.y)))"
    }

    // MARK: B2 层状态心跳 + 帧流计数

    private func startHeartbeatIfNeeded() {
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.heartbeatTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
        statAppends = 0
        statEnqueues = 0
        statDrops = 0
        heartbeatTicks = 0
    }

    private func heartbeatTick() {
        guard format != nil else { return }
        heartbeatTicks += 1
        if heartbeatTicks % 5 == 0 { logFootprint() }
        let appends = statAppends, enqueues = statEnqueues, drops = statDrops
        statAppends = 0
        statEnqueues = 0
        statDrops = 0
        // isReadyForDisplay 是 iOS 17.4 才有的接口，低系统以已入队
        // 首帧为准（与 isReadyForPictureInPicture 同一口径）。最低
        // 系统降到 17.0（d8612e3）后这里漏包会编译不过，验收时补上。
        let layerReady: Bool
        if #available(iOS 17.4, *) {
            layerReady = layer.isReadyForDisplay
        } else {
            layerReady = hasEnqueuedFrame
        }
        // 帧流全静默且层自认在显示时不打，避免日志刷屏；其余情况都打。
        guard appends > 0 || drops > 0 || !layerReady else { return }
        onLog?("本机预览心跳：近 2 秒 append \(appends) 次、enqueue \(enqueues) 次、丢弃 \(drops) 次、待入队 \(pending.count) 帧 / \(String(format: "%.1f", Double(pendingBytes) / 1_048_576)) MB；层状态 status=\(layer.status.rawValue)\(layer.error.map { " error=\($0.localizedDescription)" } ?? "") isReadyForDisplay=\(layerReady) isReadyForMoreMediaData=\(layer.isReadyForMoreMediaData) 层 frame \(Self.describe(layer.frame))")
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
        statDrops += pending.count
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
        stopHeartbeat()
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
        statAppends += 1
        guard let units = try? AnnexB.units(in: annexB), !units.isEmpty else {
            statDrops += 1
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
            guard keyframe else { statDrops += 1; return }
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
            statEnqueues += 1
            if !hasEnqueuedFrame {
                hasEnqueuedFrame = true
                // B2 首帧样本信息：format 像素尺寸 + 样本字节数，排除尺寸为 0/错位。
                if let format {
                    let dims = CMVideoFormatDescriptionGetDimensions(format)
                    onLog?("本机预览：首个样本已入队显示层（format 尺寸 \(dims.width)×\(dims.height)，样本 \(bytes) 字节，层 frame \(Self.describe(layer.frame)))")
                }
                startHeartbeatIfNeeded()
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
