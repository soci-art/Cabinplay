// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 日志上传：把当前日志整段传到 CabinPlay 自己的收件口（与 Drift、
// LaunchShield 的收件口分开，不混）。服务端单个 IP 一小时最多收
// 10 次；被拦或失败时，服务端会回一句人话原因，界面照原样显示，
// 不只说「上传失败」。

import Foundation

enum LogUploader {
    static let endpoint = URL(string: "https://cabinplay-log.86419753.xyz/upload")!

    /// 返回 (成功否, 给用户看的话)。
    static func upload(text: String) async -> (ok: Bool, message: String) {
        guard !text.isEmpty else { return (false, "日志是空的，没有可上传的内容") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            request.setValue(version, forHTTPHeaderField: "X-App-Version")
        }
        request.httpBody = Data(text.utf8)
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            // 服务端统一回 JSON：{"ok":true} 或 {"ok":false,"reason":"…"}。
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if object["ok"] as? Bool == true {
                    return (true, "日志已上传")
                }
                if let reason = object["reason"] as? String, !reason.isEmpty {
                    return (false, reason)
                }
            }
            if http?.statusCode == 200 {
                return (true, "日志已上传")
            }
            return (false, "上传失败：服务器返回了 \(http?.statusCode ?? -1)，请稍后再试")
        } catch {
            return (false, "上传失败：网络不通，没传上去，请检查网络后再试")
        }
    }
}
