/// The variable-length integer used for frame and message lengths (section
/// 4.1): unsigned LEB128, at most three bytes, canonical.
///
/// Each byte carries seven value bits, least significant group first; the top
/// bit says another byte follows. Three bytes cover 0...2,097,151, more than
/// any datagram (a frame length) or control message (`Message.maxBodyLength`)
/// needs. Canonical means minimal: a multi-byte varint whose last byte is 0 is
/// rejected, so every length has exactly one encoding and a re-encoded value
/// is byte-identical to what was received.
public enum Varint {
    public static let maxLength = 3
    public static let maxValue = (1 << (7 * maxLength)) - 1

    public enum Prefix: Equatable, Sendable {
        /// The buffer ends before the varint does (a stream parser waits for
        /// more bytes).
        case incomplete
        case complete(value: Int, length: Int)
    }

    public static func encodedLength(_ value: Int) -> Int {
        value < 1 << 7 ? 1 : value < 1 << 14 ? 2 : 3
    }

    public static func write(_ value: Int, to writer: inout WireWriter) throws(WireError) {
        guard value >= 0, value <= maxValue else { throw .tooLarge("varint") }
        var rest = value
        while rest >= 0x80 {
            writer.writeUInt8(UInt8(truncatingIfNeeded: rest) | 0x80)
            rest >>= 7
        }
        writer.writeUInt8(UInt8(rest))
    }

    /// Parses a varint at the start of `bytes`.
    public static func parsePrefix(_ bytes: ArraySlice<UInt8>) throws(WireError) -> Prefix {
        var value = 0
        var index = bytes.startIndex
        for group in 0..<maxLength {
            guard index < bytes.endIndex else { return .incomplete }
            let byte = bytes[index]
            value |= Int(byte & 0x7F) << (7 * group)
            index += 1
            if byte & 0x80 == 0 {
                if group > 0, byte == 0 { throw .nonCanonicalVarint }
                return .complete(value: value, length: group + 1)
            }
        }
        throw .varintTooLong
    }
}
