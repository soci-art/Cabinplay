// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AVFoundation
import CryptoKit
import Darwin
import Network

private final class AudioDatagramPort {
    let port: UInt16
    private var source: DispatchSourceRead?
    var onPacket: ((Data) -> Void)?
    init(queue: DispatchQueue, peerAddress: String) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var receiveBuffer: Int32 = 512 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        var allowed = in_addr()
        guard inet_pton(AF_INET, peerAddress, &allowed) == 1 else { close(fd); throw ProtocolError.malformed(CWL("音频对端地址")) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw POSIXError(.EIO) }
        var count = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &count) } }
        guard named == 0 else { close(fd); throw POSIXError(.EIO) }
        port = UInt16(bigEndian: address.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue); self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Bound the work per dispatch so media cannot starve control traffic.
            var bytes = [UInt8](repeating: 0, count: 65536)
            for _ in 0..<32 {
                var peer = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let length = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, 65536, 0, $0, &size) } }
                guard length > 0 else { break }
                guard peer.sin_addr.s_addr == allowed.s_addr else { continue }
                self.onPacket?(Data(bytes.prefix(length)))
            }
        }
        source.setCancelHandler { close(fd) }; source.resume()
    }
    func stop() { source?.cancel(); source = nil; onPacket = nil }
    deinit { stop() }
}

final class CarPlayAudio {
    let dataPort: UInt16
    let controlPort: UInt16
    let format: ReceiverAudioFormat
    let connectionID: UInt64
    private let queue: DispatchQueue
    private let data: AudioDatagramPort
    private let control: AudioDatagramPort
    private let cipher: AudioStream
    // Construct the playback graph only when authenticated audio actually arrives. Creating
    // it during RTSP SETUP can block for seconds while iOS switches the CarPlay audio route.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let output: AVAudioFormat
    private let decoder: NativeAudioDecoder
    private var microphone: NativeMicrophone?
    private var queuedFrames = 0
    private var active = true
    private var playing = false
    private var rejected = 0
    private var firstTimestamp: UInt32?
    private var lastTimestamp: UInt32?
    private var buffering = true
    private var packets = 0
    private var latePackets = 0
    private var overflowPackets = 0
    private var underruns = 0
    private var nextStatistics = 0.0
    private var retryPlaybackAt = 0.0
    private let feedbackLock = NSLock()
    private var renderedSampleTime: UInt32?
    private var browserClock: (rtp: UInt32, host: UInt64)?
    private static let renderQueue = DispatchQueue(label: "TDSCarKit.audio", qos: .userInteractive)
    // Audio decoding never blocks the video/RTSP queue. All streams share this queue.
    private static var playingStreams = 0
    #if os(iOS)
    private static var hasSpeakerOverride = false
    #endif
    var onLog: ((String) -> Void)?
    /// 本实例对应的 CarPlay 流类型（100/101/102），由 CarPlayMedia
    /// Session 建实例时回填；主流 102 停时据此打累计包数日志。
    var streamType: Int?
    var onBrowserAudio: ((AVAudioPCMBuffer, UInt64) -> Void)?
    /// 编码音频 tap（仅主流 AAC）：在解码前截一份裸 AAC 访问单元与主机
    /// 微秒时间戳，供音频桥多喂一份给车机；原解码→扬声器路径不动。
    var onEncodedAudio: ((Data, UInt64) -> Void)?
    init(secret: SymmetricKey, peerAddress: String, connectionID: UInt64, format: ReceiverAudioFormat, microphonePort: UInt16? = nil) throws {
        self.queue = Self.renderQueue; self.connectionID = connectionID; self.format = format
        decoder = try NativeAudioDecoder(format: format)
        output = decoder.output
        cipher = AudioStream(secret: secret, connectionID: connectionID)
        data = try AudioDatagramPort(queue: Self.renderQueue, peerAddress: peerAddress)
        control = try AudioDatagramPort(queue: Self.renderQueue, peerAddress: peerAddress)
        dataPort = data.port; controlPort = control.port
        if let microphonePort, !format.isAAC, format.channels == 1 {
            microphone = NativeMicrophone(secret: secret, connectionID: connectionID, address: peerAddress, port: microphonePort, format: format)
        }
        data.onPacket = { [weak self] in self?.receive($0) }
    }
    private func receive(_ wire: Data) {
        guard active else { return }
        do {
            let packet = try cipher.receive(wire)
            let arrival = DispatchTime.now().uptimeNanoseconds / 1000
            // Decode every accepted compressed packet to preserve the codec's overlap state.
            packets += 1
            if let lastTimestamp, Int32(bitPattern: packet.timestamp &- lastTimestamp) <= 0 { latePackets += 1; return }
            lastTimestamp = packet.timestamp
            // 音频桥 tap：解码前把裸 AAC 访问单元多喂一份出去（送车机），
            // 时间戳与浏览器音频共用 browserTimestamp 锚点。扬声器路径
            // 在下面照常走，一行不动。
            if let onEncodedAudio {
                onEncodedAudio(packet.samples, browserTimestamp(packet.timestamp, arrival: arrival))
            }
            guard let buffer = try decoder.decode(packet.samples) else { return }
            if let onBrowserAudio {
                onBrowserAudio(buffer, browserTimestamp(packet.timestamp, arrival: arrival))
                return
            }
            let frames = Int(buffer.frameLength)
            guard queuedFrames + frames <= format.sampleRate * 2 else { overflowPackets += 1; return }
            if !playing {
                let now = ProcessInfo.processInfo.systemUptime
                guard now >= retryPlaybackAt else { return }
                retryPlaybackAt = now + 0.5
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                let routeOutputs = session.currentRoute.outputs
                let routeHasCarAudio = routeOutputs.contains { $0.portType == .carAudio }
                let routeHasA2DP = routeOutputs.contains { $0.portType == .bluetoothA2DP }
                // 类别（AUDIO-BT-ROUTE-DIFF）：需要 playAndRecord 的场
                // 合——带麦克风、已钉扬声器、或路由只有 CarPlay 口没
                // 有蓝牙（要钉扬声器避回路，得先切过去）。类别选项恒
                // 并入 .allowBluetoothA2DP：不给这个选项，被强制切的
                // playAndRecord 类别下蓝牙 A2DP 连候选资格都没有。
                // 通话流不掺和：这里从不设 .allowBluetooth（HFP），
                // 抢不到通话路由，通话维持手机扬声器＋手机麦克风。
                let needsDuplexCategory = microphone != nil || Self.hasSpeakerOverride
                    || (routeHasCarAudio && !routeHasA2DP)
                var options: AVAudioSession.CategoryOptions = needsDuplexCategory ? [.defaultToSpeaker] : []
                options.insert(.allowBluetoothA2DP)
                if BackgroundKeepAlive.holdsAudioSession { options.insert(.mixWithOthers) }
                let category: AVAudioSession.Category = needsDuplexCategory ? .playAndRecord : .playback
                if session.category != category || session.mode != .default || session.categoryOptions != options {
                    try session.setCategory(category, mode: .default, options: options)
                }
                try session.setActive(true)
                Self.installRouteObserverIfNeeded()
                Self.routeLogSink = { [weak self] message in self?.onLog?(message) }
                if let failure = Self.reevaluateRouteOverride(reason: "起播") {
                    Self.deactivateSessionIfIdle()
                    throw failure
                }
                #endif
                let engine: AVAudioEngine
                if let existing = self.engine { engine = existing }
                else {
                    engine = AVAudioEngine()
                    let player = AVAudioPlayerNode()
                    engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: output)
                    self.engine = engine; self.player = player
                }
                do { try engine.start() } catch {
                    #if os(iOS)
                    Self.deactivateSessionIfIdle()
                    #endif
                    throw error
                }
                playing = true; Self.playingStreams += 1
                if let microphone {
                    microphone.onLog = onLog
                    DispatchQueue.main.async { microphone.start() }
                }
                firstTimestamp = packet.timestamp
                onLog?(CWL("原生 {1} 播放已开始：{2} Hz，{3} 声道", [String(describing: format.name), String(describing: format.sampleRate), String(describing: format.channels)]))
                #if os(iOS)
                onLog?(CWL("音频输出路由：{1}", [String(describing: AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", "))]))
                #endif
            }
            guard let player else { return }
            queuedFrames += frames
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.active else { return }
                    self.queuedFrames = max(0, self.queuedFrames - frames)
                    if self.queuedFrames == 0, !self.buffering {
                        self.player?.pause(); self.buffering = true; self.underruns += 1
                    }
                }
            }
            let prebuffer = format.sampleRate * (format.isAAC ? 180 : 40) / 1000
            if buffering, queuedFrames >= prebuffer {
                player.play(); buffering = false
            }
            updateFeedback()
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextStatistics {
                nextStatistics = now + 5
                onLog?(CWL("音频状态：数据包={1}，队列={2}ms，欠载={3}，延迟={4}，溢出={5}，拒绝={6}", [String(describing: packets), String(describing: queuedFrames * 1000 / format.sampleRate), String(describing: underruns), String(describing: latePackets), String(describing: overflowPackets), String(describing: rejected)]))
            }

        } catch {
            rejected += 1
            if rejected <= 3 { onLog?(CWL("音频数据包被拒绝：{1}", [String(describing: error.localizedDescription)])) }
        }
    }
    private func browserTimestamp(_ rtp: UInt32, arrival: UInt64) -> UInt64 {
        if let anchor = browserClock {
            let samples = Int64(Int32(bitPattern: rtp &- anchor.rtp))
            let position = Int64(anchor.host) + samples * 1_000_000 / Int64(format.sampleRate)
            // Keep source timing through packet bursts, and re-anchor after a genuine clock reset.
            if samples >= 0, position >= 0, abs(position - Int64(arrival)) < 500_000 {
                return UInt64(position)
            }
        }
        browserClock = (rtp, arrival)
        return arrival
    }

    private func updateFeedback() {
        guard let firstTimestamp, let player, let render = player.lastRenderTime,
              let position = player.playerTime(forNodeTime: render) else { return }
        let rendered = firstTimestamp &+ UInt32(truncatingIfNeeded: max(0, position.sampleTime))
        feedbackLock.lock()
        renderedSampleTime = rendered
        feedbackLock.unlock()
    }

    func feedback(type: Int, ntp: UInt64) -> [String: Any] {
        // Never wait for AVAudioEngine or an iOS route transition on the RTSP/video queue.
        feedbackLock.lock()
        let rendered = renderedSampleTime
        feedbackLock.unlock()
        var info: [String: Any] = ["type": type, "sampleRate": format.sampleRate]
        if let rendered {
            info["sampleTime"] = NSNumber(value: rendered)
            info["timestamp"] = NSNumber(value: ntp)
            info["streamConnectionID"] = NSNumber(value: connectionID)
        }
        return info
    }

    func stop() {
        // Keep this stream alive until its queued teardown completes; a replacement stream may
        // negotiate immediately, but the render queue always observes the old stop first.
        queue.async { self.stopOnQueue() }
    }
    static func endMediaSession() {
        #if os(iOS)
        renderQueue.async { deactivateSessionIfIdle(releaseSpeakerOverride: true) }
        #endif
    }
    private func stopOnQueue() {
        guard active else { return }; active = false
        // 主流（102）实例停时打一行本实例累计包数：iOS 这一轮到底送
        // 了多少声音包一眼可见，不用再靠 5 秒统计行推断（诊断
        // AUDIO-SILENT-DIFF：1645 轮整轮只有 1 个建流 priming 包，
        // 就是靠这种行才能一眼定性）。
        if streamType == 102 {
            onLog?(CWL("音频流 102 接收实例已停，本实例累计收到 {1} 个包", [String(describing: packets)]))
        }
        if let microphone { DispatchQueue.main.async { microphone.stop() } }; microphone = nil
        data.stop(); control.stop(); player?.stop(); engine?.stop(); queuedFrames = 0
        if playing {
            playing = false; Self.playingStreams -= 1
            #if os(iOS)
            Self.deactivateSessionIfIdle()
            #endif
        }
    }
    #if os(iOS)
    /// 路由评估的日志出口（最近一条流的 onLog）：routeChange 通知是
    /// 系统回调、没有实例在手，借这个静态口把日志送回 App 日志。
    private static var routeLogSink: ((String) -> Void)?
    private static var routeObserverInstalled = false

    /// 扬声器钉子的统一评估（起播与路由变化共用，AUDIO-BT-ROUTE
    /// -DIFF 第 3 节）：路由含 CarPlay 音频口、且不含蓝牙 A2DP 时才
    /// 钉——carAudio 口对面是我们自己的接收端，解码声从那儿出会被
    /// 当作发给车机的音频送回本 App 再解码（回路、扬声器无声）；
    /// A2DP 是单向的、不回路，只避 CarPlay、放行蓝牙。没有「强制
    /// 蓝牙」的 API，放行只是给资格：虚拟 CarPlay 在场时 iOS 让不
    /// 让本 App 输出落 A2DP 只能真机验。每处规则变化打一行日志。
    /// 返回非 nil 表示「该钉没钉成」（与旧行为一致，调用方中止起播）。
    private static func reevaluateRouteOverride(reason: String) -> Error? {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let hasCarAudio = outputs.contains { $0.portType == .carAudio }
        let hasA2DP = outputs.contains { $0.portType == .bluetoothA2DP }
        let log = routeLogSink
        if hasCarAudio && !hasA2DP {
            guard !hasSpeakerOverride else { return nil }
            do {
                try session.overrideOutputAudioPort(.speaker)
                hasSpeakerOverride = true
                log?(CWL("音频路由评估（{1}）：路由含 CarPlay 音频口、没有蓝牙 A2DP——钉住 iPhone 扬声器（避开 CarPlay 回路）", [reason]))
                return nil
            } catch {
                log?(CWL("音频路由评估（{1}）：想钉扬声器没钉成——{2}", [reason, error.localizedDescription]))
                return error
            }
        }
        if hasSpeakerOverride {
            try? session.overrideOutputAudioPort(.none)
            hasSpeakerOverride = false
            log?(CWL("音频路由评估（{1}）：路由已离开 CarPlay 独占，松开扬声器钉子，输出按系统路由走", [reason]))
        }
        if hasA2DP {
            log?(CWL("音频路由评估（{1}）：路由含蓝牙 A2DP，不钉扬声器，放行蓝牙输出", [reason]))
        }
        return nil
    }

    /// 路由变化监听（只装一次）：离开 carAudio 落到 A2DP 时松钉、
    /// 回到只有 carAudio 时重新钉——旧实现整场不松，路由中途变了
    /// 也没人重估，蓝牙永远出不来。
    private static func installRouteObserverIfNeeded() {
        guard !routeObserverInstalled else { return }
        routeObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { _ in
            // 只在还有流在播时重估：没流时钉子状态留给起播那一刻定。
            renderQueue.async {
                guard playingStreams > 0 else { return }
                _ = reevaluateRouteOverride(reason: "路由变化")
            }
        }
    }

    /// Releases the shared session after the last stream, unless the background keep-alive still
    /// plays in it: deactivating would stop that player too and iOS would suspend the app.
    private static func deactivateSessionIfIdle(releaseSpeakerOverride: Bool = false) {
        guard playingStreams == 0 else { return }
        let session = AVAudioSession.sharedInstance()
        let keepAlive = BackgroundKeepAlive.holdsAudioSession
        if hasSpeakerOverride {
            // A CarPlay audio format change tears down the old RTP stream. Keep the
            // output route through that replacement so iOS does not renegotiate again.
            guard releaseSpeakerOverride else { return }
            hasSpeakerOverride = false
            try? session.overrideOutputAudioPort(.none)
            var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
            if keepAlive { options.insert(.mixWithOthers) }
            try? session.setCategory(.playback, mode: .default, options: options)
        }
        guard !keepAlive else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif
}

/// Converts one authenticated RTP payload to native Float32 PCM.
/// AAC payloads are raw access units, not ADTS containers.
final class NativeAudioDecoder {
    let output: AVAudioFormat
    private let format: ReceiverAudioFormat
    private var converter: AVAudioConverter?
    private var compressed: AVAudioFormat?
    init(format: ReceiverAudioFormat) throws {
        self.format = format
        output = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate), channels: AVAudioChannelCount(format.channels))!
        if format.isAAC || format.isOpus {
            var description = AudioStreamBasicDescription(mSampleRate: Double(format.sampleRate), mFormatID: format.isOpus ? kAudioFormatOpus : kAudioFormatMPEG4AAC,
                mFormatFlags: format.isOpus ? 0 : 2, mBytesPerPacket: 0, mFramesPerPacket: format.isOpus ? UInt32(format.sampleRate / 50) : 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(format.channels), mBitsPerChannel: 0, mReserved: 0)
            guard let input = AVAudioFormat(streamDescription: &description), let codec = AVAudioConverter(from: input, to: output) else {
                throw ProtocolError.malformed(CWL("{1} 解码器不可用", [String(describing: format.name)]))
            }
            if format.isAAC { codec.magicCookie = Data(format.sampleRate == 44100 ? [0x12, 0x10] : [0x11, 0x90]) }
            codec.primeMethod = .none
            compressed = input; converter = codec
        }
    }
    func decode(_ payload: Data) throws -> AVAudioPCMBuffer? {
        guard !payload.isEmpty, payload.count <= 65507 else { throw ProtocolError.malformed(CWL("音频载荷大小")) }
        if let converter, let compressed {
            let input = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: payload.count)
            input.packetCount = 1; input.byteLength = UInt32(payload.count)
            payload.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: payload.count) }
            input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: format.isOpus ? 0 : 1024, mDataByteSize: UInt32(payload.count))
            guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: format.isOpus ? AVAudioFrameCount(format.sampleRate * 120 / 1000) : 1024) else { throw ProtocolError.malformed(CWL("AAC 输出缓冲区")) }
            var supplied = false, error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if status == .error { throw error ?? NSError(domain: "TDSAudio", code: 1) }
            return pcm.frameLength > 0 ? pcm : nil
        }
        let frameBytes = format.channels * 2
        guard payload.count % frameBytes == 0 else { throw ProtocolError.malformed(CWL("PCM 帧大小")) }
        let frames = payload.count / frameBytes
        guard frames <= format.sampleRate / 4,
              let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames)), let planes = buffer.floatChannelData else {
            throw ProtocolError.malformed(CWL("PCM 输出缓冲区"))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        payload.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<format.channels {
                    let index = (frame * format.channels + channel) * 2
                    let sample = Int16(bitPattern: UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
                    planes[channel][frame] = Float(sample) / 32768
                }
            }
        }
        return buffer
    }
}

/// On-demand mono PCM/Opus capture for a negotiated voice uplink. All state is main-thread.
/// Music streams never request microphone permission or activate recording.
private final class NativeMicrophone {
    private let engine = AVAudioEngine()
    private let packetizer: MicrophonePacketizer
    private let connection: NWConnection
    private let rate: Int
    private let format: ReceiverAudioFormat
    private var opusEncoder: NativeOpusEncoder?
    private let slots = DispatchSemaphore(value: 4)
    private var converter: AVAudioConverter?
    private var active = true
    private var installedTap = false
    private var pending = Data()
    private var failures = 0
    var onLog: ((String) -> Void)?
    init(secret: SymmetricKey, connectionID: UInt64, address: String, port: UInt16, format: ReceiverAudioFormat) {
        self.rate = format.sampleRate; self.format = format
        packetizer = MicrophonePacketizer(secret: secret, connectionID: connectionID)
        connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
    }
    func start() {
        guard active else { return }
        #if os(iOS)
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                if granted { self.beginCapture() }
                else { self.onLog?(CWL("麦克风权限被拒绝，语音输入不可用")) }
            }
        }
        #else
        onLog?(CWL("麦克风采集需要使用 iPhone/iPad 目标"))
        #endif
    }
    private func beginCapture() {
        do {
            if format.isOpus { opusEncoder = try NativeOpusEncoder(rate: rate) }
            let input = engine.inputNode.outputFormat(forBus: 0)
            guard input.sampleRate > 0, input.channelCount > 0,
                  let output = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
                  let converter = AVAudioConverter(from: input, to: output) else { throw ProtocolError.malformed(CWL("麦克风格式")) }
            self.converter = converter
            connection.start(queue: .main)
            let slots = self.slots
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self] buffer, _ in
                guard slots.wait(timeout: .now()) == .success else { return }
                guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { slots.signal(); return }
                copy.frameLength = buffer.frameLength
                let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for index in 0..<source.count {
                    if let src = source[index].mData, let dst = target[index].mData {
                        dst.copyMemory(from: src, byteCount: Int(source[index].mDataByteSize))
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    defer { slots.signal() }
                    guard let self, self.active else { return }
                    self.send(copy)
                }
            }
            installedTap = true
            try engine.start()
            onLog?(CWL("{1} 麦克风已启动：{2} Hz 单声道", [String(describing: format.name), String(describing: rate)]))
        } catch { onLog?(CWL("无法启动麦克风：{1}", [String(describing: error.localizedDescription)])); stop() }
    }
    private func send(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }
        do {
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * Double(rate) / input.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
            var supplied = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if status == .error { throw error ?? NSError(domain: "TDSMicrophone", code: 1) }
            guard let samples = output.floatChannelData?[0] else { return }
            for index in 0..<Int(output.frameLength) {
                let scaled = samples[index].isFinite ? max(-32768, min(32767, samples[index] * 32768)) : 0
                let sample = UInt16(bitPattern: Int16(scaled))
                pending.append(UInt8(truncatingIfNeeded: sample >> 8)); pending.append(UInt8(truncatingIfNeeded: sample))
            }
            let frames = rate / 50, bytes = frames * 2
            while pending.count >= bytes {
                let pcm = Data(pending.prefix(bytes))
                pending.removeFirst(bytes)
                let payload: Data
                if let opusEncoder {
                    guard let encoded = try opusEncoder.encode(pcm) else { continue }
                    payload = encoded
                } else { payload = pcm }
                let wire = try packetizer.seal(payload, frames: UInt32(frames))
                connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.stop() }
                })
            }
        } catch {
            failures += 1
            if failures <= 3 { onLog?(CWL("麦克风转换失败：{1}", [String(describing: error.localizedDescription)])) }
        }
    }
    func stop() {
        guard active else { return }; active = false
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        engine.stop(); connection.cancel(); converter = nil; pending.removeAll()
    }
}

/// One 20-ms mono voice packet. Uses Apple's codec, with no Ogg/container header.
final class NativeOpusEncoder {
    private let converter: AVAudioConverter
    private let pcm: AVAudioFormat
    private let compressed: AVAudioFormat
    private let frames: Int
    init(rate: Int) throws {
        frames = rate / 50
        pcm = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        var description = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &description),
              let codec = AVAudioConverter(from: pcm, to: format) else { throw ProtocolError.malformed(CWL("Opus 编码器不可用")) }
        compressed = format; converter = codec
        converter.primeMethod = .none
        converter.bitRate = rate == 48000 ? 64000 : 32000
    }
    func encode(_ bigEndianPCM: Data) throws -> Data? {
        guard bigEndianPCM.count == frames * 2,
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(frames)) else {
            throw ProtocolError.malformed(CWL("Opus 麦克风帧大小"))
        }
        input.frameLength = AVAudioFrameCount(frames)
        bigEndianPCM.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<frames {
                input.floatChannelData![0][index] = Float(Int16(bitPattern: UInt16(bytes[index * 2]) << 8 | UInt16(bytes[index * 2 + 1]))) / 32768
            }
        }
        let packet = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: 4096)
        var supplied = false, error: NSError?
        let status = converter.convert(to: packet, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { throw error ?? NSError(domain: "TDSOpus", code: 1) }
        guard packet.packetCount > 0, packet.byteLength > 0 else { return nil }
        return Data(bytes: packet.data, count: Int(packet.byteLength))
    }
}
