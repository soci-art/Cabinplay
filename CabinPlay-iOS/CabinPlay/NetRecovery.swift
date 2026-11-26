// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 会话期网络变化与音频快照。
//
// - NetworkChangeMonitor：连上之后再换网（车机热点重启、Wi-Fi 掉线重连、
//   手动切网）现在没人管，clink 会一直对着旧地址发呆。这里用 NWPathMonitor
//   监听主接口变化，把「当前地址变了」交给上层决定是否重连。
// - AudioDiagnostics：出画时打一行音频快照（路由、A2DP、模式、目标尺寸），
//   方便一轮日志里直接看清「这轮声音可能去哪」。

import Foundation
import Network
import AVFoundation

final class NetworkChangeMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "cabinplay.network.monitor")
    private var lastSignature: String?
    private var onChange: ((String) -> Void)?

    /// 当前主接口的地址签名（接口名 + IPv4 列表），用于判定「地址变了」。
    static func signature() -> String {
        let interfaces = ReceiverConfiguration.localIPv4Addresses().sorted()
        return interfaces.joined(separator: ",")
    }

    func start(onChange: @escaping (String) -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        lastSignature = Self.signature()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = Self.signature()
            guard path.status == .satisfied, signature != self.lastSignature else { return }
            self.lastSignature = signature
            self.onChange?(signature)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        onChange = nil
    }

    deinit { monitor.cancel() }
}

enum AudioDiagnostics {
    /// 一行音频快照：路由、A2DP、输出模式、画布尺寸。
    static func snapshot(width: Int, height: Int) -> String {
        let route = AudioOutputPolicy.routeSummary
        let a2dp = AudioOutputPolicy.hasA2DP() ? "在线" : "不在线"
        return "音频快照：路由 [\(route)]，A2DP \(a2dp)，模式 \(AudioOutputPolicy.mode.rawValue)，画布 \(width)×\(height)"
    }
}
