// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// HeadUnitProbe — 自动找车机：候选地址依次探 CarLink 认证端口（57209），
// 探通的第一个就是车机。候选顺序：上次连上的地址 → 当前网络的 .1 网关
// → CarLink 最常见的 192.168.49.1。

import Foundation
import Darwin

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

    /// 在后台挨个探，探通第一个就回调（主线程）；都没探通回调 nil。
    static func probeFirst(candidates: [String], completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            for ip in candidates where canConnect(ip, port: carLinkAuthPort) {
                DispatchQueue.main.async { completion(ip) }
                return
            }
            DispatchQueue.main.async { completion(nil) }
        }
    }

    private static func canConnect(_ ip: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 700) > 0 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }
}
