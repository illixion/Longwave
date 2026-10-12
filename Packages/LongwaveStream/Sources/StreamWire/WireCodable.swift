/// A value with one binary encoding.
///
/// Encoding validates with the same rules as decoding, so anything that
/// encodes also decodes, and decoding then re-encoding a value reproduces it.
public protocol WireCodable: Sendable, Equatable {
    init(from reader: inout WireReader) throws(WireError)
    func encode(to writer: inout WireWriter) throws(WireError)
}

extension WireCodable {
    /// Decodes a value that must occupy all of `bytes`.
    public init(decoding bytes: ArraySlice<UInt8>) throws(WireError) {
        var reader = WireReader(bytes)
        try self.init(from: &reader)
        try reader.finish()
    }

    public init(decoding bytes: [UInt8]) throws(WireError) {
        try self.init(decoding: bytes[...])
    }

    public func encoded() throws(WireError) -> [UInt8] {
        var writer = WireWriter()
        try encode(to: &writer)
        return writer.bytes
    }
}

/// RFC 1982 serial-number comparison for counters that wrap: frame numbers,
/// STATE sequence numbers, epochs.
public enum SerialNumber {
    /// Whether `a` is after `b`, treating the counter as circular (anything
    /// less than half the range ahead counts as newer).
    public static func isNewer(_ a: UInt32, than b: UInt32) -> Bool {
        a != b && a &- b < 0x8000_0000
    }

    public static func isNewer(_ a: UInt16, than b: UInt16) -> Bool {
        a != b && a &- b < 0x8000
    }
}
