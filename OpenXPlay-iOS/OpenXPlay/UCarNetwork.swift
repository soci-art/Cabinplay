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
// 并持续轮询检测。
//
// 入网判据（2026-11-26 改，13:50 真机日志教训）：旧判据死认 192.168.49.0/24
// ——apply 明明成功了，本机地址却一直不落进那个网段，日志再无下文，分不清
// 是车机 GO 根本不用这个网段、还是关联被拒没拿到地址。新判据认实况：
// 入网前先记下 en0 全部 IPv4 作基线，入网成功 = 出现基线之外的新私有地址
// （离开原来的 192.168.43.x 即算），或系统 SSID 已是目标网络。等待期间每
// 1.5 秒打一行实况（en0 地址全量 + 当前 SSID + 与基线对比），下一份日志
// 一眼能定性「没连上／连上了、网段是 X」。
//
// 车机地址不再写死：入网后按实际网段推导候选——ServerInfo 的 ipAddress
// （有才算）→ 本机新网段的 .1（DHCP 网关惯例）→ 192.168.49.1（P2P 组主
// 恒定地址，与首选不同才试）。候选只负责排序，逐个由上层用 clink 真
// 连接去试（14:03 真机日志教训：曾用 NWConnection 只连不发数据的试探
// 连接选地址，试探连通后紧接着 clink 真连接被 Connection refused——
// 疑似试探连接占掉了车机鉴权口的唯一连接名额，试探一断车机就关口。
// 从此禁止任何对 57209 的裸 TCP 试探）。

import Foundation
import NetworkExtension
import SystemConfiguration.CaptiveNetwork

final class UCarNetworkJoiner {
    var onLog: ((String) -> Void)?
    /// 状态卡用的一句话状态（入网中/失败原因），主线程回调。
    var onStatus: ((String) -> Void)?

    struct Result {
        let localIP: String
        /// 车机地址候选（已排序、已去重）：由上层逐个启 clink 真连接试，
        /// 谁先走到协商/出画谁就是车机地址。本类不再做任何 TCP 试探。
        let candidates: [String]
    }

    private var pollTimer: Timer?
    private var deadline: Date?
    private var warnedSlow = false
    private var pendingSSID: String?
    private var pendingBleCarIP: String?
    /// 入网前 en0 上的全部 IPv4（基线）。新地址 = 不在基线里的私有地址。
    private var baselineAddresses: Set<String> = []
    /// apply 回了 alreadyAssociated：系统认定已连在目标网络上，轮询时可
    /// 直接采信当前地址（SSID 读不到时这是唯一的「已入网」证据）。
    private var applyClaimedAssociated = false
    private var didJoin = false
    private var completion: ((Result?) -> Void)?
    private var finished = false

    /// P2P 组主恒定地址（AOSP Wi-Fi Direct 框架固定，诊断 A3.2 实证链）。
    /// 现在只是车机地址候选之一，不再是入网判据。
    static let p2pGroupOwnerIP = "192.168.49.1"
    private static let p2pSubnetPrefix = "192.168.49."

    func cancel() {
        pollTimer?.invalidate()
        pollTimer = nil
        completion = nil
        finished = true
    }

    /// 当前连接的 Wi-Fi 名（取不到返回 nil：无 wifi-info 权限时就是 nil，
    /// 只作辅助证据，不当失败处理）。
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

    /// RFC1918 私有地址（10/8、172.16/12、192.168/16）。169.254 链路本地
    /// 不算——那是没拿到 DHCP 地址的表现，不是入网成功。
    static func isPrivateIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        return false
    }

    /// 某地址所在 /24 的 .1（DHCP 网关惯例地址）。
    static func subnetDotOne(_ ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).1"
    }

    private static func sameSlash24(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: "."), pb = b.split(separator: ".")
        guard pa.count == 4, pb.count == 4 else { return false }
        return pa[0] == pb[0] && pa[1] == pb[1] && pa[2] == pb[2]
    }

    /// en0 当前全部 IPv4（已排除链路本地与未分配地址）。
    private static func en0Addresses() -> [String] {
        ReceiverConfiguration.localIPv4Addresses(interface: "en0")
    }

    /// 入网主入口。ssid/psk 来自 ServerInfo；bleCarIP 是 ServerInfo 的
    /// ipAddress（本车没有，安卓也不用它；有就作车机地址首选候选）。
    func join(ssid: String?, psk: String?, bleCarIP: String?,
              completion: @escaping (Result?) -> Void) {
        cancel()
        finished = false
        warnedSlow = false
        didJoin = false
        applyClaimedAssociated = false
        self.completion = completion

        pendingSSID = ssid
        pendingBleCarIP = (bleCarIP?.isEmpty == false) ? bleCarIP : nil

        let baseline = Self.en0Addresses()
        baselineAddresses = Set(baseline)
        let ssidNow = Self.currentSSID()
        onLog?("UCar 入网：开始组网步——目标网络「\(ssid ?? "?")」；入网前基线地址 [\(baseline.joined(separator: "、"))]，当前 Wi-Fi「\(ssidNow ?? "取不到")」。判据：出现基线外的新私有地址、或已连在目标网络上，即算入网（不再死认 192.168.49 网段）")

        // 快速通道一：系统显示已经连在目标网络上（第二轮 BLE 时手机还
        // 连着 DIRECT- 组），对应 CarWith 的 checkIsCarWifi 捷径。
        if let ssid, !ssid.isEmpty, ssidNow == ssid,
           let local = baseline.first(where: { Self.isPrivateIPv4($0) }) {
            onLog?("UCar 入网：系统显示已连在目标网络「\(ssid)」上，跳过入网步骤（快速通道）")
            joined(localIP: local, via: "已连在目标网络上（SSID 一致）")
            return
        }
        // 快速通道二：本机地址已在 P2P 组网段里（上一轮入的网还没断）。
        if let local = baseline.first(where: { $0.hasPrefix(Self.p2pSubnetPrefix) }) {
            onLog?("UCar 入网：本机地址 \(local) 已在 P2P 组网段（\(Self.p2pSubnetPrefix)0/24）里，跳过入网步骤（快速通道）")
            joined(localIP: local, via: "已在 P2P 组网段内")
            return
        }

        guard let ssid, !ssid.isEmpty else {
            onLog?("UCar 入网：ServerInfo 没给网络名（ssid），又不在车机网络里，没法入网——流程停在这里，把日志发回来看")
            onStatus?("入网失败：车机没给网络名")
            finish(nil)
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
                    self.applyClaimedAssociated = true
                    self.onLog?("UCar 入网：系统说已经连在这个网络上了，等地址确认")
                } else if nsError.domain == NEHotspotConfigurationErrorDomain,
                          nsError.code == NEHotspotConfigurationError.userDenied.rawValue {
                    self.onLog?("UCar 入网：系统弹窗被拒绝了。改走手动：去系统设置→Wi-Fi 连「\(ssid)」\((psk?.isEmpty == false) ? "，密码就是蓝牙带回的那个（已存下）" : "")，连上后这边会自动往下走")
                    self.onStatus?("入网中：请去系统设置手动连「\(ssid)」")
                } else {
                    self.onLog?("UCar 入网：程序化加入失败（\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)）。改走手动：去系统设置→Wi-Fi 连「\(ssid)」，连上后这边会自动往下走")
                    self.onStatus?("入网中：请去系统设置手动连「\(ssid)」")
                }
            } else {
                self.onLog?("UCar 入网：系统已接受加入「\(ssid)」，等本机地址变化确认入网（实况每 1.5 秒一行）")
            }
            self.startPolling()
        }
        // apply 的完成回调在个别系统版本上可能迟迟不回，轮询兜底先起着。
        startPolling()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        deadline = Date().addingTimeInterval(90)
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollOnce()
    }

    private func pollOnce() {
        guard !finished, !didJoin else { return }
        let addresses = Self.en0Addresses()
        let ssidNow = Self.currentSSID()
        let newAddresses = addresses.filter {
            !baselineAddresses.contains($0) && Self.isPrivateIPv4($0)
        }
        // 入网实况（每 1.5 秒一行）：地址全量 + SSID + 与基线对比，
        // 下一份日志一眼定性「没连上／连上了、网段是 X」。
        onLog?("UCar 入网实况：en0 地址 [\(addresses.joined(separator: "、"))]，当前 Wi-Fi「\(ssidNow ?? "取不到")」，基线 [\(baselineAddresses.sorted().joined(separator: "、"))]，基线外新地址 \(newAddresses.isEmpty ? "无" : "[\(newAddresses.joined(separator: "、"))]")")

        // 成功判据一：出现基线外的新私有地址（离开原网络、拿到新 DHCP）。
        if let local = newAddresses.first {
            joined(localIP: local, via: "出现基线外新地址（已离开入网前的网络）")
            return
        }
        // 成功判据二：SSID 已是目标网络（地址可能与基线同段，靠 SSID 认）。
        if let ssid = pendingSSID, !ssid.isEmpty, ssidNow == ssid,
           let local = addresses.first(where: { Self.isPrivateIPv4($0) }) {
            joined(localIP: local, via: "当前 Wi-Fi 已是目标网络「\(ssid)」")
            return
        }
        // 成功判据三：系统在 apply 时明说已关联（SSID 又读不到时的兜底）。
        if applyClaimedAssociated,
           let local = addresses.first(where: { Self.isPrivateIPv4($0) }) {
            joined(localIP: local, via: "系统称已关联目标网络（alreadyAssociated）")
            return
        }
        // 成功判据四：ServerInfo 直接给了车机地址、且本机已与它同 /24。
        if let bleCarIP = pendingBleCarIP,
           let local = addresses.first(where: { Self.sameSlash24($0, bleCarIP) }) {
            joined(localIP: local, via: "本机地址已与 ServerInfo 给的车机地址 \(bleCarIP) 同 /24")
            return
        }

        if let deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining < 65, !warnedSlow {
                warnedSlow = true
                onLog?("UCar 入网：等了约 25 秒还没入网——蓝牙那 30 秒时间窗可能已经过了，但入网本身继续等；真连上后即使蓝牙已断开也会接着启 CarLink（只是 …103 回告可能写不出去了）。若是第一轮赶不上，下一轮蓝牙连接时手机已在车机网络里，会直接走快速通道")
            }
            if remaining <= 0 {
                onLog?("UCar 入网：等了 90 秒仍没入网（最后实况：en0 地址 [\(addresses.joined(separator: "、"))]，当前 Wi-Fi「\(ssidNow ?? "取不到")」）——看实况行定性：地址一直没变＝没连上/关联被拒；地址变了但没被判成功＝判据漏了，把日志发回来看")
                onStatus?("入网失败：90 秒没连上车机网络")
                finish(nil)
            }
        }
    }

    /// 已确认入网：停轮询，按实际网段推导车机地址候选（排序后交给上层）。
    /// 注意：这里不再对候选做任何 TCP 试探——14:03 日志里 NWConnection
    /// 的试探连接疑似占掉了鉴权口的唯一名额，真连接随后被 refused。
    /// 候选改由上层逐个启 clink 真连接试，谁先走到协商/出画谁命中。
    private func joined(localIP: String, via: String) {
        guard !finished, !didJoin else { return }
        didJoin = true
        pollTimer?.invalidate()
        pollTimer = nil

        var candidates: [String] = []
        var derivations: [String] = []
        if let bleCarIP = pendingBleCarIP, Self.isValidIPv4(bleCarIP), bleCarIP != localIP {
            candidates.append(bleCarIP)
            derivations.append("\(bleCarIP)＝ServerInfo 直接给的 ipAddress")
        }
        if let gateway = Self.subnetDotOne(localIP), gateway != localIP,
           !candidates.contains(gateway) {
            candidates.append(gateway)
            derivations.append("\(gateway)＝本机新网段的 .1（DHCP 网关惯例）")
        }
        if !candidates.contains(Self.p2pGroupOwnerIP), Self.p2pGroupOwnerIP != localIP {
            candidates.append(Self.p2pGroupOwnerIP)
            derivations.append("\(Self.p2pGroupOwnerIP)＝P2P 组主恒定地址")
        }
        onLog?("UCar 入网：入网成功（依据：\(via)），本机地址 \(localIP)。车机地址候选（按此顺序由 CarLink 真连接逐个试，不再试探）：\(derivations.joined(separator: "；"))")
        guard !candidates.isEmpty else {
            onLog?("UCar 入网：推不出任何车机地址候选，入网判失败")
            onStatus?("入网失败：推不出车机地址")
            finish(nil)
            return
        }
        finish(Result(localIP: localIP, candidates: candidates))
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
