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
    // 输入框，改完点保存即覆盖。定位授权状态进页时刷新一次。
    @State private var locationStatusText = WiFiNameAccess.authorizationStatusText
    @State private var manualSSID = ""
    @State private var manualPassword = ""
    @State private var manualOpenNetwork = false
    @State private var audioMode: AudioOutputMode = AudioOutputPolicy.mode
    @State private var routeText = AudioOutputPolicy.routeSummary
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
                HStack {
                    Text("定位授权")
                    Spacer()
                    Text(locationStatusText)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Wi-Fi 名称和密码（手填）")
            } footer: {
                Text("启动本机 CarPlay 时，要把当前 Wi-Fi 的名字和密码成对报给系统——在这里填一次、存好，以后就不用再填。只填名字、密码空着不行（系统会当成没密码的网络不理），除非它真是开放网络，那就把上面「没有密码」打开。连车时车机发的那个网络（DIRECT- 开头）是车机每轮现发的，名字和密码都自动存、自动用，不用在这里填。")
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
        .background(Color.pageBackground)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded { fieldFocused = false })
        .onAppear {
            let remembered = LocalCarPlaySession.rememberedInfraSSID
            manualSSID = remembered
            manualPassword = LocalCarPlaySession.pairedPassword(for: remembered) ?? ""
            manualOpenNetwork = LocalCarPlaySession.isOpenNetwork(remembered)
            locationStatusText = WiFiNameAccess.authorizationStatusText
            audioMode = AudioOutputPolicy.mode
            routeText = AudioOutputPolicy.routeSummary
        }
    }
}
