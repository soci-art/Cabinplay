// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 设置：只留真用得上的——输出尺寸、身份状态（只读）、关于。
// 身份用 CabinPlay 自带的那套（包内文件，启动本机 CarPlay 时自验配对），
// 不需要再导入。

import SwiftUI

struct SettingsView: View {
    let selectedSize: (Int, Int)
    let onSelectSize: (Int, Int) -> Void

    private let sizes: [(Int, Int)] = [(854, 480), (1280, 720), (1920, 1080)]

    // Wi-Fi 名兜底：记住值与授权状态进页时刷新一次；手填保存后即时更新。
    @State private var rememberedSSID = LocalCarPlaySession.rememberedInfraSSID
    @State private var rememberedPasswordState = LocalCarPlaySession.passwordStateText(for: LocalCarPlaySession.rememberedInfraSSID)
    @State private var locationStatusText = WiFiNameAccess.authorizationStatusText
    @State private var manualSSID = ""
    @State private var manualPassword = ""
    @State private var manualOpenNetwork = false

    private var manualSSIDTrimmed: String {
        manualSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var manualSaveDisabled: Bool {
        manualSSIDTrimmed.isEmpty || (!manualOpenNetwork && manualPassword.isEmpty)
    }

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var identityReady: Bool {
        Bundle.main.url(forResource: "certificate", withExtension: "p7b") != nil
            && Bundle.main.url(forResource: "leaf", withExtension: "cer") != nil
            && Bundle.main.url(forResource: "private", withExtension: "x963") != nil
    }

    var body: some View {
        Form {
            Section {
                Label(identityReady ? "身份已就绪（App 自带）" : "身份文件不全",
                      systemImage: identityReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(identityReady ? Color.green : Color.orange)
            } header: {
                Text("MFi 身份")
            } footer: {
                Text("本机 CarPlay 用的是 CabinPlay 自带的身份，启动时会自动验一遍配对，不用再导入文件。")
            }

            Section {
                ForEach(sizes.indices, id: \.self) { index in
                    let size = sizes[index]
                    Button {
                        onSelectSize(size.0, size.1)
                    } label: {
                        HStack {
                            Text("\(size.0)×\(size.1)")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedSize.0 == size.0 && selectedSize.1 == size.1 {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.sunsetAccent)
                            }
                        }
                    }
                }
            } header: {
                Text("输出")
            } footer: {
                Text("分辨率本机 CarPlay 与 CarLink 共用，在下次启动会话时生效。")
            }

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

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(versionText).foregroundStyle(.secondary)
                }
                HStack {
                    Text("协议")
                    Spacer()
                    Text("OpenXPlay · AGPL-3.0").foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.pageBackground)
        .onAppear {
            rememberedSSID = LocalCarPlaySession.rememberedInfraSSID
            rememberedPasswordState = LocalCarPlaySession.passwordStateText(for: rememberedSSID)
            locationStatusText = WiFiNameAccess.authorizationStatusText
        }
    }
}
