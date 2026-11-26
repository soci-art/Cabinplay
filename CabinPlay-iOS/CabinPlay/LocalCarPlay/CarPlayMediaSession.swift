// SPDX-License-Identifier: GPL-3.0-or-later
// Native event/video session adapted from PlayPort's AirPlaySession and media engine.
import Foundation
import CryptoKit
import AVFoundation

final class CarPlayMediaSession {
    private let queue: DispatchQueue
    private let secret: SymmetricKey
    private let peerAddress: String
    private var eventListener: MediaTCPListener?
    private var videoListener: MediaTCPListener?
    private var event: MediaTCPConnection?
    private var video: MediaTCPConnection?
    private var timing: MediaTiming?
    private var audio: [Int: CarPlayAudio] = [:]
    private let audioEnabled: Bool
    private let hevc: Bool
    private var eventCipher: ControlCipher?
    private var eventParser = RTSPParser(allowResponses: true)
    private var screen: ScreenStream?
    private var cseq = 0
    private var videoPackets = 0
    private var videoBytes = 0
    /// 音频认领（AUDIO-CLAIM-DIFF）的节流状态：待发标记、上次发出
    /// 时刻、本会话已发次数（上限 6 次，防与手机对刷）。
    private var claimPending = false
    private var lastClaimAt: DispatchTime?
    private var claimCount = 0
    private var claimCapLogged = false

    /// 主流（102）此刻是否建着：/info 的 appStates 据实报要用。
    var mediaStreamActive: Bool { audio[102] != nil }
    var onLog: ((String) -> Void)?
    var onBrowserAudio: ((Int, AVAudioPCMBuffer, UInt64) -> Void)?
    /// 编码音频 tap 转出：（流类型，裸 AAC 访问单元，主机微秒时间戳，格式）。
    var onEncodedAudio: ((Int, Data, UInt64, ReceiverAudioFormat) -> Void)?
    var onVideo: ((Data, VideoCodec) -> Void)?
    init(queue: DispatchQueue, secret: SymmetricKey, peerAddress: String, audioEnabled: Bool, hevc: Bool) {
        self.queue = queue; self.secret = secret; self.peerAddress = peerAddress
        self.audioEnabled = audioEnabled; self.hevc = hevc
    }
    func setup(_ data: Data) throws -> Data {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ProtocolError.malformed(CWL("SETUP 属性列表"))
        }
        onLog?(CWL("SETUP 字段：{1}", [String(describing: values.keys.sorted().joined(separator: ", "))]))
        var response: [String: Any] = [:]
        if let streams = values["streams"] as? [[String: Any]] {
            var replies: [[String: Any]] = []
            for stream in streams {
                guard let type = stream["type"] as? NSNumber else { throw ProtocolError.malformed(CWL("媒体流类型")) }
                onLog?(CWL("已请求媒体流 {1}，音频格式 {2}", [String(describing: type), String(describing: (stream["audioFormat"] as? NSNumber)?.stringValue ?? CWL("无"))]))
                if [100, 101, 102].contains(type.intValue), audioEnabled {
                    guard eventListener != nil, let connectionID = stream["streamConnectionID"] as? NSNumber,
                          let bits = stream["audioFormat"] as? NSNumber else { throw ProtocolError.malformed(CWL("音频 SETUP 字段")) }
                    let format = try ReceiverAudioFormat(bits: bits.uint64Value)
                    let audioType = (stream["audioType"] as? String ?? "").lowercased()
                    let requestsMicrophone = type.intValue == 100 && ["telephony", "speechrecognition", "default"].contains(audioType)
                        && ((stream["input"] as? Bool) == true || (stream["dataPort"] as? NSNumber)?.intValue ?? 0 > 0)
                    let microphonePort = requestsMicrophone ? (stream["dataPort"] as? NSNumber).flatMap { UInt16(exactly: $0.intValue) }.flatMap { $0 > 0 ? $0 : nil } : nil
                    audio.removeValue(forKey: type.intValue)?.stop()
                    let output = try CarPlayAudio(secret: secret, peerAddress: peerAddress,
                        connectionID: connectionID.uint64Value, format: format, microphonePort: microphonePort)
                    output.streamType = type.intValue
                    output.onLog = { [weak self] in self?.onLog?($0) }
                    // 音频桥只 tap 主流（102）的 AAC：裸帧多喂一份给车机
                    // 核心，本机扬声器播放保持原样。语音/通话流不走这条。
                    if type.intValue == 102, format.isAAC {
                        let streamType = type.intValue
                        output.onEncodedAudio = { [weak self] samples, stamp in
                            self?.onEncodedAudio?(streamType, samples, stamp, format)
                        }
                    }
                    // Keep calls and Siri on the iPhone; only intended playback goes to LAN viewers.
                    if let onBrowserAudio, !requestsMicrophone, !["telephony", "speechrecognition"].contains(audioType) {
                        let streamType = type.intValue
                        output.onBrowserAudio = { buffer, stamp in onBrowserAudio(streamType, buffer, stamp) }
                    }
                    audio[type.intValue] = output
                    replies.append(["type": type, "dataPort": output.dataPort, "controlPort": output.controlPort,
                                    "streamConnectionID": connectionID])
                    onLog?(CWL("音频流 {1} 已就绪：{2} {3} Hz / {4} 声道", [String(describing: type), String(describing: format.name), String(describing: format.sampleRate), String(describing: format.channels)]))
                    if type.intValue == 102 {
                        // 主流刚建好就认领一次：开场仲裁就是在这几秒里
                        // 把音频资源判给手机的，赶在定案前发言。
                        claimAudioResource(reason: "主流 102 已建流")
                    }
                    continue
                }
                guard type.intValue == 110, let connectionID = stream["streamConnectionID"] as? NSNumber else {
                    throw ProtocolError.malformed(CWL("不支持的媒体流类型 {1}", [String(describing: type)]))
                }
                guard eventListener != nil else { throw ProtocolError.malformed(CWL("初始 SETUP 前请求了屏幕流")) }
                video?.stop(); video = nil; videoListener?.stop()
                screen = ScreenStream(secret: secret, connectionID: connectionID.uint64Value)
                videoPackets = 0
                videoBytes = 0
                let listener = try MediaTCPListener(queue: queue, peerAddress: peerAddress); videoListener = listener
                listener.onConnection = { [weak self] connection in
                    guard let self, self.video == nil else { connection.stop(); return }
                    self.video = connection; self.onLog?(CWL("视频 TCP 通道已连接"))
                    connection.onBytes = { [weak self] bytes in
                        guard let self, let screen = self.screen else { return }
                        self.videoBytes += bytes.count
                        do {
                            for unit in try screen.append(bytes) {
                                self.videoPackets += 1
                                if self.videoPackets <= 2 {
                                    self.onLog?(CWL("已解码 {1} 访问单元 {2}（{3} 字节）", [String(describing: screen.codec.displayName), String(describing: self.videoPackets), String(describing: unit.count)]))
                                }
                                self.onVideo?(unit, screen.codec)
                            }
                        } catch { self.onLog?(CWL("视频数据被拒绝：{1}", [String(describing: error)])); throw error }
                    }
                    connection.onClose = { [weak self] in self?.video = nil; self?.onLog?(CWL("视频通道已关闭")) }
                    connection.start()
                    self.recoverFirstVideoUnit(on: connection, attempt: 1)
                }
                replies.append(["type": 110, "dataPort": listener.port])
                onLog?(CWL("视频监听器已在端口 {1} 就绪", [String(describing: listener.port)]))
            }
            response["streams"] = replies
        } else {
            guard eventListener == nil else { throw ProtocolError.malformed(CWL("重复的初始 SETUP")) }
            let timingPort = (values["timingPort"] as? NSNumber)?.intValue ?? 0
            guard (0...65535).contains(timingPort) else { throw ProtocolError.malformed(CWL("时钟同步端口")) }
            timing = try MediaTiming(queue: queue, peerAddress: peerAddress, peerPort: UInt16(timingPort))
            let listener = try MediaTCPListener(queue: queue, peerAddress: peerAddress); eventListener = listener
            listener.onConnection = { [weak self] connection in self?.acceptEvent(connection) }
            if let proposed = values["features"] as? [String] {
                onLog?(CWL("iPhone 提议的会话功能：{1}", [String(describing: proposed.joined(separator: ", "))]))
            }
            let features = hevc ? ["hevc", "viewAreas"] : ["viewAreas"]
            response = ["eventPort": listener.port, "timingPort": timing!.port, "enabledFeatures": features]
            onLog?(CWL("事件/时钟同步监听器已就绪：{1}/{2}", [String(describing: listener.port), String(describing: timing!.port)]))
        }
        return try PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0)
    }

    private func recoverFirstVideoUnit(on connection: MediaTCPConnection, attempt: Int) {
        queue.asyncAfter(deadline: .now() + (attempt == 1 ? 2 : 3)) { [weak self, weak connection] in
            guard let self, let connection, self.video === connection, self.videoPackets == 0 else { return }
            let sent = self.requestKeyFrame()
            self.onLog?(CWL("等待首帧：视频 TCP 已读 {1} 字节，第 {2} 次关键帧请求{3}", [String(describing: self.videoBytes), String(describing: attempt), String(describing: sent ? CWL("已发送") : CWL("未发送"))]))
            if attempt < 2 { self.recoverFirstVideoUnit(on: connection, attempt: attempt + 1) }
        }
    }
    private func acceptEvent(_ connection: MediaTCPConnection) {
        guard event == nil else { connection.stop(); return }
        event = connection
        eventCipher = ControlCipher(readKey: PairVerify.derive(secret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"),
            writeKey: PairVerify.derive(secret, salt: "Events-Salt", info: "Events-Write-Encryption-Key"))
        onLog?(CWL("加密事件通道已连接"))
        connection.onBytes = { [weak self, weak connection] bytes in
            guard let self, let connection, let cipher = self.eventCipher else { return }
            for request in try self.eventParser.append(cipher.receive(bytes)) {
                if request.method.hasPrefix("RTSP/") || request.method.hasPrefix("HTTP/") {
                    // Answer to one of our commands; only failures are worth a log line.
                    if request.target != "200" { self.onLog?(CWL("iPhone 拒绝了事件命令（状态 {1}，CSeq {2}）", [String(describing: request.target), String(describing: request.headers["cseq"] ?? "?")])) }
                    continue
                }
                try connection.send(cipher.encrypt(RTSPResponse().encoded(for: request)))
            }
        }
        connection.onClose = { [weak self] in self?.event = nil; self?.eventCipher = nil; self?.onLog?(CWL("事件通道已关闭")) }
        connection.start()
        flushNightMode()
        flushPendingClaim()
    }
    var hasEventChannel: Bool { event != nil && eventCipher != nil }
    /// Full multitouch state: every slot is reported each time; missing slots report up.
    func touch(_ contacts: [CarPlayInfo.TouchContact]) {
        _ = sendHID(CarPlayInfo.HID.touch, CarPlayInfo.touchReport(contacts), label: CWL("触控"))
    }
    /// Momentary HID key: the press report followed by the all-released report.
    func pressHID(_ uuid: String, _ report: Data, release: Data) {
        guard sendHID(uuid, report, label: CWL("按键")) else { onLog?(CWL("按键未发送：事件通道尚未连接")); return }
        _ = sendHID(uuid, release, label: CWL("按键"))
    }
    func requestSiri() {
        guard sendCommand(["type": "requestSiri", "params": ["siriAction": 2]], label: "Siri") else {
            onLog?(CWL("Siri 未发送：事件通道尚未连接")); return
        }
        _ = sendCommand(["type": "requestSiri", "params": ["siriAction": 3]], label: "Siri")
    }
    /// Latest wanted day/night state; kept until the event channel can carry it.
    private var pendingNightMode: Bool?
    func setNightMode(_ night: Bool) {
        pendingNightMode = night
        flushNightMode()
    }
    private func flushNightMode() {
        guard let night = pendingNightMode, hasEventChannel else { return }
        if sendCommand(["type": "setNightMode", "params": ["nightMode": night]], label: CWL("夜间模式")) {
            pendingNightMode = nil
            onLog?(CWL("已通知 iPhone 切换为{1}外观", [String(describing: night ? CWL("夜间") : CWL("白天"))]))
        }
    }
    private func sendHID(_ uuid: String, _ report: Data, label: String) -> Bool {
        sendCommand(["type": "hidSendReport", "uuid": uuid, "hidReport": report], label: label)
    }
    /// 主动认领音频资源（AUDIO-CLAIM-DIFF 方向 1＋3）：经事件通道
    /// 发与手机通知同构的 modesChanged——音频资源（resourceID 2）
    /// 的 entity/permanentEntity 指向配件（2）、媒体 appState 报活
    /// 动。真车机上对应这个动作的是用户按车机音源键；我方以前只声
    /// 明、只旁听、从不发言，仲裁开场几秒就定案、放歌永不重谈。
    /// 时机：主流 102 建流后发一次；之后每次收到「R2 被判给手机」
    /// 的通知（由 NativeReceiver 转交）节流重申——间隔 ≥8 秒、单
    /// 会话最多 6 次，别和手机对刷。通道没连上时记待发，通道一连
    /// 上就补发。验法看接收端日志三行：认领后手机回的 modesChanged
    /// 里 R2 entity 是否变回 2、102 是否被 SETUP 且不紧跟
    /// TEARDOWN、放歌时音频「数据包=」计数是否涨起来。
    func claimAudioResource(reason: String) {
        let now = DispatchTime.now()
        if let last = lastClaimAt,
           now.uptimeNanoseconds - last.uptimeNanoseconds < 8_000_000_000 {
            claimPending = true
            return
        }
        guard claimCount < 6 else {
            if !claimCapLogged {
                claimCapLogged = true
                onLog?(CWL("音频认领：本会话已认领满 6 次，手机仍不放行就不再重申了（后续看蓝牙放行那条路）"))
            }
            return
        }
        let payload: [String: Any] = ["type": "modesChanged", "params": [
            "resources": [["resourceID": 2, "entity": 2, "permanentEntity": 2]],
            "appStates": [["appStateID": 2, "state": true]],
        ]]
        if sendCommand(payload, label: CWL("音频认领")) {
            claimCount += 1
            lastClaimAt = now
            claimPending = false
            onLog?(CWL("音频认领：已发 modesChanged 认领（第 {1} 次，{2}）——音频资源 2 的 entity/permanentEntity 报配件（2）、媒体 appState 报活动；等手机回 modesChanged 看 R2 归属变没变", [String(describing: claimCount), reason]))
        } else {
            claimPending = true
            onLog?(CWL("音频认领：事件通道还没连上，先记下待发（{1}）", [reason]))
        }
    }
    /// 事件通道刚连上时补发待发认领（绕过节流：这是通道就绪后的
    /// 第一次机会，建流那次多半就卡在这里）。
    private func flushPendingClaim() {
        guard claimPending else { return }
        lastClaimAt = nil
        claimAudioResource(reason: "事件通道已连上，补发待发认领")
    }
    /// Asks the iPhone to encode an IDR/IRAP picture now. CarPlay only sends one keyframe at stream
    /// start, so every decoder recovery and every late browser viewer depends on this command.
    func requestKeyFrame() -> Bool { sendCommand(["type": "forceKeyFrame"], label: CWL("关键帧请求")) }
    /// Car-initiated command on the encrypted event channel (same framing as HID reports).
    private func sendCommand(_ command: [String: Any], label: String) -> Bool {
        guard let event, let eventCipher else { return false }
        do {
            let body = try PropertyListSerialization.data(fromPropertyList: command, format: .binary, options: 0)
            cseq += 1
            let header = "POST /command RTSP/1.0\r\nContent-Type: application/x-apple-binary-plist\r\nContent-Length: \(body.count)\r\nCSeq: \(cseq)\r\n\r\n"
            try event.send(eventCipher.encrypt(Data(header.utf8) + body))
            return true
        } catch { onLog?(CWL("{1}写入失败：{2}", [String(describing: label), String(describing: error)])); event.stop(); return false }
    }
    func stop() {
        audio.values.forEach { $0.stop() }; audio.removeAll()
        CarPlayAudio.endMediaSession()
        eventListener?.stop(); videoListener?.stop(); event?.stop(); video?.stop(); timing?.stop()
        eventListener = nil; videoListener = nil; event = nil; video = nil; timing = nil; screen = nil; eventCipher = nil
    }
    func feedback() throws -> Data? {
        guard !audio.isEmpty, let timing else { return nil }
        let streams = audio.map { $0.value.feedback(type: $0.key, ntp: timing.timestamp()) }
        return try PropertyListSerialization.data(fromPropertyList: ["streams": streams], format: .binary, options: 0)
    }
    /// A stream-specific teardown must not terminate the other live streams.
    func teardown(_ body: Data) throws -> Bool {
        guard !body.isEmpty, let values = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
              let streams = values["streams"] as? [[String: Any]] else { stop(); return true }
        for stream in streams {
            guard let type = stream["type"] as? NSNumber else { continue }
            if type.intValue == 110 { video?.stop(); video = nil; videoListener?.stop(); videoListener = nil; screen = nil }
            audio.removeValue(forKey: type.intValue)?.stop()
        }
        return false
    }
    deinit { stop() }
}
