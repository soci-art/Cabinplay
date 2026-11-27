// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// HeadUnitProbe — 只负责算车机地址候选名单：上次连上的地址 → 当前网络
// 的 .1 网关 → CarLink 最常见的 192.168.49.1。名单交给 CarLinkFlow 逐个
// 用真连接试。
//
// 这里不做任何连接探测：车机认证端口（57209）只认第一个连接，裸 TCP
// 连一下不发数据就会占掉唯一的鉴权名额，随后真正的连接会被拒之门外。
// 早先的裸探（probeFirst/probeOnce/canConnect）与后加的同网段扫描发现
// （discover/scanSubnet）都按此口径删除，不再保留。

import Foundation

enum HeadUnitProbe {
    static let carLinkAuthPort: UInt16 = 57209

    static func candidates(localIPs: [String], lastUsed: String?) -> [String] {
        var list: [String] = []
        func add(_ ip: String?) {
            guard let ip, !ip.isEmpty, !list.contains(ip) else { return }
            list.append(ip)
        }
        add(lastUsed)
        for ip in localIPs {
            let parts = ip.split(separator: ".")
            if parts.count == 4 {
                add("\(parts[0]).\(parts[1]).\(parts[2]).1")
            }
        }
        add("192.168.49.1")
        return list
    }
}
