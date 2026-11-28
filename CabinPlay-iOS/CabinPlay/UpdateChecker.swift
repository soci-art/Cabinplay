// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 软件更新：查 GitHub 发行版（仓库 soci-art/Cabinplay），有比当前
// 版本新的发行版就在设置页「关于」里提示，点开去发行版页面下载
// 新包再用证书签装（侧载应用没法自己装更新，只能提示到这一步）。
// 查询走定死的加速顺序：自建代理 → gh-proxy.com → 直连。
// 前提：仓库是公开的、发行版里有正式发布；仓库转公开前查不到，
// 状态会停在「检查失败」，不影响其他功能。

import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed
    }

    @Published private(set) var status: Status = .idle

    private static let apiURL = "https://api.github.com/repos/soci-art/Cabinplay/releases/latest"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1"
    }

    func check() async {
        if case .checking = status { return }
        status = .checking
        let candidates = [
            "https://gh.86419753.xyz/\(Self.apiURL)",
            "https://gh-proxy.com/\(Self.apiURL)",
            Self.apiURL,
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String,
                  let page = object["html_url"] as? String,
                  let pageURL = URL(string: page) else { continue }
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            status = Self.isNewer(remote, than: currentVersion)
                ? .available(version: remote, url: pageURL)
                : .upToDate
            return
        }
        status = .failed
    }

    /// 点分版本号比较：1.2.0 > 1.0.9；段数不够按 0 补。
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
