// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// PictureInPicture — 把 CarPlay 画面放进系统画中画，切到别的 App 时也能看到。
// 使用 AVSampleBufferDisplayLayer 作为内容源（iOS 15+ 的 API）。

import AVKit
import AVFoundation

final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate,
                               AVPictureInPictureSampleBufferPlaybackDelegate {
    private var controller: AVPictureInPictureController?

    func setup(layer: AVSampleBufferDisplayLayer) -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = false
        self.controller = controller
        return true
    }

    @discardableResult
    func start() -> Bool {
        guard let controller else { return false }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            CarPlayCore.shared.onLog?("画中画音频会话失败：\(error.localizedDescription)")
        }
        guard controller.isPictureInPicturePossible else {
            CarPlayCore.shared.onLog?("画中画暂不可用（需要先有画面）")
            return false
        }
        controller.startPictureInPicture()
        return true
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        CarPlayCore.shared.onLog?("画中画启动失败：\(error.localizedDescription)")
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
