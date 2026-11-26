// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 设置：只留真用得上的——Wi-Fi 名兜底、关于。分辨率已改自动协商，
// 不再有手动菜单。触控固定走居中模型（车主实测最准），校准功能
// 整套已撤、设置里不再留触控区；MFi 身份是 App 自带的（包内文件，
// 启动本机 CarPlay 时自验配对）、连接必需，设置里也不再留状态
// 显示。不需要再导入任何文件。

import SwiftUI
import AVFoundation

struct SettingsView: View {
    // Wi-Fi 名兜底：记住值与授权状态进页时刷新一次；手填保存后即时更新。
    @State private var rememberedSSID = LocalCarPlaySession.rememberedInfraSSID
    @State private var rememberedPasswordState = LocalCarPlaySession.passwordStateText(for: LocalCarPlaySession.rememberedInfraSSID)
    @State private var locationStatusText = WiFiNameAccess.authorizationStatusText
    @State private var manualSSID = ""
    @State private var manualPassword = ""
    @State private var manualOpenNetwork = false
    @State private var audioMode: AudioOutputMode = AudioOutputPolicy.mode
    @State private var routeText = AudioOutputPolicy.routeSummary

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
                HStack {
                    Text("记住的 Wi-Fi 名")
                    Spacer()
                    Text(rememberedSSID.isEmpty ? "（还没有）" : rememberedSSID)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("它的密码")
                    Spacer()
                    Text(rememberedPasswordState)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("定位授权")
                    Spacer()
                    Text(locationStatusText)
                        .foregroundStyle(.secondary)
                }
                TextField("当前 Wi-Fi 名称（手填）", text: $manualSSID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("这个 Wi-Fi 的密码", text: $manualPassword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(manualOpenNetwork)
                Toggle("这个网络没有密码（开放网络）", isOn: $manualOpenNetwork)
                Button("保存名字和密码") {
                    let name = manualSSIDTrimmed
                    guard !name.isEmpty else { return }
                    LocalCarPlaySession.rememberWiFiPairManually(
                        ssid: name, password: manualPassword, isOpen: manualOpenNetwork)
                    rememberedSSID = name
                    rememberedPasswordState = LocalCarPlaySession.passwordStateText(for: name)
                    manualSSID = ""
                    manualPassword = ""
                    manualOpenNetwork = false
                }
                .disabled(manualSaveDisabled)
            } header: {
                Text("Wi-Fi 名称")
            } footer: {
                Text("启动本机 CarPlay 时要把当前 Wi-Fi 的名字和密码成对报给系统。系统规定读名字需要定位授权；不想给权限，就在这里把名称和密码成对填一次。只填名字、密码空着，系统会以为这是没密码的网络，就不理了——除非它真是开放网络，那就在上面把「没有密码」打开。")
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
            } footer: {
                Text(audioMode.detail + " 车机 Carlink 没有音频通道，所以音乐只能走车机蓝牙（A2DP）：先在系统蓝牙里连上这台车，再启动本机 CarPlay。")
            }

            Section("关于") {
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
        .onAppear {
            rememberedSSID = LocalCarPlaySession.rememberedInfraSSID
            rememberedPasswordState = LocalCarPlaySession.passwordStateText(for: rememberedSSID)
            locationStatusText = WiFiNameAccess.authorizationStatusText
            audioMode = AudioOutputPolicy.mode
            routeText = AudioOutputPolicy.routeSummary
        }
    }
}
