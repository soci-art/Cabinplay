// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 驾驶舱（主页）：一条主线——本机 CarPlay（启动/停止 + 预览）→ 蓝牙连接
// 车机 → 连接车机 CarLink → 上车状态汇总。输入项收进连接 sheet。

import SwiftUI
import AVFoundation

struct DashboardView: View {
    // 本机 CarPlay
    let localPhaseText: String
    let localPhaseFailed: Bool
    let localRunning: Bool
    let localStreaming: Bool
    let hasVideo: Bool
    let videoLayer: AVSampleBufferDisplayLayer
    // CarLink
    let carLinkState: CarLinkCore.State
    let carLinkRunning: Bool
    let headUnitIP: String
    // 蓝牙
    let bleScanning: Bool
    let bleSummary: String
    let bleFound: Bool
    let bleHasToken: Bool
    let blePhaseText: String

    @Binding var headUnitIPField: String
    @Binding var localIPField: String
    @Binding var pairingCodeField: String
    @Binding var blePinField: String
    @Binding var wifiSSIDField: String
    @Binding var wifiPasswordField: String

    let onToggleLocalSession: () -> Void
    let onSelectSize: (Int, Int) -> Void
    let onConnectCarLink: () -> Void
    let onDisconnectCarLink: () -> Void
    let onToggleBleProbe: () -> Void
    let onConnectBle: () -> Void

    @State private var showingCarLinkSheet = false
    @FocusState private var blePinFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                localCarPlayCard
                bleProbeCard
                carLinkCard
                onboardCard
            }
            .padding()
        }
        .background(Color.pageBackground)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { blePinFocused = false }
            }
        }
        .sheet(isPresented: $showingCarLinkSheet) {
            carLinkSheet
        }
    }

    // MARK: 第一步：本机 CarPlay

    private var localCarPlayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本机 CarPlay").font(.cardTitle)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(localStreaming ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(localPhaseText).font(.caption).foregroundStyle(.secondary)
                }
            }

            ZStack {
                VideoSurface(layer: videoLayer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)

                if !hasVideo {
                    VStack(spacing: 8) {
                        Image(systemName: "car.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.gray)
                        Text("CarPlay 画面会出现在这里")
                            .font(.footnote)
                            .foregroundStyle(.gray)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottomTrailing) {
                Menu {
                    Button("854×480") { onSelectSize(854, 480) }
                    Button("1280×720") { onSelectSize(1280, 720) }
                    Button("1920×1080") { onSelectSize(1920, 1080) }
                } label: {
                    Image(systemName: "aspectratio")
                        .frame(width: 38, height: 38)
                }
                .foregroundStyle(.primary)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
                .accessibilityLabel("分辨率")
            }

            if localPhaseFailed {
                Text(localPhaseText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Haptics.tap()
                onToggleLocalSession()
            } label: {
                Label(localRunning ? "停止 CarPlay" : "启动 CarPlay",
                      systemImage: localRunning ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(localRunning ? Color.stopRed : Color.sunsetAccent)

            Text("在这台 iPhone 上直接跑出 CarPlay 画面，再送上车机。声音走手机本机出声（也可以用手机蓝牙连车机出声）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
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
                .disabled(!bleFound || (blePinField.count != 6 && !bleHasToken))
            }
            if !bleFound {
                Text("先点「开始探测」，等上面显示发现车机，再输配对码连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if bleHasToken && blePinField.count != 6 {
                Text("这台车机存有上次配对的重连令牌，不用输码，直接点「连接车机」就能连")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: 第三步：连接车机 CarLink 摘要卡 + 连接 sheet

    private var carLinkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("连接车机 CarLink").font(.cardTitle)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(carLinkState == .playing ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(carLinkState.text).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("车机 \(headUnitIP) · 把本机 CarPlay 画面送到车机")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Haptics.tap()
                if carLinkRunning {
                    onDisconnectCarLink()
                } else {
                    showingCarLinkSheet = true
                }
            } label: {
                Text(carLinkRunning ? "断开 CarLink" : "连接车机")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .tint(Color.sunsetAccent)
        }
        .padding()
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    private var carLinkSheet: some View {
        NavigationStack {
            Form {
                Section("车机地址") {
                    TextField("车机 IP", text: $headUnitIPField)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    TextField("本机 IP", text: $localIPField)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
                Section("配对码") {
                    TextField("车机屏幕上的配对码", text: $pairingCodeField)
                        .keyboardType(.numberPad)
                        .font(.title3.monospaced())
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("车机热点（本机 CarPlay 用）")
                            .font(.footnote.weight(.medium))
                        TextField("热点名称（蓝牙连上后会自动填）", text: $wifiSSIDField)
                            .autocorrectionDisabled()
                        TextField("热点密码", text: $wifiPasswordField)
                            .autocorrectionDisabled()
                        Text("蓝牙连接成功后会自动带回并存下，一般不用手填；本机 CarPlay 启动时要用它告诉系统走哪个网络。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        showingCarLinkSheet = false
                        onConnectCarLink()
                    } label: {
                        Text("连接车机").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.sunsetAccent)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.pageBackground)
            .navigationTitle("连接车机 CarLink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingCarLinkSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
