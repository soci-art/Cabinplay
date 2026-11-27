// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 驾驶舱（Carlink 页）：教程式分步——Wi-Fi 设置（第一步）→ 画质 →
// 声音 → 蓝牙配对码（第二步）→ 连接车机 CarLink（第三步）→ 上车状态。
// 必须按顺序完成一步才解锁下一步，未解锁的卡置灰不可用；画质与声音
// 不受步骤控制、随时可调。原来在设置页的 Wi-Fi 手填、画质、声音三区
// 已整段搬到这里（那些本来就是适配 CarLink 的），文字照原样搬、不加
// 不改。本机 CarPlay 的分辨率显示、失败提示与手动开关并入画质卡（它
// 的状态在上车状态卡里有汇总行）。右上角橙色「日志」入口进二级日志
// 页（原日志标签页已删，日志功能整体搬到这里）。
//
// CarLink 没有任何手填表单：车机地址入网后自动推导、本机 IP 实测、
// 配对码只用蓝牙卡的输入框、热点凭据由蓝牙 ServerInfo 带回静默存下。

import SwiftUI
import AVFoundation

struct DashboardView: View {
    // 本机 CarPlay（启停平时由「连接车机」流程自动走；连上 CarLink 后
    // 画质卡里多一个手动开关按钮，可只停/只开 CarPlay、不断 CarLink；
    // 预览也不在这里——画面只上车机屏，本机显示层在根层离屏承接）
    let localPhaseText: String
    let localPhaseFailed: Bool
    let localStreaming: Bool
    let localSessionRunning: Bool
    let onToggleCarPlay: () -> Void
    // CarLink（纯状态）
    let carLinkState: CarLinkCore.State
    let carLinkRunning: Bool
    let carLinkStatusText: String
    let carLinkDetail: String
    // 蓝牙
    let bleScanning: Bool
    let bleSummary: String
    let bleFound: Bool
    /// 这台车机配对过（有车机令牌或本机配对记录）：蓝牙卡免输码形态。
    let blePaired: Bool
    /// 免码连接失败后上层要求亮出输码框（车机多半把手机忘了）。
    let pinEntryForced: Bool
    let blePhaseText: String

    /// 后台保活状态（本机 CarPlay 会话运行期间自动生效）。
    let keepAliveActive: Bool

    @Binding var blePinField: String

    /// 当前生效的分辨率（自动协商的当前档，只展示、不可手选）。
    let currentSizeLabel: String

    let onDisconnectCarLink: () -> Void
    let onToggleBleProbe: () -> Void
    let onConnectBle: () -> Void

    // 日志二级页（右上角橙色入口）：本页只管 CarLink 这一套日志。
    let logLines: [String]
    let onClearLog: () -> Void

    // MARK: 从设置页搬来的三区（状态与存法照旧）

    // Wi-Fi 手填区直接就是已存的那一对：进页时把记住的名字/密码填进
    // 输入框，改完点保存即覆盖。
    @State private var manualSSID = ""
    @State private var manualPassword = ""
    @State private var manualOpenNetwork = false
    /// 第一步是否完成：已存下一对能用的 Wi-Fi 名字＋密码（或开放网络）。
    @State private var wifiSavedPair = false
    @State private var audioMode: AudioOutputMode = AudioOutputPolicy.mode
    // 画面档位：默认自动；手动档用于对比 1080p/720p 在车机上的实际流畅度。
    @AppStorage("cabinplay.sizeChoice") private var sizeChoice = "auto"
    @AppStorage("cabinplay.fpsChoice") private var fpsChoice = 60
    @State private var routeText = AudioOutputPolicy.routeSummary

    @FocusState private var blePinFocused: Bool
    @FocusState private var wifiFieldFocused: Bool
    /// 已配对时用户手动点开输码框（重新配对用）。
    @State private var showPinEntry = false

    /// 输码框什么时候露出来：没配对过、用户手动点开、或免码失败被上层要求。
    private var pinEntryVisible: Bool { !blePaired || showPinEntry || pinEntryForced }

    // MARK: 步骤解锁（教程式：完成一步才解锁下一步）

    /// 第二步（蓝牙配对码）：第一步存好 Wi-Fi 才解锁。
    private var bleLocked: Bool { !wifiSavedPair }
    /// 第三步（连接 CarLink）：蓝牙流程已经起步（状态离开未开始）才解锁。
    private var carLinkLocked: Bool {
        !(wifiSavedPair && (carLinkState != .idle || carLinkRunning))
    }

    private var manualSSIDTrimmed: String {
        manualSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var manualSaveDisabled: Bool {
        manualSSIDTrimmed.isEmpty || (!manualOpenNetwork && manualPassword.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 标题行：大标题在页面里（不用导航栏标题），右边是日志
                // 入口——橙色边框的样子见 LogEntryLabel 的注释。
                HStack(alignment: .center) {
                    Text("CabinPlay")
                        .font(.largeTitle.weight(.bold))
                    Spacer()
                    NavigationLink {
                        LogView(lines: logLines, onClear: onClearLog)
                            .navigationTitle("日志")
                    } label: {
                        LogEntryLabel()
                    }
                }
                section(title: "Wi-Fi 名称和密码（手填）") { wifiCard }
                section(title: "画面") { videoCard }
                section(title: "声音") { audioCard }
                bleProbeCard
                    .stepLocked(bleLocked)
                carLinkCard
                    .stepLocked(carLinkLocked)
                onboardCard
            }
            .padding()
        }
        .background(Color.pageBackground)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarHidden(true)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { blePinFocused = false; wifiFieldFocused = false }
            }
        }
        .onAppear {
            let remembered = LocalCarPlaySession.rememberedInfraSSID
            manualSSID = remembered
            manualPassword = LocalCarPlaySession.pairedPassword(for: remembered) ?? ""
            manualOpenNetwork = LocalCarPlaySession.isOpenNetwork(remembered)
            audioMode = AudioOutputPolicy.mode
            routeText = AudioOutputPolicy.routeSummary
            refreshWifiSaved()
        }
    }

    private func refreshWifiSaved() {
        let ssid = LocalCarPlaySession.rememberedInfraSSID
        wifiSavedPair = !ssid.isEmpty
            && (LocalCarPlaySession.isOpenNetwork(ssid)
                || !(LocalCarPlaySession.pairedPassword(for: ssid) ?? "").isEmpty)
    }

    // MARK: 分区（灰色小标题＋白色卡片，与设置页原样同款）

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

    // MARK: 第一步：Wi-Fi 名称和密码（手填）（从设置页整段搬来）

    private var wifiCard: some View {
        card {
            row {
                TextField("Wi-Fi 名称", text: $manualSSID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($wifiFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { wifiFieldFocused = false }
            }
            Divider()
            row {
                SecureField("Wi-Fi 密码", text: $manualPassword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($wifiFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { wifiFieldFocused = false }
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
                    wifiFieldFocused = false
                    refreshWifiSaved()
                }
                .foregroundStyle(manualSaveDisabled ? Color.secondary : Color.sunsetAccent)
                .disabled(manualSaveDisabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 画面（从设置页整段搬来，本机 CarPlay 的分辨率与开关并入此卡）

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
            row {
                HStack {
                    Text("分辨率")
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "aspectratio")
                        Text("自动 · 当前 \(currentSizeLabel)")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityLabel("分辨率（自动协商）")
                }
            }
            Divider()
            Text("手动档只决定起步档：协商失败仍会自动往下降。车机只解 30 帧时，把帧率切到 30 会更稳；想让画面更顺，先试 720p。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 11)
            if localPhaseFailed {
                Divider()
                Text(localPhaseText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.vertical, 11)
            }
            if carLinkState == .playing {
                Divider()
                // 连上 CarLink 后才有手动开关：只停/只开本机 CarPlay
                // 会话，CarLink 连接不断。
                Button {
                    Haptics.tap()
                    onToggleCarPlay()
                } label: {
                    Text(localSessionRunning ? "关闭 CarPlay" : "开启 CarPlay")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.sunsetAccent)
                .padding(.vertical, 7)
            }
        }
    }

    // MARK: 声音（从设置页整段搬来）

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

    // MARK: 第二步：蓝牙连接车机卡（探针 + UCar 连接前段）

    private var bleProbeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("蓝牙连接车机").font(.cardTitle)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(bleScanning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(bleScanning ? "正在探测" : "探测已停").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(bleSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(blePhaseText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
            if pinEntryVisible {
                TextField("车机屏幕上的 6 位配对码", text: $blePinField)
                    .keyboardType(.numberPad)
                    .focused($blePinFocused)
                    .submitLabel(.done)
                    .onSubmit { blePinFocused = false }
                    .onChange(of: blePinField) { _, newValue in
                        if newValue.count >= 6 { blePinFocused = false }
                    }
                    .font(.title3.monospaced())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.sunsetAccent)
                    Text("这台车已经配对过，不用输配对码")
                        .font(.footnote.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sunsetAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    onToggleBleProbe()
                } label: {
                    Text(bleScanning ? "停止探测" : "开始探测")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .tint(Color.sunsetAccent)

                Button {
                    Haptics.tap()
                    onConnectBle()
                } label: {
                    Text("连接车机")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.sunsetAccent)
                .disabled(!bleFound || (pinEntryVisible && blePinField.count != 6))
            }
            if !bleFound {
                Text("先点「开始探测」，等上面显示发现车机，再连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !pinEntryVisible {
                Button("连不上、车机要重新配对？点这里输码") {
                    Haptics.tap()
                    showPinEntry = true
                }
                .font(.caption)
                .tint(Color.sunsetAccent)
            } else if pinEntryForced {
                Text("车机把手机忘了，要重新输一次码配对；配对成功后又能免码连")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if blePaired {
                Text("输一次码重新配对；配对成功后又能免码连")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("第一次连接要输一次车机屏幕上的 6 位码；配对成功后，以后连接就不用再输了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: 第三步：连接车机 CarLink（纯状态卡，没有表单、点不开任何东西）

    private var carLinkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("连接车机 CarLink").font(.cardTitle)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(carLinkState == .playing ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(carLinkStatusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(carLinkDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("全自动：蓝牙连上车机后，入网、鉴权、出画都自己走，不用在这里填任何东西")
                .font(.caption)
                .foregroundStyle(.secondary)
            if carLinkRunning {
                Button {
                    Haptics.tap()
                    onDisconnectCarLink()
                } label: {
                    Text("断开 CarLink")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .tint(Color.sunsetAccent)
            }
        }
        .padding()
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: 上车状态汇总

    private var onboardCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("上车状态").font(.cardTitle)
            statusRow("本机 CarPlay", state: localStreaming ? "已出画" : localPhaseText,
                      ok: localStreaming)
            statusRow("蓝牙配对", state: blePhaseText, ok: bleFound)
            statusRow("车机出画", state: carLinkState.text,
                      ok: carLinkState == .playing)
            statusRow("后台保活", state: keepAliveActive ? "已开启（回桌面/锁屏不断）" : "未开启",
                      ok: keepAliveActive)
            if carLinkState == .playing && localStreaming {
                Text("已上车：CarPlay 画面正在车机上显示，车机触摸能直接操作")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    private func statusRow(_ name: String, state: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(name).font(.footnote.weight(.medium))
            Spacer()
            Text(state).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// 步骤未解锁时的样子：整卡置灰、不可点。
private extension View {
    func stepLocked(_ locked: Bool) -> some View {
        self.disabled(locked)
            .opacity(locked ? 0.45 : 1)
            .saturation(locked ? 0.3 : 1)
    }
}
