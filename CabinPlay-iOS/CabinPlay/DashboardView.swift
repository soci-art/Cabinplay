// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 驾驶舱（主页）：一条主线——本机 CarPlay（纯状态卡，启停由连接车机
// 流程自动走、画面只上车机屏）→ 蓝牙连接车机 → 连接车机 CarLink（纯
// 状态卡）→ 上车状态汇总。CarLink 没有任何手填表单：车机地址入网后
// 自动推导、本机 IP 实测、配对码只用蓝牙卡的输入框、热点凭据由蓝牙
// ServerInfo 带回静默存下。

import SwiftUI
import AVFoundation

struct DashboardView: View {
    // 本机 CarPlay（启停平时由「连接车机」流程自动走；连上 CarLink 后
    // 卡里多一个手动开关按钮，可只停/只开 CarPlay、不断 CarLink；
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

    /// 首次连某台没校准记录的车且已出画时，给一行可点的校准提示。

    let onDisconnectCarLink: () -> Void
    let onToggleBleProbe: () -> Void
    let onConnectBle: () -> Void

    @FocusState private var blePinFocused: Bool
    /// 已配对时用户手动点开输码框（重新配对用）。
    @State private var showPinEntry = false

    /// 输码框什么时候露出来：没配对过、用户手动点开、或免码失败被上层要求。
    private var pinEntryVisible: Bool { !blePaired || showPinEntry || pinEntryForced }

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

    // MARK: 第一步：本机 CarPlay（纯状态卡）

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

            HStack {
                Text("分辨率").font(.footnote.weight(.medium))
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

            if localPhaseFailed {
                Text(localPhaseText)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if carLinkState == .playing {
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
            }
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
