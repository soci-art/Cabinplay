// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// CarLinkCore — Swift side of the CarLink client (oxp-clink-ios).
// Same callback pattern as CarPlayCore: C function pointers carry an opaque
// pointer back to the instance.

import Foundation
import Darwin

final class CarLinkCore {
    static let shared = CarLinkCore()

    enum State: UInt16 {
        case idle = 0, connecting = 1, authenticating = 2, negotiating = 3, playing = 4, ended = 5

        var text: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "连接车机…"
            case .authenticating: return "配对认证…"
            case .negotiating: return "协商画面…"
            case .playing: return "已连接，正在输出"
            case .ended: return "会话已结束"
            }
        }
    }

    var onLog: ((String) -> Void)?
    var onState: ((State) -> Void)?
    var onTouch: ((UInt32, Double, Double, Bool) -> Void)?
    /// 校准捕获回调：捕获模式下核心只报原始坐标（触控面归一化）走
    /// 这里，正常触控通道（onTouch）同时静默，绝不转发给 iOS。
    var onTouchCapture: ((Double, Double) -> Void)?
    var onKey: ((UInt32, Bool) -> Void)?

    private(set) var running = false

    private init() {}

    func start(headUnit: String, local: String, pin: String, stateDir: String,
               width: UInt32, height: UInt32,
               deviceID: String, model: String) -> Bool {
        if running { return true }

        // 鉴权请求里报的手机身份：id 与蓝牙 ClientInfo 同源（持久 6 字符 ID），
        // model 用机型市场名，productName 固定 CabinPlay。
        deviceID.withCString { idPtr in
            model.withCString { modelPtr in
                "CabinPlay".withCString { productPtr in
                    clink_set_identity(idPtr, modelPtr, productPtr)
                }
            }
        }

        var callbacks = ClinkCallbacks()
        callbacks.context = Unmanaged.passUnretained(self).toOpaque()
        callbacks.on_state = { context, value in
            guard let context else { return }
            let core = Unmanaged<CarLinkCore>.fromOpaque(context).takeUnretainedValue()
            core.handleState(value)
        }
        callbacks.on_error = { context, bytes, length in
            guard let context, let bytes else { return }
            let text = String(decoding: Data(bytes: bytes, count: length), as: UTF8.self)
            Unmanaged<CarLinkCore>.fromOpaque(context).takeUnretainedValue()
                .onLog?("CarLink 错误：\(text)")
        }
        callbacks.on_touch = { context, screen, x, y, pressed in
            guard let context else { return }
            let core = Unmanaged<CarLinkCore>.fromOpaque(context).takeUnretainedValue()
            // 车机触摸回送本机 CarPlay 会话（由 ContentView 接到 LocalCarPlaySession）。
            core.onTouch?(screen, x, y, pressed != 0)
        }
        callbacks.on_touch_capture = { context, x, y in
            guard let context else { return }
            let core = Unmanaged<CarLinkCore>.fromOpaque(context).takeUnretainedValue()
            core.onTouchCapture?(x, y)
        }
        callbacks.on_key = { context, code, down in
            guard let context else { return }
            let core = Unmanaged<CarLinkCore>.fromOpaque(context).takeUnretainedValue()
            core.onKey?(code, down != 0)
        }
        callbacks.on_log = { context, bytes, length in
            guard let context, let bytes else { return }
            let text = String(decoding: Data(bytes: bytes, count: length), as: UTF8.self)
            Unmanaged<CarLinkCore>.fromOpaque(context).takeUnretainedValue().onLog?(text)
        }

        let code = headUnit.withCString { head in
            local.withCString { localIp in
                pin.withCString { pinText in
                    stateDir.withCString { state in
                        clink_start(head, localIp, pinText, state, width, height, callbacks)
                    }
                }
            }
        }
        running = code == 0
        if !running {
            onLog?("CarLink 连接失败（错误码 \(code)）")
        }
        return running
    }

    func stop() {
        guard running else { return }
        _ = clink_stop()
        running = false
    }

    // MARK: 触控换算（固定居中模型）

    /// 触控换算固定居中模型（校准功能已整套撤销：描边校准页、按车
    /// 校准记录、模式切换都不再有）：每轮连接开始时把居中模式推给
    /// 核心（核心侧 FFI 也已钉死居中，任何入参都回不到按校准/直
    /// 通），并清掉核心里可能残留的校准矩形，双保险。
    func applyTouchMode() {
        clink_set_touch_mode(1) // 1 = 居中模型（核心 FFI 模式编号）
        clink_clear_touch_calibration()
    }

    /// 出画后让核心重打一行触控定锚（声明几何＋当前换算方式）：
    /// 日志中段导出时开头的定锚行会被滚掉，这一行为新会话兜底。
    func logTouchAnchor() {
        clink_log_touch_anchor()
    }

    /// 把解码配置（avcC/hvcC 记录）推给车机；必须先于帧调用。codec：1=H.264，2=H.265。
    /// 返回 false 表示会话没在跑或核心拒绝（核心内部还要求会话已进入出画状态）。
    @discardableResult
    func pushConfig(codec: UInt32, config: Data, fps: Double) -> Bool {
        guard running, !config.isEmpty else { return false }
        let code = config.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -99 }
            return clink_push_config(0, codec, base.assumingMemoryBound(to: UInt8.self),
                                     config.count, fps)
        }
        return code == 0
    }

    /// 把一帧已编码画面（Annex-B）推给车机。pts 用微秒，keyFrame 标关键帧。
    @discardableResult
    func pushFrame(_ data: Data, ptsMicros: Int64, keyFrame: Bool) -> Bool {
        guard running, !data.isEmpty else { return false }
        let code = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -99 }
            return clink_push_frame(0, base.assumingMemoryBound(to: UInt8.self),
                                    data.count, ptsMicros, keyFrame ? 1 : 0)
        }
        return code == 0
    }

    /// 登记主流媒体音频格式（AAC-LC）：必须先于该流的音频包调用。核心只
    /// 收 48000 Hz/2 声道、config 恰为 [0x11, 0x90] 的格式，其余会被核心
    /// 以 unsupported_media_audio 诊断丢弃。
    @discardableResult
    func pushAudioFormat(stream: UInt32, sampleRate: UInt32, channels: UInt32, config: Data) -> Bool {
        guard running else { return false }
        let code = config.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else {
                return clink_push_audio_format(stream, sampleRate, channels, nil, 0)
            }
            return clink_push_audio_format(stream, sampleRate, channels,
                                           base.assumingMemoryBound(to: UInt8.self), config.count)
        }
        return code == 0
    }

    /// 把一个裸 AAC 访问单元（不带 ADTS 头，核心自己加）推给车机。
    /// pts 与视频帧共用同一条单调时间线（微秒）。
    @discardableResult
    func pushAudioPacket(stream: UInt32, data: Data, ptsMicros: Int64) -> Bool {
        guard running, !data.isEmpty else { return false }
        let code = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -99 }
            return clink_push_audio_packet(stream, base.assumingMemoryBound(to: UInt8.self),
                                            data.count, ptsMicros)
        }
        return code == 0
    }

    private func handleState(_ value: UInt16) {
        let state = State(rawValue: value) ?? .ended
        if state == .ended || state == .idle { running = false }
        onState?(state)
        onLog?("CarLink 状态：\(state.text)")
    }
}

/// Local IPv4 addresses, so the CarLink form can prefill the one that sits on
/// the head unit's Wi-Fi network.
enum LocalNetwork {
    static func ipv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        var cursor = first
        while true {
            let interface = cursor.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var text = in_addr()
                    text.s_addr = raw.s_addr
                    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 16)
                    defer { buffer.deallocate() }
                    inet_ntop(AF_INET, &text, buffer, 16)
                    result.append(String(cString: buffer))
                }
            }
            guard let next = interface.ifa_next else { break }
            cursor = next
        }
        return result
    }
}
