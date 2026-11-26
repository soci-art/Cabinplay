// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 设置页：MFi 身份 / 输出 / 关于，三组 Form。

import SwiftUI

struct SettingsView: View {
    @ObservedObject var identity: IdentityStore

    let selectedSize: (Int, Int)
    let onSelectSize: (Int, Int) -> Void
    let onImportIdentity: () -> Void

    private let sizes: [(Int, Int)] = [(854, 480), (1280, 720), (1920, 1080)]

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        Form {
            Section("MFi 身份") {
                Label(identity.hasIdentity ? "身份已就绪" : "缺少 MFi 身份",
                      systemImage: identity.hasIdentity ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(identity.hasIdentity ? Color.green : Color.orange)

                HStack {
                    Text("设备地址")
                    Spacer()
                    Text(identity.deviceId)
                        .font(.monoCaption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    onImportIdentity()
                } label: {
                    Label("导入或更换身份", systemImage: "square.and.arrow.down")
                }
                .foregroundStyle(Color.sunsetAccent)
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
                Text("分辨率在下次启动接收端时生效")
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
    }
}
