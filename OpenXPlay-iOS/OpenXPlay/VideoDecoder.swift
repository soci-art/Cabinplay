// SPDX-FileCopyrightText: 2026 OpenXPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// VideoDecoder — turns the Annex-B NAL units the Rust core emits into
// CMSampleBuffers and hands them to AVSampleBufferDisplayLayer, which decodes
// H.264/HEVC itself. The decoder configuration (AVCDecoderConfigurationRecord
// or hvcC) arrives once per stream.

import AVFoundation
import CoreMedia
import UIKit
import VideoToolbox

final class VideoDecoder {
    let layer = AVSampleBufferDisplayLayer()

    private var format: CMVideoFormatDescription?
    private var codec: UInt32 = 1

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func reset() {
        format = nil
        layer.flushAndRemoveImage()
        if layer.status == .failed {
            layer.flush()
        }
    }

    func configure(codec: UInt32, config: Data) {
        self.codec = codec
        format = codec == 2 ? Self.hevcFormat(config) : Self.h264Format(config)
    }

    func append(_ annexB: Data, ptsNanos: UInt64) {
        guard let format, !annexB.isEmpty else { return }
        let avcc = Self.avcc(fromAnnexB: annexB)
        guard !avcc.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return }
        _ = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(ptsNanos), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        let size = CMVideoFormatDescriptionGetDimensions(format)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [avcc.count],
            sampleBufferOut: &sample
        ) == noErr, let sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        _ = size

        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sample)
    }

    // MARK: - Format descriptions

    private static func h264Format(_ config: Data) -> CMVideoFormatDescription? {
        let bytes = [UInt8](config)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        var sets: [[UInt8]] = []
        var cursor = 5
        let spsCount = Int(bytes[cursor] & 0x1F)
        cursor += 1
        for _ in 0..<spsCount {
            guard cursor + 2 <= bytes.count else { break }
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
            guard length > 0, cursor + length <= bytes.count else { break }
            sets.append(Array(bytes[cursor..<cursor + length]))
            cursor += length
        }
        guard cursor < bytes.count else { return nil }
        let ppsCount = Int(bytes[cursor])
        cursor += 1
        for _ in 0..<ppsCount {
            guard cursor + 2 <= bytes.count else { break }
            let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
            guard length > 0, cursor + length <= bytes.count else { break }
            sets.append(Array(bytes[cursor..<cursor + length]))
            cursor += length
        }
        return makeH264Description(sets)
    }

    private static func makeH264Description(_ sets: [[UInt8]]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty else { return nil }
        var description: CMVideoFormatDescription?
        var pointers: [UnsafePointer<UInt8>] = []
        var lengths: [Int] = []
        var storage: [UnsafeMutablePointer<UInt8>] = []
        defer { storage.forEach { $0.deallocate() } }
        for set in sets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            buffer.initialize(from: set, count: set.count)
            storage.append(buffer)
            pointers.append(UnsafePointer(buffer))
            lengths.append(set.count)
        }
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            lengths.withUnsafeBufferPointer { lengthBuffer in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: lengthBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    private static func hevcFormat(_ config: Data) -> CMVideoFormatDescription? {
        // hvcC: 23-byte header, then arrays of parameter set NALs (VPS/SPS/PPS).
        let bytes = [UInt8](config)
        guard bytes.count > 23 else { return nil }
        var sets: [[UInt8]] = []
        var cursor = 23
        let arrayCount = Int(bytes[22])
        for _ in 0..<arrayCount {
            guard cursor + 3 <= bytes.count else { break }
            cursor += 1 // array_completeness + NAL unit type
            let count = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
            cursor += 2
            for _ in 0..<count {
                guard cursor + 2 <= bytes.count else { break }
                let length = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1])
                cursor += 2
                guard length > 0, cursor + length <= bytes.count else { break }
                sets.append(Array(bytes[cursor..<cursor + length]))
                cursor += length
            }
        }
        guard !sets.isEmpty else { return nil }
        var description: CMVideoFormatDescription?
        var pointers: [UnsafePointer<UInt8>] = []
        var lengths: [Int] = []
        var storage: [UnsafeMutablePointer<UInt8>] = []
        defer { storage.forEach { $0.deallocate() } }
        for set in sets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            buffer.initialize(from: set, count: set.count)
            storage.append(buffer)
            pointers.append(UnsafePointer(buffer))
            lengths.append(set.count)
        }
        let status = pointers.withUnsafeBufferPointer { pointerBuffer in
            lengths.withUnsafeBufferPointer { lengthBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: lengthBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    // MARK: - Annex-B → AVCC

    private static func avcc(fromAnnexB data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data()
        var i = 0
        var nalStart: Int?
        func flush(_ end: Int) {
            guard let start = nalStart, end > start else { return }
            var nal = Array(bytes[start..<end])
            // Drop trailing zero padding that some senders append.
            while let last = nal.last, last == 0 { nal.removeLast() }
            guard !nal.isEmpty else { return }
            let length = UInt32(nal.count)
            out.append(contentsOf: [UInt8(length >> 24 & 0xFF),
                                    UInt8(length >> 16 & 0xFF),
                                    UInt8(length >> 8 & 0xFF),
                                    UInt8(length & 0xFF)])
            out.append(contentsOf: nal)
        }
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if nalStart != nil { flush(i) }
                nalStart = i + 3
                i += 3
            } else if i + 4 <= bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                if nalStart != nil { flush(i) }
                nalStart = i + 4
                i += 4
            } else {
                i += 1
            }
        }
        flush(bytes.count)
        return out
    }
}
