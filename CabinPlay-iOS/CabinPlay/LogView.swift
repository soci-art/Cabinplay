// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 日志页：等宽小字，关键节点带图标；右上角菜单可分享/清空。

import SwiftUI

struct LogView: View {
    let lines: [String]
    let onClear: () -> Void

    /// 分享用的日志文件地址。纯文字分享在 iOS 上没有「存储到文件」，
    /// 所以先把日志写成真正的 .txt 文件，再分享这个文件。
    @State private var logFileURL: URL?

    /// 把当前日志写到临时目录的 .txt 文件（文件名带时间戳），供分享使用。
    private func prepareLogFile() {
        guard !lines.isEmpty else {
            logFileURL = nil
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let fileName = "CabinPlay-log-\(formatter.string(from: Date())).txt"
        let dir = FileManager.default.temporaryDirectory
        // 顺手清掉上次的日志文件，别越攒越多。
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in old where url.lastPathComponent.hasPrefix("CabinPlay-log-") && url.lastPathComponent != fileName {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let url = dir.appendingPathComponent(fileName)
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            logFileURL = url
        } catch {
            logFileURL = nil
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
        .onAppear { prepareLogFile() }
        .onChange(of: lines) { prepareLogFile() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let logFileURL {
                        ShareLink(item: logFileURL) {
                            Label("分享日志", systemImage: "square.and.arrow.up")
                        }
                    }
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
