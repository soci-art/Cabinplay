import Foundation

public enum AnnexB {
    /// Splits complete Annex-B access units into raw NAL units (without start codes).
    public static func units(in data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count <= 8 * 1024 * 1024 else { throw ProtocolError.limitExceeded("video access unit") }
        var starts: [(Int, Int)] = []; var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        guard let first = starts.first, bytes.prefix(first.0).allSatisfy({ $0 == 0 }) else {
            throw ProtocolError.malformed("Annex B start code")
        }
        return try starts.enumerated().map { index, entry in
            let begin = entry.0 + entry.1
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            guard end > begin else { throw ProtocolError.malformed("empty NAL unit") }
            return Data(bytes[begin..<end])
        }
    }
    /// Lightweight header scan of an Annex-B access unit: reports whether it
    /// carries a parameter-set NAL and whether it contains a random-access
    /// (IDR/IRAP) NAL, reading only each NAL's first header byte — no
    /// per-unit Data materialisation. The start-code walk mirrors
    /// `units(in:)` exactly and the result is nil wherever `units(in:)`
    /// would throw, so callers can fall back to the full parse. Used by the
    /// frame bridge once parameter sets are complete; any AU flagged with
    /// parameter sets must still go through `units` + absorb so changes
    /// (a resolution switch replaces the SPS) are picked up.
    public static func scanHeaders(in data: Data, codec: VideoCodec) -> (hasParameterSet: Bool, isKeyFrame: Bool)? {
        let bytes = [UInt8](data)
        guard bytes.count <= 8 * 1024 * 1024 else { return nil }
        var starts: [(Int, Int)] = []; var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        guard let first = starts.first, bytes.prefix(first.0).allSatisfy({ $0 == 0 }) else { return nil }
        var hasParameterSet = false
        var isKeyFrame = false
        for (index, entry) in starts.enumerated() {
            let begin = entry.0 + entry.1
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            guard end > begin else { return nil }
            let type = codec.nalType(firstByte: bytes[begin])
            if codec.parameterSet(nalType: type) != nil { hasParameterSet = true }
            if codec.isRandomAccess(nalType: type) { isKeyFrame = true }
        }
        return (hasParameterSet, isKeyFrame)
    }
    public static func lengthPrefixed(_ units: [Data]) throws -> Data {
        var result = Data()
        for unit in units {
            guard !unit.isEmpty, unit.count <= 8 * 1024 * 1024 else { throw ProtocolError.malformed("NAL unit size") }
            result.putBE32(UInt32(unit.count)); result.append(unit)
        }
        return result
    }
}
