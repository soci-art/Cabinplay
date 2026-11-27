// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 设置：只留真用得上的——Wi-Fi 名和密码手填、声音、关于。分辨率已改
// 自动协商，不再有手动菜单。触控固定走居中模型（车主实测最准），校
// 准功能整套已撤、设置里不再留触控区；MFi 身份是 App 自带的（包内
// 文件，启动本机 CarPlay 时自验配对）、连接必需，设置里也不再留状态
// 显示。不需要再导入任何文件。

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
    // 键盘收起：点空白处、滑动、按回车都能收（以前输完收不起来）。
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
        Form {
            Section {
                TextField("Wi-Fi 名称", text: $manualSSID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit { fieldFocused = false }
                SecureField("Wi-Fi 密码", text: $manualPassword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit { fieldFocused = false }
                    .disabled(manualOpenNetwork)
                Toggle("这个网络没有密码（开放网络）", isOn: $manualOpenNetwork)
                Button("保存名字和密码") {
                    let name = manualSSIDTrimmed
                    guard !name.isEmpty else { return }
                    LocalCarPlaySession.rememberWiFiPairManually(
                        ssid: name, password: manualPassword, isOpen: manualOpenNetwork)
                    fieldFocused = false
                }
                .disabled(manualSaveDisabled)
            } header: {
                Text("Wi-Fi 名称和密码（手填）")
            }

            Section {
                Picker("声音输出", selection: $audioMode) {
                    ForEach(AudioOutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: audioMode) { _, value in
                    AudioOutputPolicy.mode = value
                    routeText = AudioOutputPolicy.routeSummary
                }
                HStack {
                    Text("当前路由")
                    Spacer()
                    Text(routeText).foregroundStyle(.secondary)
                }
            } header: {
                Text("声音")
            }

            Section("画面") {
                Picker("画质档位", selection: $sizeChoice) {
                    Text("自动（按车记忆）").tag("auto")
                    Text("1080p").tag("1080")
                    Text("720p（更流畅）").tag("720")
                    Text("480p（最省带宽）").tag("480")
                }
                Picker("请求帧率", selection: $fpsChoice) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
                Text("手动档只决定起步档：协商失败仍会自动往下降。车机只解 30 帧时，把帧率切到 30 会更稳；想让画面更顺，先试 720p。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("关于") {
                HStack {
                    Text("作者")
                    Spacer()
                    Link("soci-art", destination: URL(string: "https://github.com/soci-art")!)
                }
                HStack {
                    Text("版本")
                    Spacer()
                    Text(versionText).foregroundStyle(.secondary)
                }
                HStack {
                    Text("软件更新")
                    Spacer()
                    switch updateChecker.status {
                    case .idle, .failed:
                        Button("检查更新") { Task { await updateChecker.check() } }
                    case .checking:
                        Text("正在检查…").foregroundStyle(.secondary)
                    case .upToDate:
                        Text("已是最新").foregroundStyle(.secondary)
                    case .available(let version, let url):
                        Link("有新版本 \(version)", destination: url)
                    }
                }
                HStack {
                    Text("协议")
                    Spacer()
                    Text("CabinPlay · AGPL-3.0").foregroundStyle(.secondary)
                }
                HStack {
                    Text("上游")
                    Spacer()
                    Text("基于 CarWithin 整合").foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        // 点空白收键盘的手势只能挂背景层：挂在表单本体上时，手指抬起的
        // 瞬间会触发刷新，把菜单式选择器（声音输出/画质档位/请求帧率）
        // 刚要弹出的菜单打掉，表现为三个选择器点了一点没反应（2026-11-27
        // 实测）。背景层只接没落在控件上的点，控件自己的点按不受干扰。
        .background {
            Color.pageBackground
                .contentShape(Rectangle())
                .onTapGesture { fieldFocused = false }
        }
        .scrollDismissesKeyboard(.interactively)
        // 照主页的样子：主页是滚动视图、导航栏背景天生透明，栏后透
        // 出页面底色、大标题照常显示；表单页的栏默认是不透明白底，
        // 才会有发白接缝。改法：标题照常用导航栏大标题，栏背景用
        // NavigationBarClearance 改成透明（见文件末尾）。别再试的两
        // 条路（2026-11-27 截图实锤）：给栏强制铺色会让大标题消失；
        // 把整条栏藏掉，顶部会多出一大片空白、底部标签栏还会改成
        // 压在内容上的悬浮式。
        .navigationTitle("设置")
        .background { NavigationBarClearance() }
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
}

/// 把本页所在导航栏的背景改成透明（照主页的样子）：栏后透出页面
/// 底色，大标题照常显示，整页同色无接缝。只动设置页自己这一条
/// 导航栏，其他标签页不受影响。
private struct NavigationBarClearance: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        DispatchQueue.main.async { Self.apply(from: vc) }
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        DispatchQueue.main.async { Self.apply(from: vc) }
    }

    private static func apply(from vc: UIViewController) {
        guard let nav = vc.navigationController else { return }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        nav.navigationBar.scrollEdgeAppearance = appearance
        nav.navigationBar.standardAppearance = appearance
        nav.navigationBar.compactAppearance = appearance
    }
}
