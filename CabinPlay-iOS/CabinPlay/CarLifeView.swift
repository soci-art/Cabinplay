// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// CarLife 页：与 CarLink 完全独立的一套输出。
//
// 车机当客户端、手机当服务端；画面走 H.264，声音留在手机经蓝牙到车机。
// 这里只负责启动/停止、填车机地址、看状态；日志与 CarLink 那边同规格：
// 右上角橙色入口进二级日志页（上传/清除/导出都有），只记 CarLife 自己
// 的这一套，与 CarLink 的日志互不干扰。

import SwiftUI

struct CarLifeView: View {
    @StateObject private var session = CarLifeSession()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("cabinplay.carLifeAddress") private var carIP = ""
    // CarLife 自己的参数，和 CarLink 的设置互不影响：默认 720p30（这条
    // 协议的实际能力上限就是 1080p30），实际帧率仍以车机请求为准。
    @AppStorage("cabinplay.carLifeSize") private var sizeTag = "720"
    @AppStorage("cabinplay.carLifeFPS") private var fps = 30

    private var videoSize: (Int, Int) { sizeTag == "1080" ? (1920, 1080) : (1280, 720) }

    private var startDisabled: Bool { session.running }

    private func stepRow(_ title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.dotted" : "circle"))
                .foregroundStyle(done ? Color.green : Color.secondary)
            Text(title)
            Spacer()
            Text(done ? "完成" : (active ? "进行中" : "未开始"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 标题行与 Carlink 页同款：大标题在页面里，右边是橙色
                // 边框的日志入口（不用导航栏按钮，原因见 LogEntryLabel）。
                HStack(alignment: .center) {
                    Text("CarLife")
                        .font(.largeTitle.weight(.bold))
                    Spacer()
                    NavigationLink {
                        LogView(lines: session.logLines,
                                onClear: { session.clearLog() },
                                uploadTitle: "CabinPlay CarLife 日志",
                                filePrefix: "CabinPlay-CarLife-log")
                            .navigationTitle("日志")
                    } label: {
                        LogEntryLabel()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)
            Form {
                Section("车机") {
                    TextField("车机 IP（可留空，靠 UDP 发现）", text: $carIP)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(session.running)
                    Text("无线 CarLife：车机与这台 iPhone 要连到同一个 Wi-Fi。找不到车机时把车机 IP 填上，只发单播通知。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("进度") {
                    stepRow("Wi-Fi 网络", done: session.networkReady, active: session.running)
                    stepRow("监听端口", done: session.listening, active: session.running)
                    stepRow("车机连上", done: session.peerConnected, active: session.running)
                    stepRow("画面在走", done: session.streaming, active: session.running)
                    if session.pausedByCar {
                        Text("车机侧暂停了画面（它会自己恢复）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if session.keepAliveActive {
                        Text("保活已拉起：回桌面/锁屏也能撑住")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("输出") {
                    Picker("分辨率", selection: $sizeTag) {
                        Text("1280×720").tag("720")
                        Text("1920×1080").tag("1080")
                    }
                    .disabled(session.running)
                    Picker("帧率", selection: $fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps（最多，实际听车机的）").tag(60)
                    }
                    .disabled(session.running)
                    HStack {
                        Text("声音")
                        Spacer()
                        Text("本机 → 蓝牙 A2DP")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(session.running ? "停止" : "启动") {
                        if session.running {
                            session.stop()
                        } else {
                            let size = videoSize
                            session.start(carIP: carIP, width: size.0, height: size.1, fps: fps)
                        }
                    }
                    .foregroundStyle(session.running ? .red : .primary)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.status)
                        if let hint = session.hint {
                            Text(hint)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.pageBackground)
            .background {
                VideoSurface(decoder: session.decoder)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            }
            .background(Color.pageBackground)
            .navigationBarHidden(true)
            .onChange(of: scenePhase) { _, phase in
                // 画中画保活的联动：切后台时推一把让它自动吊起，
                // 回前台收尾（与 CarLink 主页同款，CarLife 原来缺这环）。
                switch phase {
                case .inactive: session.sceneBecameInactive()
                case .active: session.sceneReturnedToForeground()
                default: break
                }
            }
        }
    }
}
