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
            core.onTouch?(screen, x, y, pressed != 0)
            // 车机触摸直接回灌给当前 CarPlay 会话
            _ = oxp_touch(screen, x, y, UInt32(pressed))
        }
        callbacks.on_key = { context, code, down in
            guard let context else { return }
            let core = Unmanaged<CarLinkCore>.fromOpaque(context).takeUnretainedValue()
            core.onKey?(code, down != 0)
            _ = oxp_key(code, UInt32(down))
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
