// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 软件更新：查 GitHub 发行版（仓库 soci-art/Cabinplay），有比当前
// 版本新的发行版就在设置页「关于」里提示，并能直接在 App 里把新包
// 下回来（下完弹分享菜单送去签名工具、或存到文件）。侧载应用没法
// 自己装更新，下载只省去网页上翻发行版找附件那几步，签装仍在签名
// 工具里走。检查与下载都走定死的加速顺序：自建代理 → gh-proxy.com
// → 直连。前提：仓库是公开的、发行版里有正式发布；查不到时状态停
// 在「检查失败」，不影响其他功能。

import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    struct Asset: Equatable {
        let name: String
        let url: URL
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, pageURL: URL, asset: Asset?)
        case failed
    }

    enum DownloadState: Equatable {
        /// 还没下（或已取消）。
        case none
        /// 下载中；fraction 为 nil 是服务器没给总大小、算不出百分比。
        case downloading(fraction: Double?)
        case downloaded
        case downloadFailed
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var downloadState: DownloadState = .none

    private static let apiURL = "https://api.github.com/repos/soci-art/Cabinplay/releases/latest"
    private static let downloadedVersionKey = "cabinplay.updateDownloadedVersion"

    private let downloader = AssetDownloader()
    private var downloadTask: Task<Void, Never>?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1"
    }

    /// 下好的包文件（Documents/Updates 下），分享时用。
    var downloadedFileURL: URL? {
        guard let version = UserDefaults.standard.string(forKey: Self.downloadedVersionKey),
              !version.isEmpty else { return nil }
        let dir = Self.updatesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              let ipa = files.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return nil }
        return ipa
    }

    private static var updatesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Updates", isDirectory: true)
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
            if Self.isNewer(remote, than: currentVersion) {
                let asset = Self.parseAsset(from: object)
                status = .available(version: remote, pageURL: pageURL, asset: asset)
                // 以前下好的就是这一版 → 直接显示已下载，不用重下。
                let stored = UserDefaults.standard.string(forKey: Self.downloadedVersionKey)
                downloadState = (stored == remote && downloadedFileURL != nil) ? .downloaded : .none
            } else {
                status = .upToDate
            }
            return
        }
        status = .failed
    }

    /// 发行版附件里挑 .ipa 那个（每版只有一个）。
    private static func parseAsset(from object: [String: Any]) -> Asset? {
        guard let assets = object["assets"] as? [[String: Any]] else { return nil }
        for entry in assets {
            guard let name = entry["name"] as? String,
                  name.lowercased().hasSuffix(".ipa"),
                  let link = entry["browser_download_url"] as? String,
                  let url = URL(string: link) else { continue }
            return Asset(name: name, url: url)
        }
        return nil
    }

    // MARK: 下载

    func startDownload() {
        guard case .available(let version, _, let asset) = status, let asset else { return }
        downloadTask?.cancel()
        downloadState = .downloading(fraction: nil)
        let raw = asset.url.absoluteString
        let candidates = [
            "https://gh.86419753.xyz/\(raw)",
            "https://gh-proxy.com/\(raw)",
            raw,
        ].compactMap { URL(string: $0) }
        let name = asset.name
        downloadTask = Task { [weak self] in
            guard let self else { return }
            for url in candidates {
                if Task.isCancelled { return }
                do {
                    let staged = try await downloader.download(from: url) { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, case .downloading = self.downloadState else { return }
                            self.downloadState = .downloading(fraction: fraction)
                        }
                    }
                    try moveIntoPlace(staged: staged, name: name)
                    UserDefaults.standard.set(version, forKey: Self.downloadedVersionKey)
                    downloadState = .downloaded
                    return
                } catch is CancellationError {
                    downloadState = .none
                    return
                } catch {
                    continue // 这一条加速路不通，换下一条
                }
            }
            if !Task.isCancelled { downloadState = .downloadFailed }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloader.cancel()
        downloadState = .none
    }

    /// 清除缓存时连已下载的更新包一起清（车主定的，归在缓存里）：
    /// 删文件、去下载记录，状态回到没下载。
    func clearDownloadedUpdate() {
        let dir = Self.updatesDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "ipa" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.downloadedVersionKey)
        if case .downloaded = downloadState { downloadState = .none }
    }

    /// 把下好的临时文件搬进 Documents/Updates（旧包清掉，只留当前一份）。
    private func moveIntoPlace(staged: URL, name: String) throws {
        let dir = Self.updatesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "ipa" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.moveItem(at: staged, to: dest)
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

/// 带进度的下载器：系统下载任务＋回调。代理不一定回总大小，进度
/// 算不出来时回调 nil。完成时先把临时文件搬到暂存区再交回（系统在
/// 回调返回后会删它自己的临时文件）。
private final class AssetDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: ((Double?) -> Void)?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(from url: URL, onProgress: @escaping (Double?) -> Void) async throws -> URL {
        self.onProgress = onProgress
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-\(UUID().uuidString).ipa")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            continuation?.resume(returning: staged)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
