import Foundation
import Network
import CoreGraphics

/// All listener/session state is confined to queue. UI callbacks are always main-thread.
final class NativeReceiver {
    private let queue = DispatchQueue(label: "TDSCarKit.receiver")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var sessions: [UUID: SessionState] = [:]
    /// Access units handed to the main thread but not yet consumed. Over the limit, the local
    /// display skips to the next keyframe instead of dropping arbitrary (dependent) P-frames.
    private var localInFlight = 0
    private var localSkipping = false
    private let maximumLocalInFlight = 12
    private var localVideoEnabled = true

    func setLocalVideoEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.localVideoEnabled = enabled
            if !enabled { self?.localSkipping = false }
        }
    }
    // forceKeyFrame state: throttled sends, resent every second until a keyframe arrives.
    private var keyframeWantedSince: DispatchTime?
    private var keyframeLastSent: DispatchTime?
    private var keyframeAttempts = 0
    private var keyframeReason = ""
    private var touchSlots = TouchSlots(count: CarPlayInfo.touchContacts)
    private var displaySize: (width: Int, height: Int)?
    private var nightMode: Bool?
    private var generation = UUID()
    private var airPlayIdentity: AirPlayCredentials?
    var onCarUIRequested: (() -> Void)?
    var onLog: ((String) -> Void)?
    var onListening: ((UInt16) -> Void)?
    var onControlConnected: (() -> Void)?
    var onVideo: ((Data, VideoCodec) -> Void)?
    /// 主流（102）编码音频帧 tap：裸 AAC 访问单元 + 主机微秒时间戳 + 格式。
    /// 由媒体会话转出，给音频桥送车机用；本机扬声器播放不走这里。
    var onEncodedAudio: ((Int, Data, UInt64, ReceiverAudioFormat) -> Void)?
    /// Queue-confined raw access-unit fan-out (no main-thread hop, no local-display
    /// throttling). The clink bridge consumes from here.
    var onVideoAccessUnit: ((Data, VideoCodec) -> Void)?
    var onFailure: (() -> Void)?

    func start(configuration: ReceiverConfiguration, identity: AccessoryIdentity) {
        let listening = onListening
        queue.async { [weak self] in
            guard let self else { return }
            self.displaySize = (configuration.width, configuration.height)
            do { self.airPlayIdentity = try AirPlayCredentials() }
            catch { self.fail(CWL("AirPlay 身份创建失败：{1}", [String(describing: error.localizedDescription)])); return }
            if configuration.audioEnabled {
                do {
                    for bits: UInt64 in [0x10000000, 0x20000000, 0x40000000] {
                        let format = try ReceiverAudioFormat(bits: bits)
                        _ = try NativeAudioDecoder(format: format)
                        _ = try NativeOpusEncoder(rate: format.sampleRate)
                    }
                    self.log(CWL("原生 Opus 语音编解码器可用（16/24/48 kHz）"))
                } catch { self.fail(CWL("无线音频编解码器不可用：{1}", [String(describing: error.localizedDescription)])); return }
            }
            self.log(CWL("请求 {1}×{2} @ {3} FPS，{4}；音频{5}", [String(describing: configuration.width), String(describing: configuration.height), String(describing: configuration.maxFPS), String(describing: configuration.videoCodec.displayName), String(describing: configuration.audioEnabled ? CWL("已启用（PCM/AAC/Opus）") : CWL("已关闭"))]))
            self.listen(configuration: configuration, identity: identity, port: configuration.port, onReady: listening)
        }
    }
    private func listen(configuration: ReceiverConfiguration, identity: AccessoryIdentity, port: UInt16?, onReady: ((UInt16) -> Void)?) {
        let generation = self.generation
        do {
            let candidate = try NWListener(using: .tcp, on: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
            if let airPlayIdentity {
                let features = CarPlayInfo.features(audio: configuration.audioEnabled)
                let txt: [String: String] = ["deviceid": configuration.deviceID,
                    "features": String(format: "0x%x,0x%x", UInt32(truncatingIfNeeded: features), UInt32(truncatingIfNeeded: features >> 32)),
                    "flags": "0x4", "model": "TDSCarKit1,1", "srcvers": "509.11", "protovers": "1.1",
                    "pi": airPlayIdentity.identifier, "pk": airPlayIdentity.signingKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()]
                candidate.service = NWListener.Service(name: configuration.name, type: "_airplay._tcp", txtRecord: NWTXTRecord(txt))
                candidate.serviceRegistrationUpdateHandler = { [weak self] change in self?.log(CWL("Bonjour 注册状态：{1}", [String(describing: change)])) }
            }
            listener = candidate
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate, self.generation == generation, self.listener === candidate else { return }
                switch state {
                case .ready:
                    guard let actualPort = candidate.port?.rawValue else { self.fail(CWL("监听器未获得端口")); return }
                    self.log(CWL("原生 RTSP 监听器已在端口 {1} 就绪", [String(describing: actualPort)]))
                    DispatchQueue.main.async { onReady?(actualPort) }
                case .failed(let error):
                    if port != nil, case .posix(.EADDRINUSE) = error {
                        self.log(CWL("端口 {1} 已被占用，正在申请可用端口", [String(describing: port!)]))
                        candidate.cancel(); self.listener = nil
                        self.listen(configuration: configuration, identity: identity, port: nil, onReady: onReady)
                    } else { self.fail(CWL("监听器失败：{1}", [String(describing: error.localizedDescription)])) }
                default: break
                }
            }
            candidate.newConnectionHandler = { [weak self, weak candidate] connection in
                guard let self, self.generation == generation, self.listener === candidate,
                      self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID(); self.connections[id] = connection
                let state = SessionState(credentials: self.airPlayIdentity)
                state.setup?.onLog = { [weak self] in self?.log($0) }
                self.sessions[id] = state
                if case .hostPort(let host, _) = connection.endpoint { state.peerAddress = "\(host)" }
                connection.stateUpdateHandler = { [weak self, weak connection] update in
                    guard let self, let connection else { return }
                    switch update {
                    case .ready:
                        self.log(CWL("收到控制连接"))
                        DispatchQueue.main.async { [weak self] in self?.onControlConnected?() }
                        self.receive(connection, id: id, state: state, configuration: configuration, identity: identity)
                    case .failed, .cancelled:
                        state.media?.stop(); self.sessions.removeValue(forKey: id); self.connections.removeValue(forKey: id)
                    default: break
                    }
                }
                connection.start(queue: self.queue)
            }
            candidate.start(queue: queue)
        } catch let error as NWError {
            if port != nil, case .posix(.EADDRINUSE) = error {
                log(CWL("端口 {1} 已被占用，正在申请可用端口", [String(describing: port!)]))
                listen(configuration: configuration, identity: identity, port: nil, onReady: onReady)
            } else { fail(CWL("无法创建监听器：{1}", [String(describing: error.localizedDescription)])) }
        } catch { fail(CWL("无法创建监听器：{1}", [String(describing: error)])) }
    }
    private func fail(_ message: String) {
        log(message); stopOnQueue()
        DispatchQueue.main.async { [weak self] in self?.onFailure?() }
    }
    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }
    private var activeMedia: CarPlayMediaSession? { sessions.values.first(where: { $0.media != nil })?.media }
    /// All fingers currently held by `source` (normalized 0…1); an empty list releases them.
    func touches(source: String, _ points: [TouchPoint]) {
        queue.async { [weak self] in
            guard let self, let size = self.displaySize else { return }
            let report = self.touchSlots.update(source: source, points: points)
            guard !report.isEmpty else { return }
            let contacts = report.map { entry in
                CarPlayInfo.TouchContact(slot: entry.slot,
                    x: UInt16(clamping: Int((min(max(entry.x, 0), 1) * Double(max(size.width - 1, 0))).rounded())),
                    y: UInt16(clamping: Int((min(max(entry.y, 0), 1) * Double(max(size.height - 1, 0))).rounded())),
                    down: entry.down)
            }
            self.activeMedia?.touch(contacts)
        }
    }
    func press(_ control: CarPlayControl) {
        queue.async { [weak self] in
            guard let self, let media = self.activeMedia else { self?.log(CWL("CarPlay 尚未连接，无法发送「{1}」", [String(describing: control.title)])); return }
            let knobUp = CarPlayInfo.knobReport()
            switch control {
            case .home: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(home: true), release: knobUp)
            case .back: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(back: true), release: knobUp)
            case .select: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(select: true), release: knobUp)
            case .knobPrevious: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(wheel: -1), release: knobUp)
            case .knobNext: media.pressHID(CarPlayInfo.HID.knob, CarPlayInfo.knobReport(wheel: 1), release: knobUp)
            case .previous: media.pressHID(CarPlayInfo.HID.media, Data([CarPlayInfo.MediaKey.previous.rawValue]), release: Data([0]))
            case .playPause:
                log(CWL("媒体 HID：发送「播放/暂停」"))
                media.pressHID(CarPlayInfo.HID.media, Data([CarPlayInfo.MediaKey.playPause.rawValue]), release: Data([0]))
            case .next: media.pressHID(CarPlayInfo.HID.media, Data([CarPlayInfo.MediaKey.next.rawValue]), release: Data([0]))
            case .siri: media.requestSiri()
            case .hookSwitch: media.pressHID(CarPlayInfo.HID.telephony, Data([CarPlayInfo.TelephonyKey.hookSwitch.rawValue]), release: Data([0]))
            }
        }
    }
    /// Day/night appearance for CarPlay. Remembered across sessions and sent once the event channel is up.
    func setNightMode(_ night: Bool) {
        queue.async { [weak self] in
            guard let self, self.nightMode != night else { return }
            self.nightMode = night
            self.sessions.values.forEach { $0.media?.setNightMode(night) }
        }
    }
    /// Thread-safe entry for decoders (local display, browser viewers) that need a fresh keyframe.
    func requestKeyFrame(reason: String) {
        queue.async { [weak self] in self?.requestKeyFrameOnQueue(reason: reason) }
    }
    private func requestKeyFrameOnQueue(reason: String) {
        let now = DispatchTime.now()
        if keyframeWantedSince == nil { keyframeWantedSince = now; keyframeAttempts = 0; keyframeReason = reason }
        // 250 ms throttle: several viewers recovering together share one request.
        if let last = keyframeLastSent, now.uptimeNanoseconds - last.uptimeNanoseconds < 250_000_000 { return }
        sendKeyFrameRequest()
    }
    private func sendKeyFrameRequest() {
        guard keyframeWantedSince != nil else { return }
        guard let media = sessions.values.first(where: { $0.media?.hasEventChannel == true })?.media else { return }
        keyframeAttempts += 1
        keyframeLastSent = .now()
        guard media.requestKeyFrame() else { return }
        if keyframeAttempts == 1 { log(CWL("已请求关键帧（{1}）", [String(describing: keyframeReason)])) }
        guard keyframeAttempts < 8 else {
            log(CWL("iPhone 未响应关键帧请求（已重试 {1} 次），等待自然关键帧", [String(describing: keyframeAttempts)]))
            keyframeWantedSince = nil; return
        }
        let run = generation
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == run, self.keyframeWantedSince != nil else { return }
            self.sendKeyFrameRequest()
        }
    }
    private func keyframeArrived() {
        guard let since = keyframeWantedSince else { return }
        keyframeWantedSince = nil
        let ms = (DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
        log(CWL("关键帧已到达（{1} ms，{2} 次请求）", [String(describing: ms), String(describing: keyframeAttempts)]))
    }
    private static func containsRandomAccess(_ accessUnit: Data, codec: VideoCodec) -> Bool {
        (try? AnnexB.units(in: accessUnit))?.contains { codec.isRandomAccess($0) } ?? false
    }
    private func stopOnQueue() {
        generation = UUID(); listener?.cancel(); listener = nil
        localSkipping = false; keyframeWantedSince = nil; keyframeLastSent = nil; keyframeAttempts = 0
        touchSlots.reset()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        sessions.values.forEach { $0.media?.stop() }; sessions.removeAll()
    }
    private final class SessionState {
        var parser = RTSPParser()
        var authenticated = false
        var setup: PairSetup?
        var verify: PairVerify?
        var cipher: ControlCipher?
        var media: CarPlayMediaSession?
        var peerAddress = ""
        init(credentials: AirPlayCredentials?) {
            if let credentials {
                setup = PairSetup(identifier: credentials.identifier, signingKey: credentials.signingKey) {
                    try credentials.saveController($0, key: $1)
                }
                verify = PairVerify(identifier: credentials.identifier, signingKey: credentials.signingKey) {
                    try? credentials.controller($0)
                }
            }
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, state: SessionState,
                         configuration: ReceiverConfiguration, identity: AccessoryIdentity) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            do {
                if let data, !data.isEmpty {
                    var input = data
                    while true {
                        let plaintext = try state.cipher?.receive(input) ?? input
                        guard let request = try state.parser.append(plaintext, maximumRequests: 1).first else { break }
                        self.log(CWL("{1} {2} [{3} 字节]", [String(describing: request.method), String(describing: request.target.prefix(100)), String(describing: request.body.count)]))
                        let response = try self.respond(request, state: state, configuration: configuration, identity: identity)
                        let encoded = response.encoded(for: request)
                        let wire = try state.cipher?.encrypt(encoded) ?? encoded
                        connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                            if let error { self?.log(CWL("控制通道写入失败：{1}", [String(describing: error.localizedDescription)])); connection.cancel() }
                        })
                        input = Data()
                        if state.cipher == nil, let keys = state.verify?.keys {
                            // M4 is plaintext. Only subsequent bytes use the negotiated record keys.
                            state.cipher = ControlCipher(readKey: keys.read, writeKey: keys.write)
                            input = state.parser.takeBufferedData()
                            self.log(CWL("Pair-Verify 已通过，已启用加密控制"))
                        }
                    }
                }
                if complete || error != nil { connection.cancel(); self.connections.removeValue(forKey: id) }
                else { self.receive(connection, id: id, state: state, configuration: configuration, identity: identity) }
            } catch {
                self.log(CWL("控制连接被拒绝：{1}", [String(describing: error)])); connection.cancel(); self.connections.removeValue(forKey: id)
            }
        }
    }
    private func respond(_ request: RTSPRequest, state: SessionState, configuration: ReceiverConfiguration,
                         identity: AccessoryIdentity) throws -> RTSPResponse {
        switch (request.method, request.target.components(separatedBy: "?")[0]) {
        case ("OPTIONS", _): return RTSPResponse()
        case ("SETUP", _):
            guard state.cipher != nil, state.authenticated, let secret = state.verify?.mediaSecret else {
                throw ProtocolError.malformed(CWL("在配件会话通过验证前收到 SETUP"))
            }
            if state.media == nil {
                let media = CarPlayMediaSession(queue: queue, secret: secret, peerAddress: state.peerAddress,
                                                audioEnabled: configuration.audioEnabled, hevc: configuration.videoCodec == .h265)
                media.onLog = { [weak self] in self?.log($0) }
                media.onEncodedAudio = { [weak self] stream, samples, stamp, format in
                    self?.onEncodedAudio?(stream, samples, stamp, format)
                }
                if let nightMode { media.setNightMode(nightMode) }
                media.onVideo = { [weak self] data, codec in
                    guard let self else { return }
                    let keyframe = Self.containsRandomAccess(data, codec: codec)
                    if keyframe { self.keyframeArrived() }
                    self.onVideoAccessUnit?(data, codec)
                    guard self.localVideoEnabled else { return }
                    if self.localSkipping {
                        guard keyframe, self.localInFlight < self.maximumLocalInFlight / 2 else { return }
                        self.localSkipping = false
                    } else if self.localInFlight >= self.maximumLocalInFlight, !keyframe {
                        self.localSkipping = true
                        self.requestKeyFrameOnQueue(reason: CWL("本机显示积压"))
                        return
                    }
                    self.localInFlight += 1
                    DispatchQueue.main.async { [weak self] in
                        self?.onVideo?(data, codec)
                        self?.queue.async { [weak self] in
                            if let self { self.localInFlight = max(0, self.localInFlight - 1) }
                        }
                    }
                }
                state.media = media
            }
            return RTSPResponse(body: try state.media!.setup(request.body), contentType: "application/x-apple-binary-plist")
        case ("RECORD", _):
            guard state.media != nil else { throw ProtocolError.malformed(CWL("在 SETUP 前收到 RECORD")) }
            log(CWL("已接受 CarPlay RECORD，正在等待视频"))
            return RTSPResponse()
        case ("POST", "/pair-setup"):
            guard state.cipher == nil, let setup = state.setup else { throw ProtocolError.malformed(CWL("pair-setup 不可用")) }
            let fields = try TLV8.decode(request.body)
            log(CWL("Pair-Setup 状态 {1}，方法 {2}", [String(describing: fields[6]?.first ?? 0), String(describing: fields[0]?.first.map(String.init) ?? CWL("缺失"))]))
            let body = try setup.handle(request.body)
            if setup.complete { log(CWL("Pair-Setup 已完成，已保存通过验证的控制端")) }
            return RTSPResponse(body: body, contentType: "application/pairing+tlv8")
        case ("POST", "/pair-verify"):
            guard state.cipher == nil, let verify = state.verify else { throw ProtocolError.malformed(CWL("pair-verify 不可用")) }
            return RTSPResponse(body: try verify.handle(request.body), contentType: "application/pairing+tlv8")
        case ("GET", "/info"), ("POST", "/info"):
            // appStates 据实报：媒体状态取此刻 102 流是否建着（会话
            // 早期 /info 时流还没建，报 false 是实话，不再恒写死）。
            let info = CarPlayInfo.build(configuration,
                                         mediaActive: state.media?.mediaStreamActive ?? false)
            return RTSPResponse(body: try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0),
                                contentType: "application/x-apple-binary-plist")
        case ("POST", "/auth-setup"):
            let body = try MFiSAP.respond(to: request.body, identity: identity)
            state.authenticated = true
            log(CWL("已生成 MFiSAP 响应，正在等待 iPhone 接受"))
            return RTSPResponse(body: body)
        case ("POST", "/feedback"):
            if let feedback = try state.media?.feedback() {
                return RTSPResponse(body: feedback, contentType: "application/x-apple-binary-plist")
            }
            return RTSPResponse()
        case ("POST", "/command"):
            guard state.cipher != nil else { throw ProtocolError.malformed(CWL("验证完成前收到 command")) }
            if let command = try PropertyListSerialization.propertyList(from: request.body, format: nil) as? [String: Any] {
                let type = command["type"] as? String ?? CWL("未知")
                log(CWL("CarPlay 命令：{1}；字段：{2}", [String(describing: type), String(describing: command.keys.sorted().joined(separator: ", "))]))
                if type == "requestUI" {
                    let url = (command["params"] as? [String: Any])?["url"] as? String
                    // "videoplayback:" is the parked-video player, which CarWithin does not offer.
                    if url == nil || url?.hasPrefix("videoplayback") == false {
                        // 车按钮不要有任何动作：当场认回画面资源，
                        // 不让手机把界面切走（见 claimUIResource）。
                        state.media?.claimUIResource()
                        DispatchQueue.main.async { [weak self] in self?.onCarUIRequested?() }
                    }
                }
                if type == "modesChanged", let params = command["params"] as? [String: Any] {
                    // 全量落盘（AUDIO-CLAIM-DIFF 方向 2）：resources 与
                    // appStates 一起打，不再只挑 resources 的三个数
                    // 字——appStates 是仲裁的另一半，以前整段被丢弃，
                    // 放歌瞬间手机那侧媒体状态翻没翻 true 在日志里无
                    // 据可查，认领载荷也没法对着手机原报文调。
                    var resourceText: [String] = []
                    var audioClaimedByPhone = false
                    for resource in params["resources"] as? [[String: Any]] ?? [] {
                        let fields = ["resourceID", "entity", "permanentEntity"].compactMap { key -> String? in
                            guard let value = resource[key] as? NSNumber else { return nil }
                            return "\(key)=\(value)"
                        }
                        resourceText.append(fields.joined(separator: ", "))
                        if (resource["resourceID"] as? NSNumber)?.intValue == 2,
                           let entity = (resource["entity"] as? NSNumber)?.intValue,
                           entity != 2 {
                            audioClaimedByPhone = true
                        }
                    }
                    var appStateText: [String] = []
                    for appState in params["appStates"] as? [[String: Any]] ?? [] {
                        let parts = appState.keys.sorted().map { key -> String in
                            if let value = appState[key] as? NSNumber { return "\(key)=\(value)" }
                            return "\(key)=\(String(describing: appState[key]))"
                        }
                        appStateText.append("{" + parts.joined(separator: ", ") + "}")
                    }
                    log(CWL("CarPlay 模式变化（modesChanged）全量：resources=[{1}]；appStates=[{2}]",
                            [resourceText.joined(separator: "; "), appStateText.joined(separator: "; ")]))
                    // 认领重申（方向 3）：音频资源被判给手机时回发一
                    // 次认领，把「只旁听」改成「参与仲裁」；节流与上
                    // 限在媒体会话内部管。
                    if audioClaimedByPhone {
                        state.media?.claimAudioResource(reason: "收到 modesChanged：音频资源 2 的 entity 被判给手机")
                    }
                }

            }
            return RTSPResponse()
        case ("TEARDOWN", _):
            // Log only protocol structure, never arbitrary values or credentials.
            if let values = try? PropertyListSerialization.propertyList(from: request.body, format: nil) as? [String: Any] {
                let types = (values["streams"] as? [[String: Any]])?.compactMap { ($0["type"] as? NSNumber)?.intValue }
                log("CarPlay TEARDOWN details: keys=\(values.keys.sorted().joined(separator: ",")); streams=\(types.map { String(describing: $0) } ?? "absent (entire media session)")")
            } else {
                log("CarPlay TEARDOWN details: no property-list dictionary; bytes=\(request.body.count)")
            }
            if try state.media?.teardown(request.body) == true {
                state.media = nil
                log("CarPlay TEARDOWN: all media stopped; control connection may remain open")
            }
            return RTSPResponse()
        default:
            log(CWL("尚未实现：{1} {2}；未占用会话", [String(describing: request.method), String(describing: request.target.prefix(80))]))
            return RTSPResponse(status: 501, reason: "Not Implemented")
        }
    }
    private func log(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onLog?(message) } }
}
