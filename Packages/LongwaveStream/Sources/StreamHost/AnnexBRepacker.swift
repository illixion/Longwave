/// An encoder's Annex-B access unit in the shape the desktop stream carries
/// (NATIVE_V3_PROTOCOL.md section 4.8): HEVC parameter sets lifted out for the
/// format description, still Annex-B, and every other NAL unit 4-byte
/// big-endian length-prefixed, as v2 and CoreMedia take them.
public enum AnnexBRepacker {
    public struct Repacked: Sendable, Equatable {
        /// VPS, SPS and PPS, each behind a 4-byte start code; empty when the unit had none.
        public var parameterSets: [UInt8]
        /// The rest of the unit, length-prefixed.
        public var sample: [UInt8]

        public init(parameterSets: [UInt8], sample: [UInt8]) {
            self.parameterSets = parameterSets
            self.sample = sample
        }
    }

    /// Splits `accessUnit` on 3- and 4-byte start codes.
    public static func repack(hevc accessUnit: some Collection<UInt8>) -> Repacked {
        let bytes = Array(accessUnit)
        var result = Repacked(parameterSets: [], sample: [])
        result.sample.reserveCapacity(bytes.count)
        for nal in nalUnits(bytes) where !nal.isEmpty {
            let type = (bytes[nal.lowerBound] >> 1) & 0x3F
            if (32...34).contains(type) {
                result.parameterSets += [0, 0, 0, 1]
                result.parameterSets += bytes[nal]
            } else {
                let count = UInt32(nal.count)
                result.sample += [UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
                result.sample += bytes[nal]
            }
        }
        return result
    }

    /// The NAL units' ranges, start codes excluded. A 4-byte code's leading
    /// zero is not part of the unit before it.
    static func nalUnits(_ bytes: [UInt8]) -> [Range<Int>] {
        var starts: [(code: Int, nal: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i > 0 && bytes[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.indices.map { n in
            let end = n + 1 < starts.count ? starts[n + 1].code : bytes.count
            return starts[n].nal..<max(starts[n].nal, end)
        }
    }
}
