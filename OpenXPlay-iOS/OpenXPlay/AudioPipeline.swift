// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// AudioPipeline — CarPlay 的音频以 RTP（AAC-LC / LPCM）送到 sink，这里做 RTP
// 拆包 + AVAudioConverter 解码，再交给 AVAudioEngine 播放。
// AAC-ELD / Opus / ALAC 目前只记日志（车机蓝牙仍然是主要出声路径）。

import AVFoundation

final class AudioPipeline {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var configured = false
    private var loggedUnsupported = false

    func configure(formatJSON: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: formatJSON) as? [String: Any],
              let codec = object["codec"] as? String,
              let sampleRate = object["sampleRate"] as? Double,
              let channels = object["channels"] as? Int else {
            return
        }

        let isLPCM = codec.hasPrefix("Lpcm")
        let isAAC = codec.hasPrefix("AacLc")
        guard isLPCM || isAAC else {
            if !loggedUnsupported {
                CarPlayCore.shared.onLog?("音频编码 \(codec) 不在本地播放范围（改用车机蓝牙）")
                loggedUnsupported = true
            }
            return
        }

        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: UInt32(channels),
                                         interleaved: true) else { return }
        outputFormat = output

        if isAAC,
           let input = AVAudioFormat(settings: [
               AVFormatIDKey: kAudioFormatMPEG4AAC,
               AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: channels,
           ]) {
            converter = AVAudioConverter(from: input, to: output)
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: output)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try engine.start()
            player.play()
            configured = true
            CarPlayCore.shared.onLog?("音频已启动（\(isAAC ? "AAC-LC" : "LPCM") \(Int(sampleRate))Hz \(channels)ch）")
        } catch {
            CarPlayCore.shared.onLog?("音频引擎启动失败：\(error.localizedDescription)")
        }
    }

    func push(rtp: Data) {
        guard configured, let outputFormat else { return }
        let packets = Self.depacketize(rtp)
        for packet in packets {
            if let converter {
                decodeAAC(packet, to: outputFormat, using: converter)
            } else if let buffer = Self.pcmBuffer(packet, format: outputFormat) {
                player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            }
        }
    }

    private func decodeAAC(_ packet: Data, to output: AVAudioFormat, using converter: AVAudioConverter) {
        guard let input = AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: output.sampleRate,
            AVNumberOfChannelsKey: output.channelCount,
        ]) else { return }

        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: packet.count)
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.count)
        )
        packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(compressed.data, base, packet.count)
        }

        let frames = AVAudioFrameCount(output.sampleRate * 0.05)
        guard let decoded = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: frames) else { return }
        var error: NSError?
        var supplied = false
        converter.convert(to: decoded, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return compressed
        }
        if let error {
            CarPlayCore.shared.onLog?("AAC 解码失败：\(error.localizedDescription)")
            return
        }
        if decoded.frameLength > 0 {
            player.scheduleBuffer(decoded, at: nil, options: [], completionHandler: nil)
        }
    }

    // MARK: - RTP / AAC-hbr

    static func depacketize(_ rtp: Data) -> [Data] {
        let bytes = [UInt8](rtp)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return [] }
        var offset = 12 + Int(bytes[0] & 0x0F) * 4
        if bytes[0] & 0x10 != 0 {
            guard offset + 4 <= bytes.count else { return [] }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
        }
        guard offset + 2 <= bytes.count else { return [] }

        let headersLengthBits = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        offset += 2
        let headerCount = headersLengthBits / 16
        guard headerCount > 0 else {
            return offset < bytes.count ? [Data(bytes[offset...])] : []
        }
        var sizes: [Int] = []
        for index in 0..<headerCount {
            let at = offset + index * 2
            guard at + 1 < bytes.count else { return [] }
            let header = Int(bytes[at] & 0x1F) << 8 | Int(bytes[at + 1])
            sizes.append(header >> 3)
        }
        offset += headerCount * 2
        var packets: [Data] = []
        for size in sizes {
            guard size > 0, offset + size <= bytes.count else { break }
            packets.append(Data(bytes[offset..<offset + size]))
            offset += size
        }
        return packets
    }

    static func pcmBuffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = data.count / 2 / Int(format.channelCount)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let destination = buffer.int16ChannelData?[0] else { return }
            memcpy(destination, base, data.count)
        }
        return buffer
    }
}
