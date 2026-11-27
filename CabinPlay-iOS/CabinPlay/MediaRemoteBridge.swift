// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// MediaRemoteBridge：把车机音响键接回 CarPlay。
//
// 音频走 A2DP 时，车机的播放/暂停/上一曲/下一曲不是 CarLink 的 UIBC 按键，
// 而是蓝牙 AVRCP 媒体命令，由 iOS 派给「正在播放的 App」。本 App 自己解码
// 播放 CarPlay 音频（CarPlayAudio / AVAudioEngine），就成了那个 App；但以前
// 没注册 MPRemoteCommandCenter，命令落到系统默认空实现，车机按键等于没
// 反应。这里把媒体命令转成 CarPlay 的媒体 HID 键（NativeReceiver.press →
// CarPlayMediaSession.pressHID），与车机 UIBC 的播放/暂停走同一个动作。

import Foundation
import MediaPlayer

final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    private weak var session: LocalCarPlaySession?
    private var installed = false
    private var log: ((String) -> Void)?

    /// 每次本机 CarPlay 会话启动时调用；命令处理只装一次。
    func install(for session: LocalCarPlaySession, log: @escaping (String) -> Void) {
        self.session = session
        self.log = log
        guard !installed else { return }
        installed = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.forward(.playPause, "播放") ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.forward(.playPause, "暂停") ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.forward(.playPause, "播放/暂停") ?? .commandFailed }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.forward(.next, "下一曲") ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.forward(.previous, "上一曲") ?? .commandFailed }
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.isEnabled = true
        }
        log("媒体键：已接管车机 AVRCP（播放/暂停/上一曲/下一曲 → CarPlay 媒体键）")
    }

    private func forward(_ control: CarPlayControl, _ name: String) -> MPRemoteCommandHandlerStatus {
        guard let session, session.controlConnected else {
            log?("媒体键 \(name)：CarPlay 还没连上，忽略")
            return .noSuchContent
        }
        log?("媒体键 \(name)：转给 CarPlay")
        session.pressRemote(control)
        return .success
    }
}
