// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 驾驶舱（主页）：链路状态卡 + 预览窗 + 主按钮 + CarLink 摘要卡。
// 输入项（车机 IP / 本机 IP / 配对码）收进连接 sheet，主页只留摘要。

import SwiftUI
import AVFoundation

struct DashboardView: View {
    @ObservedObject var identity: IdentityStore

    let heroState: String
    let heroDetail: String
    let receiverError: String?
    let running: Bool
    let phoneConnected: Bool
    let hasVideo: Bool
    let startedAt: Date?
    let videoLayer: AVSampleBufferDisplayLayer
    let pipReady: Bool
    let carLinkState: CarLinkCore.State
    let carLinkRunning: Bool
    let headUnitIP: String
    let bleScanning: Bool
    let bleSummary: String
    let bleFound: Bool
    let blePhaseText: String

    @Binding var headUnitIPField: String
    @Binding var localIPField: String
    @Binding var pairingCodeField: String
    @Binding var blePinField: String

    let onToggleReceiver: () -> Void
    let onPiP: () -> Void
    let onSelectSize: (Int, Int) -> Void
    let onConnectCarLink: () -> Void
    let onDisconnectCarLink: () -> Void
    let onToggleBleProbe: () -> Void
    let onConnectBle: () -> Void
    let onImportIdentity: () -> Void
    let onOpenSettings: () -> Void

    @State private var showingCarLinkSheet = false
    @FocusState private var blePinFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                chainCard

                if !identity.hasIdentity {
                    identityWarning
                }

                previewCard

                if running, let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text("已运行 \(elapsedText(since: startedAt, now: context.date))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Haptics.tap()
                    onToggleReceiver()
                } label: {
                    Label(running ? "停止接收" : "启动接收端",
                          systemImage: running ? "stop.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(running ? Color.stopRed : Color.sunsetAccent)
                .disabled(!identity.hasIdentity)
                .accessibilityLabel(running ? "停止接收" : "启动接收端")

                carLinkCard

                bleProbeCard
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

    // MARK: 链路状态卡

    private var chainCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                chainNode(icon: "iphone", name: "iPhone", active: phoneConnected)
                chainSegment(active: phoneConnected)
                chainNode(icon: "display", name: "接收端", active: running)
                chainSegment(active: carLinkState == .playing)
                chainNode(icon: "car.fill", name: "车机", active: carLinkState == .playing)
            }

            Text(receiverError ?? heroState)
                .font(.heroState)
                .foregroundStyle(receiverError != nil ? Color.red : Color.primary)
                .multilineTextAlignment(.center)

            Text(heroDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Button {
                onOpenSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: identity.hasIdentity ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(identity.hasIdentity ? Color.green : Color.orange)
                    Text(identity.hasIdentity ? "身份已就绪" : "缺少 MFi 身份")
                    Text(identity.deviceId).font(.monoCaption)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .font(.footnote)
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 20))
    }

    private func chainNode(icon: String, name: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(active ? Color.sunsetAccent : Color.secondary)
                .frame(width: 44, height: 44)
            HStack(spacing: 4) {
                Circle()
                    .fill(active ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(name).font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func chainSegment(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.sunsetAccent : Color.secondary.opacity(0.35))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 22)
            .animation(.easeInOut(duration: 0.4), value: active)
    }

    // MARK: 身份缺失提醒

    private var identityWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("先导入 MFi 身份文件，接收端才能启动")
                .font(.footnote)
            Spacer()
            Button("去导入") {
                Haptics.tap()
                onImportIdentity()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.sunsetAccent)
        }
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 预览窗

    private var previewCard: some View {
        ZStack {
            VideoSurface(layer: videoLayer)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .background(Color.black)

            if !hasVideo {
                VStack(spacing: 8) {
                    Image(systemName: "car.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.gray)
                    Text("画面会出现在这里")
                        .font(.footnote)
                        .foregroundStyle(.gray)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 2) {
                Button {
                    onPiP()
                } label: {
                    Image(systemName: "pip.enter")
                        .frame(width: 38, height: 38)
                }
                .disabled(!pipReady)
                .accessibilityLabel("画中画")

                Menu {
                    Button("854×480") { onSelectSize(854, 480) }
                    Button("1280×720") { onSelectSize(1280, 720) }
                    Button("1920×1080") { onSelectSize(1920, 1080) }
                } label: {
                    Image(systemName: "aspectratio")
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("分辨率")
            }
            .foregroundStyle(.primary)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
        }
    }

    // MARK: CarLink 摘要卡 + 连接 sheet

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
            Text("车机 \(headUnitIP) · 把画面送到车机")
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

    // MARK: 蓝牙连接车机卡（探针 + UCar 连接前段）

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
                .disabled(!bleFound || blePinField.count != 6)
            }
            if !bleFound {
                Text("先点「开始探测」，等上面显示发现车机，再输配对码连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        .presentationDetents([.medium])
    }

    private func elapsedText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
