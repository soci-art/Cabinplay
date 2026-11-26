// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 驾驶舱（主页）：一条主线——本机 CarPlay（启动/停止 + 预览）→ 蓝牙连接
// 车机 → 连接车机 CarLink（纯状态卡）→ 上车状态汇总。CarLink 没有任何
// 手填表单：车机地址入网后自动推导、本机 IP 实测、配对码只用蓝牙卡的
// 输入框、热点凭据由蓝牙 ServerInfo 带回静默存下。

import SwiftUI
import AVFoundation

struct DashboardView: View {
    // 本机 CarPlay
    let localPhaseText: String
    let localPhaseFailed: Bool
    let localRunning: Bool
    let localStreaming: Bool
    let hasVideo: Bool
    let decoder: VideoDecoder
    // CarLink（纯状态）
    let carLinkState: CarLinkCore.State
    let carLinkRunning: Bool
    let carLinkStatusText: String
    let carLinkDetail: String
    // 蓝牙
    let bleScanning: Bool
    let bleSummary: String
    let bleFound: Bool
    let bleHasToken: Bool
    let blePhaseText: String

    @Binding var blePinField: String

    /// 当前生效的分辨率（与 ContentView 的状态实时绑定，菜单打勾用）。
    let selectedSize: (Int, Int)

    let onToggleLocalSession: () -> Void
    let onSelectSize: (Int, Int) -> Void
    let onDisconnectCarLink: () -> Void
    let onToggleBleProbe: () -> Void
    let onConnectBle: () -> Void

    @FocusState private var blePinFocused: Bool

    // MARK: 分辨率菜单（勾选与实际生效值绑定）

    private struct ResolutionOption: Identifiable {
        let width: Int
        let height: Int
        var label: String { "\(width)×\(height)" }
        var id: String { label }
    }

    private static let resolutionOptions: [ResolutionOption] = [
        ResolutionOption(width: 854, height: 480),
        ResolutionOption(width: 1280, height: 720),
        ResolutionOption(width: 1920, height: 1080),
    ]

    private func sizeLabel(_ size: (Int, Int)) -> String {
        "\(size.0)×\(size.1)"
    }

    /// 菜单内 Picker 的选中值：读的是当前生效分辨率，写回调 onSelectSize
    /// 更新上层状态——两边共用同一个状态源，勾永远落在实际生效的那一档。
    private var sizeSelection: Binding<String> {
        Binding(
            get: { sizeLabel(selectedSize) },
            set: { newLabel in
                if let option = Self.resolutionOptions.first(where: { $0.label == newLabel }) {
                    onSelectSize(option.width, option.height)
                }
            }
        )
    }

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
                VideoSurface(decoder: decoder)
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
                    // Picker 放进 Menu 是系统原生的勾选菜单形态：当前生效
                    // 的那一档自动带勾，且与 selectedSize 实时绑定——切换
                    // 后重新打开菜单，勾落在新选中的那一档上。
                    Picker("分辨率", selection: sizeSelection) {
                        ForEach(Self.resolutionOptions) { option in
                            Text(option.label).tag(option.label)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "aspectratio")
                        Text(sizeLabel(selectedSize))
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
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
