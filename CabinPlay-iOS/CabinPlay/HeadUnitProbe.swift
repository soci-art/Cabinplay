// SPDX-FileCopyrightText: 2026 CabinPlay.org
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

    /// 单次裸 TCP 连接探测（阻塞调用，请放后台线程）：返回是否连通和一句
    /// 给日志看的细节（连通/被拒/超时/错误原文分开写清）。
    static func probeOnce(_ ip: String, port: UInt16, timeoutMs: Int32 = 3000) -> (ok: Bool, detail: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (false, "建 socket 失败 errno \(errno)") }
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
        if result == 0 { return (true, "直接连通") }
        guard errno == EINPROGRESS else {
            return (false, "connect 立刻失败 errno \(errno)（\(String(cString: strerror(errno)))）")
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else {
            return (false, "\(timeoutMs) 毫秒内没响应（超时，对方没理）")
        }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        if error == 0 { return (true, "连通") }
        if error == ECONNREFUSED {
            return (false, "被拒绝（Connection refused，端口没开或还没开始监听）")
        }
        return (false, "连不上 errno \(error)（\(String(cString: strerror(error)))）")
    }

    private static func canConnect(_ ip: String, port: UInt16, timeoutMs: Int32 = 700) -> Bool {
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
        guard poll(&pfd, 1, timeoutMs) > 0 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    /// 主动发现：先快速验种子里有没有活着的（有就直接用它，不拖慢连接），
    /// 都没有才扫同网段 1–254 的 57209 口。覆盖两种情况：BLE 没给车机
    /// 地址、以及车机不在网关上（.1 探不通但确实在网段里）。
    static func discover(localIP: String, seeds: [String], completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            for ip in seeds where canConnect(ip, port: carLinkAuthPort, timeoutMs: 350) {
                DispatchQueue.main.async { completion([ip]) }
                return
            }
            let hits = scanSubnet(localIP: localIP)
            DispatchQueue.main.async { completion(hits) }
        }
    }

    /// 同网段 /24 扫 CarLink 认证口（并发 48、单机 350 毫秒），返回探通的
    /// 地址（升序）。扫不动或地址不是私有 IPv4 就返回空。
    static func scanSubnet(localIP: String, timeoutMs: Int32 = 350, concurrency: Int = 48) -> [String] {
        let parts = localIP.split(separator: ".")
        guard parts.count == 4, let last = Int(parts[3]) else { return [] }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        let hosts = 1...254
        var hits: [String] = []
        var index = 0
        let lock = NSLock()
        let group = DispatchGroup()
        for _ in 0..<min(concurrency, hosts.count) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                while true {
                    lock.lock()
                    let i = index
                    index += 1
                    lock.unlock()
                    guard i < hosts.count else { break }
                    let host = hosts[i]
                    if host == last { continue }
                    let ip = prefix + String(host)
                    if canConnect(ip, port: carLinkAuthPort, timeoutMs: timeoutMs) {
                        lock.lock(); hits.append(ip); lock.unlock()
                    }
                }
                group.leave()
            }
        }
        group.wait()
        func lastOctet(_ ip: String) -> Int {
            Int(ip.split(separator: ".").last.map(String.init) ?? "") ?? 0
        }
        return hits.sorted { lastOctet($0) < lastOctet($1) }
    }
}
