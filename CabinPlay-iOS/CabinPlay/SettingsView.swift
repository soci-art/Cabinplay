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

struct SettingsView: View {
    @StateObject private var updateChecker = UpdateChecker()

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
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
        .task { await updateChecker.check() }
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
                    case .available(let version, let url):
                        Link("有新版本 \(version)", destination: url)
                            .foregroundStyle(Color.sunsetAccent)
                    }
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
}
