// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// CarLife 会话：和 CarLink 完全独立的一套。
//
// 自己持有一个本机 CarPlay 会话 + 一个 CarLife 输出；把 CarPlay 的画面、
// 触控、按键、关键帧请求接到 CarLife 那条链路上。CarLink 那边的状态、
// 入网流程、触控居中模型一概不碰。
//
// 音频：CarLife 协议没有音频通道，声音必须留本机（蓝牙 A2DP 到车机）。
// 所以这里启动时明确把「车机在放声音」的标记清掉，让本机解码出声。

import Foundation
import Combine

final class CarLifeSession: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "未启动"
    @Published private(set) var logLines: [String] = []

    private let local = LocalCarPlaySession()
    private let output = CarLifeOutput()
    private var wired = false

    private func append(_ line: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logLines.append(line)
            if self.logLines.count > 300 { self.logLines.removeFirst(self.logLines.count - 300) }
        }
    }

    func start(carIP: String, width: Int, height: Int, fps: Int) {
        guard !running else { return }
        guard !CarLinkCore.shared.running else {
            status = "CarLink 正在运行：两边不能同时开，先停止 CarLink"
            append("CarLife：检测到 CarLink 在跑，拒绝启动（两套输出必须互斥）")
            return
        }
        let ip = carIP.trimmingCharacters(in: .whitespacesAndNewlines)
        // 声音留本机：CarLife 没有音频通道。
        CarPlayAudio.carPlaysAudio = false
        wire()
        local.start(width: width, height: height, fps: fps)
        output.start(targetAddress: ip.isEmpty ? nil : ip, width: width, height: height, fps: fps)
        running = true
        status = ip.isEmpty
            ? "正在启动：本机 CarPlay + CarLife 监听（靠 UDP 发现车机）"
            : "正在启动：本机 CarPlay + CarLife 监听（只通知车机 \(ip)）"
    }

    func stop() {
        output.stop()
        local.stop()
        running = false
        status = "已停止"
        append("CarLife：已停止")
    }

    private func wire() {
        guard !wired else { return }
        wired = true
        local.onLog = { [weak self] line in self?.append(line) }
        local.onPreviewFrame = { [weak self] data, codec in
            self?.output.append(data, codec: codec)
        }
        output.onLog = { [weak self] line in self?.append(line) }
        output.onState = { [weak self] line in
            DispatchQueue.main.async { self?.status = line }
        }
        output.onTouches = { [weak self] points in
            guard let self else { return }
            if let first = points.first {
                self.local.touchesFromCarLink(pressed: true, x: first.x, y: first.y)
            } else {
                self.local.touchesFromCarLink(pressed: false, x: 0, y: 0)
            }
        }
        output.onControl = { [weak self] control in
            self?.local.pressRemote(control)
        }
        output.onKeyframeRequest = { [weak self] _ in
            // 复用现有的「进入出画」入口，它会向本机 CarPlay 请求关键帧。
            self?.local.carLinkPlayingChanged(true)
        }
    }
}
