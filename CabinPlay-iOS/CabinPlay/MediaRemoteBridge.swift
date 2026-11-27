// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// MediaRemoteBridge：把车机音响键接回 CarPlay。
//
// 音频走 A2DP 时，车机媒体键是蓝牙 AVRCP 命令，由 iOS 派给「正在播放的
// App」。本 App 自己解码/转发 CarPlay 音频，就成了那个 App，所以必须自己
// 挂 MPRemoteCommandCenter，否则命令落到系统默认空实现。
//
// 2026-11-27 实机反馈：上一首/下一首能用，播放/暂停（车机上的 OK）不能用。
// 说明 AVRCP 确实到了本 App，但「播放/暂停」这一支要么没被系统派发、要么
// 派成了别的命令。这一版把能接的命令全接上并逐条打日志，下一次日志就能
// 直接看出车机按 OK 时到底来了哪条命令。

import Foundation
import MediaPlayer

final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    private weak var session: LocalCarPlaySession?
    private var installed = false
    private var log: ((String) -> Void)?

    func install(for session: LocalCarPlaySession, log: @escaping (String) -> Void) {
        self.session = session
        self.log = log
        guard !installed else { return }
        installed = true

        let center = MPRemoteCommandCenter.shared()
        bind(center.playCommand, "播放", .play)
        bind(center.pauseCommand, "暂停", .pause)
        bind(center.togglePlayPauseCommand, "播放/暂停", .playPause)
        bind(center.nextTrackCommand, "下一曲", .next)
        bind(center.previousTrackCommand, "上一曲", .previous)
        // 下面这些不一定被派发，但接上并记录，才能看出「OK」是不是被系统
        // 派成了 stop / skip / seek 之类。
        bind(center.stopCommand, "停止", .pause)
        bind(center.skipForwardCommand, "快进(跳过)", .next)
        bind(center.skipBackwardCommand, "快退(跳过)", .previous)
        observe(center.seekForwardCommand, "快进")
        observe(center.seekBackwardCommand, "快退")
        observe(center.changePlaybackPositionCommand, "拖动播放位置")
        log("媒体键：已接管车机 AVRCP（播放/暂停/上一曲/下一曲，含 stop/skip/seek 观察）")
    }

    private func bind(_ command: MPRemoteCommand, _ name: String, _ control: CarPlayControl) {
        command.isEnabled = true
        command.addTarget { [weak self] _ in
            self?.forward(control, name) ?? .commandFailed
        }
    }

    private func observe(_ command: MPRemoteCommand, _ name: String) {
        command.isEnabled = true
        command.addTarget { [weak self] _ in
            self?.log?("媒体键 \(name)：收到命令（未映射到动作，仅记录）")
            return .success
        }
    }

    private func forward(_ control: CarPlayControl, _ name: String) -> MPRemoteCommandHandlerStatus {
        guard let session, session.controlConnected else {
            log?("媒体键 \(name)：CarPlay 还没连上，忽略")
            return .noSuchContent
        }
        log?("媒体键 \(name)：转给 CarPlay 媒体键")
        session.pressRemote(control)
        return .success
    }
}
