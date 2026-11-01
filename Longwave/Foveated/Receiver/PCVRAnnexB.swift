#if FOVEATED_ENABLED
import Foundation

/// HEVC Annex-B handling for the v3 PCVR stream. The Windows host sends NVENC's
/// output as is: start-code delimited NAL units, with the parameter sets in the
/// format description (`FormatKind.annexBParameterSets`) and again in front of
/// every IDR. VideoToolbox wants neither: parameter sets go into the
/// `CMVideoFormatDescription`, and samples are 4-byte length prefixed.
nonisolated enum PCVRAnnexB {
    /// HEVC `nal_unit_type` values this code cares about.
    enum NALType {
        static let vps: UInt8 = 32
        static let sps: UInt8 = 33
        static let pps: UInt8 = 34
        static let accessUnitDelimiter: UInt8 = 35
    }

    /// The NAL units in an Annex-B byte stream, without their start codes.
    /// Accepts 3- and 4-byte start codes; bytes before the first start code
    /// are ignored. A NAL unit's trailing zero bytes (the leading zero of a
    /// following 4-byte start code) are trimmed, as H.265 B.2 allows.
    static func nalUnits(_ bytes: some Collection<UInt8>) -> [ArraySlice<UInt8>] {
        let data = Array(bytes)
        var starts: [(codeStart: Int, payloadStart: Int)] = []
        var index = 0
        while index + 2 < data.count {
            if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                starts.append((index, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        var units: [ArraySlice<UInt8>] = []
        for (position, start) in starts.enumerated() {
            var end = position + 1 < starts.count ? starts[position + 1].codeStart : data.count
            while end > start.payloadStart, data[end - 1] == 0 { end -= 1 }
            if end > start.payloadStart { units.append(data[start.payloadStart..<end]) }
        }
        return units
    }

    /// `nal_unit_type` of a NAL unit (bits 1-6 of its first header byte).
    static func type(of unit: ArraySlice<UInt8>) -> UInt8? {
        unit.first.map { ($0 >> 1) & 0x3F }
    }

    /// VPS, SPS and PPS out of a format description's configuration, in that
    /// order, or nil when any is missing.
    static func parameterSets(_ configuration: some Collection<UInt8>) -> (vps: [UInt8], sps: [UInt8], pps: [UInt8])? {
        var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
        for unit in nalUnits(configuration) {
            switch type(of: unit) {
            case NALType.vps: vps = vps ?? Array(unit)
            case NALType.sps: sps = sps ?? Array(unit)
            case NALType.pps: pps = pps ?? Array(unit)
            default: break
            }
        }
        guard let vps, let sps, let pps else { return nil }
        return (vps, sps, pps)
    }

    /// An access unit as a VideoToolbox sample: every NAL unit with a 4-byte
    /// big-endian length, minus parameter sets and delimiters (the format
    /// description carries the former; the latter mean nothing in a sample).
    /// Empty when nothing decodable is left.
    static func lengthPrefixedSample(_ accessUnit: some Collection<UInt8>) -> [UInt8] {
        var sample: [UInt8] = []
        sample.reserveCapacity(accessUnit.count + 16)
        for unit in nalUnits(accessUnit) {
            switch type(of: unit) {
            case NALType.vps, NALType.sps, NALType.pps, NALType.accessUnitDelimiter: continue
            default: break
            }
            let length = UInt32(unit.count)
            sample.append(UInt8(length >> 24))
            sample.append(UInt8((length >> 16) & 0xFF))
            sample.append(UInt8((length >> 8) & 0xFF))
            sample.append(UInt8(length & 0xFF))
            sample.append(contentsOf: unit)
        }
        return sample
    }
}
#endif
