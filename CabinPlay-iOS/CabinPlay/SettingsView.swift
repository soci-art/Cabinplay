// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 设置：只留真用得上的——Wi-Fi 名和密码手填、声音、画面、关于。触控
// 固定走居中模型（车主实测最准），校准功能整套已撤、设置里不再留触
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
import AVFoundation

struct SettingsView: View {
    // Wi-Fi 手填区直接就是已存的那一对：进页时把记住的名字/密码填进
    // 输入框，改完点保存即覆盖。
    @State private var manualSSID = ""
    @State private var manualPassword = ""
    @State private var manualOpenNetwork = false
    @State private var audioMode: AudioOutputMode = AudioOutputPolicy.mode
    // 画面档位：默认自动；手动档用于对比 1080p/720p 在车机上的实际流畅度。
    @AppStorage("cabinplay.sizeChoice") private var sizeChoice = "auto"
    @AppStorage("cabinplay.fpsChoice") private var fpsChoice = 60
    @State private var routeText = AudioOutputPolicy.routeSummary
    @StateObject private var updateChecker = UpdateChecker()
    // 键盘收起：点空白处、滑动、按回车、键盘工具栏「完成」都能收。
    @FocusState private var fieldFocused: Bool

    private var manualSSIDTrimmed: String {
        manualSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var manualSaveDisabled: Bool {
        manualSSIDTrimmed.isEmpty || (!manualOpenNetwork && manualPassword.isEmpty)
    }

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                section(title: "Wi-Fi 名称和密码（手填）") { wifiCard }
                section(title: "声音") { audioCard }
                section(title: "画面") { videoCard }
                section(title: "关于") { aboutCard }
            }
            .padding()
        }
        .background {
            // 点空白收键盘的手势只挂背景层：控件自己的点按先被控件接
            // 走，落到空白处才收键盘，不会打掉菜单式选择器的弹出。
            Color.pageBackground
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { fieldFocused = false }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("设置")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { fieldFocused = false }
            }
        }
        .task { await updateChecker.check() }
        .onAppear {
            let remembered = LocalCarPlaySession.rememberedInfraSSID
            manualSSID = remembered
            manualPassword = LocalCarPlaySession.pairedPassword(for: remembered) ?? ""
            manualOpenNetwork = LocalCarPlaySession.isOpenNetwork(remembered)
            audioMode = AudioOutputPolicy.mode
            routeText = AudioOutputPolicy.routeSummary
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

    /// 选择器行：行名是普通黑字，右边是系统原生菜单式选择器（只显
    /// 当前值＋上下小箭头，落日橙），点开的菜单与表单页时一模一样。
    /// 别用自绘 Menu 当选择器：Menu 会把整行标签都染成强调色（行名
    /// 跟着变橙），弹出的面板样子也与原生选择器不同（2026-11-27
    /// 截图实锤）。
    private func pickerRow<Selection: Hashable>(title: String,
                                                selection: Binding<Selection>,
                                                @ViewBuilder options: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection) { options() }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Color.sunsetAccent)
        }
    }

    // MARK: Wi-Fi 手填

    private var wifiCard: some View {
        card {
            row {
                TextField("Wi-Fi 名称", text: $manualSSID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit { fieldFocused = false }
            }
            Divider()
            row {
                SecureField("Wi-Fi 密码", text: $manualPassword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit { fieldFocused = false }
                    .disabled(manualOpenNetwork)
            }
            Divider()
            row {
                Toggle("这个网络没有密码（开放网络）", isOn: $manualOpenNetwork)
            }
            Divider()
            row {
                Button("保存名字和密码") {
                    let name = manualSSIDTrimmed
                    guard !name.isEmpty else { return }
                    LocalCarPlaySession.rememberWiFiPairManually(
                        ssid: name, password: manualPassword, isOpen: manualOpenNetwork)
                    fieldFocused = false
                }
                .foregroundStyle(manualSaveDisabled ? Color.secondary : Color.sunsetAccent)
                .disabled(manualSaveDisabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 声音

    private var audioCard: some View {
        card {
            row {
                pickerRow(title: "声音输出", selection: $audioMode) {
                    ForEach(AudioOutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: audioMode) { _, value in
                    AudioOutputPolicy.mode = value
                    routeText = AudioOutputPolicy.routeSummary
                }
            }
            Divider()
            row {
                HStack {
                    Text("当前路由")
                    Spacer()
                    Text(routeText).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 画面

    private var videoCard: some View {
        card {
            row {
                pickerRow(title: "画质档位", selection: $sizeChoice) {
                    Text("自动（按车记忆）").tag("auto")
                    Text("1080p").tag("1080")
                    Text("720p（更流畅）").tag("720")
                    Text("480p（最省带宽）").tag("480")
                }
            }
            Divider()
            row {
                pickerRow(title: "请求帧率", selection: $fpsChoice) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
            }
            Divider()
            Text("手动档只决定起步档：协商失败仍会自动往下降。车机只解 30 帧时，把帧率切到 30 会更稳；想让画面更顺，先试 720p。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 11)
        }
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
