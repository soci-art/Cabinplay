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

    @Binding var headUnitIPField: String
    @Binding var localIPField: String
    @Binding var pairingCodeField: String

    let onToggleReceiver: () -> Void
    let onPiP: () -> Void
    let onSelectSize: (Int, Int) -> Void
    let onConnectCarLink: () -> Void
    let onDisconnectCarLink: () -> Void
    let onImportIdentity: () -> Void
    let onOpenSettings: () -> Void

    @State private var showingCarLinkSheet = false

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
            }
            .padding()
        }
        .background(Color.pageBackground)
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
            HStack(spacing: 4) {
                Button {
                    onPiP()
                } label: {
                    Image(systemName: "pip.enter")
                        .frame(width: 40, height: 40)
                }
                .disabled(!pipReady)
                .accessibilityLabel("画中画")

                Menu {
                    Button("854×480") { onSelectSize(854, 480) }
                    Button("1280×720") { onSelectSize(1280, 720) }
                    Button("1920×1080") { onSelectSize(1920, 1080) }
                } label: {
                    Image(systemName: "rectangle.resize")
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("分辨率")
            }
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
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
