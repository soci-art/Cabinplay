// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 日志页：等宽小字，关键节点带图标；右上角菜单可分享/清空。

import SwiftUI
import UIKit

struct LogView: View {
    let lines: [String]
    let onClear: () -> Void
    /// 上传时在日志正文最前面加的一行标题（只进上传文件、页面不显示）：
    /// CarLink 与 CarLife 两边日志都传同一个收件箱，靠这一行分清是谁的。
    var uploadTitle: String? = nil
    /// 导出快照的文件名前缀（CarLife 那边传自己的，存文件时分得清）。
    var filePrefix: String = "CabinPlay-log"

    /// 分享用的日志文件：点「分享日志」那一刻才把当前日志写成一份
    /// 定格的 .txt 快照，分享面板打开期间不再改它。以前是每来一行新
    /// 日志就重写一遍（还跨分钟换名删旧），连接状态下日志不停滚动，
    /// 用户在分享面板里选「存储到文件」时脚下的文件已被换掉/删掉，
    /// 存不下去（2026-11-27 实测）。上传按钮是点下即定格内容，所以
    /// 一直没事，分享照此改。
    @State private var shareItem: ShareItem?

    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    // 日志上传（右上角，和清空日志并排）：上传中禁用按钮；结果用弹
    // 窗告诉用户，失败时把服务端回的原因照原样显示。
    @State private var uploading = false
    @State private var uploadSucceeded = false
    @State private var uploadMessage: String?

    private func doUpload() {
        uploading = true
        let text = (uploadTitle.map { "\($0)\n" } ?? "") + lines.joined(separator: "\n")
        Task {
            let result = await LogUploader.upload(text: text)
            uploading = false
            uploadSucceeded = result.ok
            uploadMessage = result.message
        }
    }

    /// 点分享时才写一份定格快照（文件名精确到秒、每次唯一），写完
    /// 不再动它；临时目录由系统回收，不在这里删任何文件。
    private func writeSnapshot() -> URL? {
        guard !lines.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filePrefix)-\(formatter.string(from: Date())).txt")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private enum Kind {
        case milestone, stream, problem, plain
    }

    private func kind(of line: String) -> Kind {
        if line.contains("tcp-accepted") || line.contains("device-info") {
            return .milestone
        }
        if line.contains("视频流") {
            return .stream
        }
        if line.contains("错误") || line.contains("失败") {
            return .problem
        }
        return .plain
    }

    var body: some View {
        Group {
            if lines.isEmpty {
                ContentUnavailableView {
                    Label("还没有日志", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("启动接收端后，这里会记下每一步")
                }
            } else {
                List(lines.suffix(200), id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        icon(for: line)
                        Text(line)
                            .font(.monoCaption)
                            .foregroundStyle(kind(of: line) == .plain ? Color.secondary : Color.primary)
                    }
                    .listRowBackground(Color.cardBackground)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.pageBackground)
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        .alert(uploadSucceeded ? "上传成功" : "上传失败",
               isPresented: Binding(get: { uploadMessage != nil },
                                    set: { if !$0 { uploadMessage = nil } })) {
            Button("好") { uploadMessage = nil }
        } message: {
            Text(uploadMessage ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    doUpload()
                } label: {
                    Label(uploading ? "上传中…" : "上传日志", systemImage: "arrow.up.circle")
                }
                .disabled(lines.isEmpty || uploading)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        if let url = writeSnapshot() {
                            shareItem = ShareItem(url: url)
                        }
                    } label: {
                        Label("分享日志", systemImage: "square.and.arrow.up")
                    }
                    .disabled(lines.isEmpty)
                    Button(role: .destructive) {
                        onClear()
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                    .disabled(lines.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("日志操作")
            }
        }
    }

    @ViewBuilder
    private func icon(for line: String) -> some View {
        switch kind(of: line) {
        case .milestone:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .stream:
            Circle()
                .fill(Color.sunsetAccent)
                .frame(width: 8, height: 8)
                .padding(.top, 3)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .plain:
            Circle()
                .fill(Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 3)
        }
    }
}

/// 日志入口按钮的样子（Carlink / CarLife 两页共用，放在导航栏右
/// 上角，与设置页同款的系统导航栏标题配套，2026-11-28 车主定）：
/// 只有橙色图标＋橙字，不带边框——iOS 27 会给导航栏按钮套一层系
/// 统玻璃胶囊，边框再套上去就是双层框（2026-11-27 截图实锤，车主
/// 圈出后否的）。橙色靠使用处给 NavigationLink 上 .tint(落日橙)。
struct LogToolbarLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
            Text("日志")
        }
    }
}

/// 系统分享面板（存文件/隔空投送等都走它）的 SwiftUI 包装。
private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
