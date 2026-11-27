// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// CarLife 页：与 CarLink 完全独立的一套输出。
//
// 车机当客户端、手机当服务端；画面走 H.264，声音留在手机经蓝牙到车机。
// 这里只负责启动/停止、填车机地址、看状态与日志，别的一概不碰 CarLink。

import SwiftUI

struct CarLifeView: View {
    @StateObject private var session = CarLifeSession()
    @AppStorage("cabinplay.carLifeAddress") private var carIP = ""

    private var startDisabled: Bool { session.running }

    var body: some View {
        NavigationStack {
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

                Section("输出") {
                    HStack {
                        Text("分辨率")
                        Spacer()
                        Text("1280×720")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("帧率")
                        Spacer()
                        Text("30 fps")
                            .foregroundStyle(.secondary)
                    }
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
                            session.start(carIP: carIP, width: 1280, height: 720, fps: 30)
                        }
                    }
                    .foregroundStyle(session.running ? .red : .primary)
                } footer: {
                    Text(session.status)
                }

                Section("日志") {
                    if session.logLines.isEmpty {
                        Text("启动后这里会记下每一步")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(session.logLines.suffix(60).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.pageBackground)
            .navigationTitle("CarLife")
        }
    }
}
