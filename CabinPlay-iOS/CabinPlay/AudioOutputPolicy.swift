// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// AudioOutputPolicy — 声音往哪儿出的唯一决策点。
//
// 背景：虚拟 CarPlay 在场时，系统路由里有一个 carAudio 口（对面是我们
// 自己的接收端），直接用它出声会绕回 App 形成回路，所以旧代码在没有
// 蓝牙 A2DP 时把输出钉在 iPhone 扬声器上。音乐于是永远出不了车机。
//
// 新规则：
//   automatic（默认）—— 有蓝牙 A2DP 就走蓝牙（车机），没有才钉扬声器；
//   bluetooth        —— 只要 A2DP 在，绝不钉扬声器；A2DP 不在就如实写日志，
//                        仍然不钉（避免把用户手动连上的蓝牙抢回扬声器）；
//   speaker          —— 始终钉扬声器（调试/怕回路时用）。
//
// 另外把「什么时候需要 playAndRecord」收紧：只有真的在跑麦克风流才切
// 双工类别，音乐流一律 .playback，蓝牙才有候选资格。

import AVFoundation

enum AudioOutputMode: String, CaseIterable, Identifiable {
    case automatic
    case bluetooth
    case speaker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动（有蓝牙走蓝牙）"
        case .bluetooth: return "优先车机蓝牙"
        case .speaker: return "iPhone 扬声器"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "连上车机蓝牙时音乐从车机出；没连蓝牙时留在手机扬声器，并避开 CarPlay 回路。"
        case .bluetooth: return "只要蓝牙 A2DP 在线就走车机；不在线也不抢回扬声器，日志会写明原因。"
        case .speaker: return "始终从 iPhone 扬声器出，适合排查回路或蓝牙不稳定时。"
        }
    }
}

enum AudioOutputPolicy {
    static let defaultsKey = "cabinplay.audio.output"

    static var mode: AudioOutputMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let mode = AudioOutputMode(rawValue: raw) else {
                return .automatic
            }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    static var routeSummary: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outputs.isEmpty { return "无输出" }
        return outputs.map { $0.portType.rawValue }.joined(separator: ", ")
    }

    static func hasA2DP() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .bluetoothA2DP }
    }

    /// 是否应该把输出钉在扬声器上（只有 speaker 模式，或自动模式下
    /// 没有蓝牙且存在 carAudio 回路风险时才钉）。
    static func shouldPinSpeaker(hasCarAudio: Bool, hasA2DP: Bool) -> Bool {
        switch mode {
        case .speaker:
            return true
        case .bluetooth:
            return false
        case .automatic:
            return hasCarAudio && !hasA2DP
        }
    }
}
