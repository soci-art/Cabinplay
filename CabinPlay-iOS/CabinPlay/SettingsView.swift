// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 设置：只剩「关于」。Wi-Fi 手填、画面、声音三区原本在这里，
// 2026-11-27 按车主要求整段搬到 Carlink 页（那些都是适配 CarLink
// 的，排在连接流程的最前面当教程步骤）；这里不再留第二份。触控固
// 定走居中模型（车主实测最准），校准功能整套已撤、设置里不再留触
// 控区；MFi 身份是 App 自带的（包内文件，启动本机 CarPlay 时自验配
// 对）、连接必需，设置里也不再留状态显示。不需要再导入任何文件。
//
// 页面骨架与主页（DashboardView）完全同款：ScrollView＋卡片列。
// 不要改回 Form——表单页的导航栏默认是不透明白底（标题区发白、与
// 页面底色有接缝），内容还会滑到悬浮标签栏底下；主页的滚动页两样
// 都没有。2026-11-27 为这个来回试过三轮（强制铺色标题消失、藏导航
// 栏留空白加标签栏变悬浮、UIKit 改栏透明没生效），最终定案照主页
// 原样搭。

import SwiftUI
import UIKit

struct SettingsView: View {
    @StateObject private var updateChecker = UpdateChecker()
    /// 本轮是用户刚点下载下完的 → 自动弹一次分享菜单（以前下好的不弹）。
    @State private var downloadTapped = false
    @State private var sharePresented = false
    @State private var cacheBytes: Int64 = 0

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                section(title: "关于") { aboutCard }
            }
            .padding()
        }
        .background(Color.pageBackground)
        .navigationTitle("设置")
        .task {
            await updateChecker.check()
            refreshCacheSize()
        }
        .sheet(isPresented: $sharePresented) {
            if let file = updateChecker.downloadedFileURL {
                ActivityShareSheet(items: [file])
            }
        }
        .onChange(of: updateChecker.downloadState) { _, state in
            refreshCacheSize()
            if state == .downloaded && downloadTapped {
                downloadTapped = false
                sharePresented = true
            }
        }
    }

    // MARK: 分区（灰色小标题＋白色卡片，与主页卡片同款圆角与底色）

    private func section<Content: View>(title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 11)
    }

    // MARK: 关于

    private var aboutCard: some View {
        card {
            row {
                HStack {
                    Text("作者")
                    Spacer()
                    Link("soci-art", destination: URL(string: "https://github.com/soci-art")!)
                        .foregroundStyle(Color.sunsetAccent)
                }
            }
            Divider()
            row {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(versionText).foregroundStyle(.secondary)
                }
            }
            Divider()
            row {
                HStack {
                    Text("软件更新")
                    Spacer()
                    switch updateChecker.status {
                    case .idle, .failed:
                        Button("检查更新") { Task { await updateChecker.check() } }
                            .foregroundStyle(Color.sunsetAccent)
                    case .checking:
                        Text("正在检查…").foregroundStyle(.secondary)
                    case .upToDate:
                        Text("已是最新").foregroundStyle(.secondary)
                    case .available(let version, let build, _, _):
                        Text(build.map { "有新版 \(version)（构建 \($0)）" } ?? "有新版本 \(version)")
                            .foregroundStyle(Color.sunsetAccent)
                    }
                }
            }
            if case .available(_, _, let pageURL, let asset) = updateChecker.status {
                Divider()
                row { updateActionRow(pageURL: pageURL, asset: asset) }
            }
            Divider()
            row {
                HStack {
                    Text("清除缓存")
                    Spacer()
                    Text(cacheSizeText)
                        .foregroundStyle(.secondary)
                    Button("清除") { clearCache() }
                        .foregroundStyle(Color.sunsetAccent)
                }
            }
            Divider()
            row {
                HStack {
                    Text("协议")
                    Spacer()
                    Text("CabinPlay · AGPL-3.0").foregroundStyle(.secondary)
                }
            }
            Divider()
            row {
                HStack {
                    Text("上游")
                    Spacer()
                    Text("基于 CarWithin 整合").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 软件更新的第二行（有新版时才出现）：在 App 里直接下载新包，
    /// 带进度、能取消；下完自动弹分享菜单，包留在 App 里、之后点
    /// 「分享」还能再发。装更新仍要去签名工具签了再装（系统不让
    /// App 自己装），这一行省的是去网页翻发行版找附件的步骤。
    @ViewBuilder
    private func updateActionRow(pageURL: URL, asset: UpdateChecker.Asset?) -> some View {
        switch updateChecker.downloadState {
        case .none:
            HStack {
                if asset != nil {
                    Button("下载") {
                        downloadTapped = true
                        updateChecker.startDownload()
                    }
                    .foregroundStyle(Color.sunsetAccent)
                }
                Spacer()
                Link("去发行页", destination: pageURL)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("正在下载…")
                    Spacer()
                    if let fraction {
                        Text("\(Int(fraction * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Button("取消") { updateChecker.cancelDownload() }
                        .foregroundStyle(Color.sunsetAccent)
                }
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(Color.sunsetAccent)
                } else {
                    ProgressView()
                        .tint(Color.sunsetAccent)
                }
            }
        case .downloaded:
            HStack {
                Text("已下载")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("分享") { sharePresented = true }
                    .foregroundStyle(Color.sunsetAccent)
            }
        case .downloadFailed:
            HStack {
                Text("下载失败")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重试") {
                    downloadTapped = true
                    updateChecker.startDownload()
                }
                .foregroundStyle(Color.sunsetAccent)
            }
        }
    }

    // MARK: 清除缓存（网络缓存＋临时文件＋缓存目录＋已下载的更新包，
    // 车主定：已下载的包也归在缓存里一起清；配对记录在 Application
    // Support、不在这里面，不会误伤）

    private var cacheSizeText: String {
        cacheBytes > 0
            ? ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
            : "0 KB"
    }

    private static func directoryBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private func refreshCacheSize() {
        let downloaded = updateChecker.downloadedFileURL
        Task.detached {
            var total = Int64(URLCache.shared.currentDiskUsage)
            total += Self.directoryBytes(FileManager.default.temporaryDirectory)
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                total += Self.directoryBytes(caches)
            }
            if let downloaded,
               let size = try? downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
            await MainActor.run { cacheBytes = total }
        }
    }

    private func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        var dirs = [FileManager.default.temporaryDirectory]
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            dirs.append(caches)
        }
        for dir in dirs {
            if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in items { try? FileManager.default.removeItem(at: item) }
            }
        }
        updateChecker.clearDownloadedUpdate()
        refreshCacheSize()
    }
}

/// 系统分享菜单（把下好的包送去签名工具、或存到文件）。
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
