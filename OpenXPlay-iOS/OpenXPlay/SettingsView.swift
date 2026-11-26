// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 设置：只留真用得上的——输出尺寸、身份状态（只读）、关于。
// 身份用 CabinPlay 自带的那套（包内文件，启动本机 CarPlay 时自验配对），
// 不需要再导入。

import SwiftUI

struct SettingsView: View {
    let selectedSize: (Int, Int)
    let onSelectSize: (Int, Int) -> Void

    private let sizes: [(Int, Int)] = [(854, 480), (1280, 720), (1920, 1080)]

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
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
                Text("分辨率本机 CarPlay 与 CarLink 共用，在下次启动会话时生效。")
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
