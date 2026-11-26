// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 设置：只留真用得上的——身份状态（只读）、触控校准入口、Wi-Fi 名
// 兜底、关于。分辨率已改自动协商，不再有手动菜单。
// 身份用 CabinPlay 自带的那套（包内文件，启动本机 CarPlay 时自验配对），
// 不需要再导入。

import SwiftUI

struct SettingsView: View {
    /// 当前针对的车机（刚发现的，或上次连过的那台）：触控校准按它
    /// 存取。 nil 时校准入口置灰。
    let calibrationCarId: String?
    /// CarLink 是否正在出画（校准要触控链活着才能做）。
    let calibrationAvailable: Bool
    let onOpenCalibration: () -> Void

    /// 触控换算模式（取证三档）：进页时按当前车读，切档即存并推给
    /// 核心（核心侧打日志）。默认「按校准」。
    @State private var touchMode: TouchConversionMode = .calibrated

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

    /// 校准入口右侧的状态小字：还没认出车/已预置/已校准/未校准。
    private var calibrationStatusText: String {
        guard let calibrationCarId else { return "还没连过车机" }
        if let effective = TouchCalibrationStore.effectiveRect(for: calibrationCarId) {
            return effective.isPreset ? "已用内置预置" : "已校准"
        }
        return "还没校准"
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
                Button {
                    onOpenCalibration()
                } label: {
                    HStack {
                        Text("校准车机触控")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(calibrationStatusText)
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(calibrationCarId == nil)
                Picker("触控换算方式", selection: $touchMode) {
                    ForEach(TouchConversionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .disabled(calibrationCarId == nil)
                .onChange(of: touchMode) { _, newMode in
                    guard let calibrationCarId else { return }
                    TouchModeStore.save(newMode, for: calibrationCarId)
                    CarLinkCore.shared.applyTouchCalibration(forDeviceId: calibrationCarId)
                    CarLinkCore.shared.logTouchAnchor()
                }
            } header: {
                Text("触控")
            } footer: {
                Text("每台车机屏上画面的位置不一样，校准一次（在车机屏上点画面四条边的中间），点起来才对得准。结果按这台车单独存，换车互不影响。分辨率已经改成自动协商了，不用在这里选。\n「触控换算方式」是排查点不准时用的：直通＝原始坐标一点不校正、原样转发；居中模型＝不用校准记录、按画面居中估算；按校准＝平时用的（有校准按校准、没有按居中估算）。三档各点一轮，日志里能对出哪档最准。")
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
            if let calibrationCarId {
                touchMode = TouchModeStore.mode(for: calibrationCarId)
            }
        }
    }
}
