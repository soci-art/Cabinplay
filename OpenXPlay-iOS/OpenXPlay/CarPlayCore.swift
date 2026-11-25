// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// CarPlayCore — Swift wrapper around the Rust receiver (rust/oxp-ios).
// The C callbacks cannot capture context, so every callback reads the
// CarPlayCore instance back out of the opaque `context` pointer.

import Foundation

struct CoreLog: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
}

final class CarPlayCore {
    static let shared = CarPlayCore()

    var onLog: ((String) -> Void)?
    var onState: ((String) -> Void)?
    var onVideoCodec: ((UInt16, UInt32) -> Void)?
    var onVideoConfig: ((UInt16, Data) -> Void)?
    var onVideoFrame: ((UInt16, Data, UInt64) -> Void)?
    var onAudioFormat: ((Data) -> Void)?

    private(set) var running = false
    private(set) var lastError: String?

    private init() {}

    /// Start the receiver. `identityDirectory` must contain
    /// `identity.pk8` and `certificate.p7b`.
    func start(identityDirectory: URL, deviceId: String, btMac: String,
               width: UInt32, height: UInt32, fps: UInt32, port: UInt16) -> Bool {
        if running { return true }
        lastError = nil

        var callbacks = OxpCallbacks()
        callbacks.context = Unmanaged.passUnretained(self).toOpaque()
        callbacks.on_video_codec = { context, kind, codec in
            guard let context else { return }
            Unmanaged<CarPlayCore>.fromOpaque(context).takeUnretainedValue()
                .onVideoCodec?(kind, codec)
        }
        callbacks.on_video_config = { context, kind, bytes, length in
            guard let context, let bytes else { return }
            let data = Data(bytes: bytes, count: length)
            Unmanaged<CarPlayCore>.fromOpaque(context).takeUnretainedValue()
                .onVideoConfig?(kind, data)
        }
        callbacks.on_video_frame = { context, kind, bytes, length, nanos in
            guard let context, let bytes else { return }
            let data = Data(bytes: bytes, count: length)
            Unmanaged<CarPlayCore>.fromOpaque(context).takeUnretainedValue()
                .onVideoFrame?(kind, data, nanos)
        }
        callbacks.on_audio_format = { context, bytes, length in
            guard let context, let bytes else { return }
            Unmanaged<CarPlayCore>.fromOpaque(context).takeUnretainedValue()
                .onAudioFormat?(Data(bytes: bytes, count: length))
        }
        callbacks.on_state = { context, bytes, length in
            guard let context, let bytes else { return }
            let text = String(decoding: Data(bytes: bytes, count: length), as: UTF8.self)
            Unmanaged<CarPlayCore>.fromOpaque(context).takeUnretainedValue()
                .handleState(text)
        }
        callbacks.on_log = { context, bytes, length in
            guard let context, let bytes else { return }
            let text = String(decoding: Data(bytes: bytes, count: length), as: UTF8.self)
            Unmanaged<CarPlayCore>.fromOpaque(context).takeUnretainedValue()
                .emit(text)
        }

        let code = identityDirectory.path.withCString { dir in
            deviceId.withCString { device in
                btMac.withCString { mac in
                    oxp_start(dir, device, mac, width, height, fps, port, callbacks)
                }
            }
        }
        running = code == 0
        if !running {
            lastError = "接收端启动失败（错误码 \(code)）"
            emit(lastError!)
        }
        return running
    }

    func stop() {
        guard running else { return }
        _ = oxp_stop()
        running = false
        emit("接收端已停止")
    }

    fileprivate func emit(_ text: String) {
        onLog?(text)
        onState?(text)
    }

    fileprivate func handleState(_ text: String) {
        if text.hasPrefix("error: ") {
            lastError = String(text.dropFirst("error: ".count))
        }
        onState?(text)
        onLog?(text)
    }
}
