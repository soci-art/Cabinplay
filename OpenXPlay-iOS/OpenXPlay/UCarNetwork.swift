// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// UCarNetworkJoiner — ServerInfo 之后的组网步（P2P-AND-PREVIEW-DIFF A 部分）。
//
// CarWith 的顺序（y8/h.java、P2pController.java 实证）：ServerInfo 到手 →
// 加入车机给的网络 → 车机 IP 取组主地址 → 连 57209 鉴权。ServerInfo 里
// 的 ipAddress 安卓根本不用（只打日志），所以本车 ServerInfo 没这个字段
// 是常态，不能在那儿停住。
//
// iOS 等价路径：把 DIRECT- 组主当普通 WPA2 热点，用
// NEHotspotConfigurationManager 程序化加入（需 HotspotConfiguration
// entitlement + 系统确认框）；失败/超时则明示网络名与密码引导手动加入，
// 并持续轮询检测。入网判据（两条路径共用）：本机 en0 地址落入目标网段
// ——P2P 组恒为 192.168.49.0/24、车机（组主）恒为 192.168.49.1（AOSP
// P2P 框架固定值，多源实证）；ServerInfo 带了 ipAddress 时改用它并以
// 同 /24 为判据。已在目标网段内（第二轮快速通道）直接跳过入网。

import Foundation
import NetworkExtension
import SystemConfiguration.CaptiveNetwork

final class UCarNetworkJoiner {
    var onLog: ((String) -> Void)?
    /// 状态卡用的一句话状态（入网中/失败原因），主线程回调。
    var onStatus: ((String) -> Void)?

    struct Result {
        let localIP: String
        let carIP: String
    }

    private var pollTimer: Timer?
    private var deadline: Date?
    private var warnedSlow = false
    private var pendingCarIP: String?
    private var pendingSSID: String?
    private var completion: ((Result?) -> Void)?
    private var finished = false

    /// P2P 组主恒定地址（AOSP Wi-Fi Direct 框架固定，诊断 A3.2 实证链）。
    static let p2pSubnetPrefix = "192.168.49."
    static let p2pGroupOwnerIP = "192.168.49.1"

    func cancel() {
        pollTimer?.invalidate()
        pollTimer = nil
        completion = nil
        finished = true
    }

    /// 当前连接的 Wi-Fi 名（取不到返回 nil：无 wifi-info 权限时就是 nil，
    /// 只按网段判定，不当失败处理）。
    static func currentSSID() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for interface in interfaces {
            if let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: Any],
               let ssid = info[kCNNetworkInfoKeySSID as String] as? String, !ssid.isEmpty {
                return ssid
            }
        }
        return nil
    }

    static func isValidIPv4(_ text: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, text, &addr) == 1
    }

    private static func sameSlash24(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: "."), pb = b.split(separator: ".")
        guard pa.count == 4, pb.count == 4 else { return false }
        return pa[0] == pb[0] && pa[1] == pb[1] && pa[2] == pb[2]
    }

    /// 入网主入口。ssid/psk 来自 ServerInfo；bleCarIP 是 ServerInfo 的
    /// ipAddress（本车没有，安卓也不用它；有就优先采用）。
    func join(ssid: String?, psk: String?, bleCarIP: String?,
              completion: @escaping (Result?) -> Void) {
        cancel()
        finished = false
        warnedSlow = false
        self.completion = completion

        let carIP = (bleCarIP?.isEmpty == false) ? bleCarIP! : Self.p2pGroupOwnerIP
        pendingCarIP = carIP
        pendingSSID = ssid

        let localNow = ReceiverConfiguration.wifiIPv4Address()
        let ssidNow = Self.currentSSID()
        onLog?("UCar 入网：开始组网步——目标网络「\(ssid ?? "?")」，车机地址候选 \(carIP)（\(bleCarIP?.isEmpty == false ? "ServerInfo 直接给的 ipAddress" : "P2P 组主恒定地址")）；当前 Wi-Fi「\(ssidNow ?? "取不到")」，本机地址 \(localNow ?? "无")")

        // 快速通道：已经在目标网段里（第二轮 BLE 时手机还连着 DIRECT- 组），
        // 对应 CarWith 的 checkIsCarWifi 捷径，直接跳过入网。
        if let localNow, matchesTarget(localIP: localNow, carIP: carIP, ssid: ssid, currentSSID: ssidNow) {
            onLog?("UCar 入网：本机地址 \(localNow) 已在车机网段内（车机 \(carIP)），跳过入网步骤，直接往下走")
            finish(localIP: localNow, carIP: carIP)
            return
        }

        guard let ssid, !ssid.isEmpty else {
            onLog?("UCar 入网：ServerInfo 没给网络名（ssid），又不在车机网段里，没法入网——流程停在这里，把日志发回来看")
            onStatus?("入网失败：车机没给网络名")
            finish(nil)
            return
        }

        if ssidNow == ssid {
            onLog?("UCar 入网：系统显示已连在「\(ssid)」上，但本机地址还没落入车机网段，等 DHCP 分配")
            startPolling()
            return
        }

        // 程序化加入：NEHotspotConfiguration（系统会弹确认框，用户点「加入」）。
        onStatus?("入网中：请在系统弹窗里点「加入」连上车机网络")
        onLog?("UCar 入网：请系统加入「\(ssid)」——会弹系统确认框，点「加入」才执行；若报 entitlement 相关错误，说明签名描述文件不带 HotspotConfiguration 能力，改走手动加入")
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: psk ?? "", isWEP: false)
        configuration.joinOnce = false
        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            guard let self, !self.finished else { return }
            if let error {
                let nsError = error as NSError
                if nsError.domain == NEHotspotConfigurationErrorDomain,
                   nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    self.onLog?("UCar 入网：系统说已经连在这个网络上了，等地址落入车机网段")
                } else if nsError.domain == NEHotspotConfigurationErrorDomain,
                          nsError.code == NEHotspotConfigurationError.userDenied.rawValue {
                    self.onLog?("UCar 入网：系统弹窗被拒绝了。改走手动：去系统设置→Wi-Fi 连「\(ssid)」\((psk?.isEmpty == false) ? "，密码就是蓝牙带回的那个（已存下）" : "")，连上后这边会自动往下走")
                    self.onStatus?("入网中：请去系统设置手动连「\(ssid)」")
                } else {
                    self.onLog?("UCar 入网：程序化加入失败（\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)）。改走手动：去系统设置→Wi-Fi 连「\(ssid)」，连上后这边会自动往下走")
                    self.onStatus?("入网中：请去系统设置手动连「\(ssid)」")
                }
            } else {
                self.onLog?("UCar 入网：系统已接受加入「\(ssid)」，等本机地址落入车机网段")
            }
            self.startPolling()
        }
        // apply 的完成回调在个别系统版本上可能迟迟不回，轮询兜底先起着。
        startPolling()
    }

    /// 入网判据（诊断 A3.2 口径）：本机地址与车机地址同 /24——P2P 情形
    /// 即本机落入 192.168.49.0/24、车机=组主 192.168.49.1。当前 SSID
    /// 取得到且 ServerInfo 也给了 ssid 时再加一道 SSID 一致校验；
    /// SSID 取不到（无 wifi-info 权限）就只认网段，不当失败。
    private func matchesTarget(localIP: String, carIP: String, ssid: String?, currentSSID: String?) -> Bool {
        guard Self.sameSlash24(localIP, carIP) else { return false }
        if let ssid, let currentSSID { return ssid == currentSSID }
        return true
    }

    private func startPolling() {
        pollTimer?.invalidate()
        deadline = Date().addingTimeInterval(90)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollOnce()
    }

    private func pollOnce() {
        guard !finished, let carIP = pendingCarIP else { return }
        if let local = ReceiverConfiguration.wifiIPv4Address(),
           matchesTarget(localIP: local, carIP: carIP, ssid: pendingSSID,
                          currentSSID: Self.currentSSID()) {
            onLog?("UCar 入网：入网成功——本机地址 \(local) 已落入车机网段，车机地址定为 \(carIP)（组主地址；推导：本机 \(local) 与 \(carIP) 同 /24\(carIP == Self.p2pGroupOwnerIP ? "，且 192.168.49.1 是 P2P 组主恒定地址" : "")）")
            finish(localIP: local, carIP: carIP)
            return
        }
        if let deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining < 65, !warnedSlow {
                warnedSlow = true
                onLog?("UCar 入网：等了约 25 秒还没入网——蓝牙那 30 秒时间窗可能已经过了，但入网本身继续等；真连上后即使蓝牙已断开也会接着启 CarLink（只是 …103 回告可能写不出去了）。若是第一轮赶不上，下一轮蓝牙连接时手机已在车机网络里，会直接走快速通道")
            }
            if remaining <= 0 {
                onLog?("UCar 入网：等了 90 秒本机地址仍没落入车机网段（车机 \(carIP)），入网判失败。确认手机 Wi-Fi 是否连在车机网络上，再重点一次「连接车机」")
                onStatus?("入网失败：90 秒没连上车机网络")
                finish(nil)
            }
        }
    }

    private func finish(localIP: String, carIP: String) {
        let result = Result(localIP: localIP, carIP: carIP)
        finish(result)
    }

    private func finish(_ result: Result?) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        pollTimer = nil
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async { completion?(result) }
    }
}
