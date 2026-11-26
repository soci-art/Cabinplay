// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 日志页：等宽小字，关键节点带图标；右上角菜单可分享/清空。

import SwiftUI

struct LogView: View {
    let lines: [String]
    let onClear: () -> Void

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: lines.joined(separator: "\n")) {
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
