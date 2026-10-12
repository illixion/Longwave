/// A bounds-checked little-endian cursor over received bytes.
///
/// Every read checks the remaining length first and throws
/// `WireError.truncated` instead of indexing past the end, so no input can
/// make a parser trap. Reads of byte runs return slices of the input, not
/// copies.
public struct WireReader: Sendable {
    public let bytes: ArraySlice<UInt8>
    /// Absolute index into `bytes` of the next unread byte.
    public private(set) var position: Int

    public init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        position = bytes.startIndex
    }

    public init(_ bytes: [UInt8]) {
        self.init(bytes[...])
    }

    public var remaining: Int { bytes.endIndex - position }
    public var isAtEnd: Bool { position == bytes.endIndex }
    /// Bytes read so far.
    public var consumed: Int { position - bytes.startIndex }

    /// Claims `count` bytes and returns the index of the first.
    @inline(__always)
    private mutating func take(_ count: Int) throws(WireError) -> Int {
        guard count >= 0, count <= remaining else { throw .truncated }
        let start = position
        position += count
        return start
    }

    public mutating func readUInt8() throws(WireError) -> UInt8 {
        bytes[try take(1)]
    }

    public mutating func readUInt16() throws(WireError) -> UInt16 {
        let i = try take(2)
        return UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
    }

    public mutating func readUInt32() throws(WireError) -> UInt32 {
        let i = try take(4)
        var value: UInt32 = 0
        for offset in (0..<4).reversed() { value = value << 8 | UInt32(bytes[i + offset]) }
        return value
    }

    public mutating func readUInt64() throws(WireError) -> UInt64 {
        let i = try take(8)
        var value: UInt64 = 0
        for offset in (0..<8).reversed() { value = value << 8 | UInt64(bytes[i + offset]) }
        return value
    }

    public mutating func readInt16() throws(WireError) -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    public mutating func readInt32() throws(WireError) -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    /// IEEE 754 binary32, little-endian.
    public mutating func readFloat32() throws(WireError) -> Float {
        Float(bitPattern: try readUInt32())
    }

    /// A byte that must be 0 or 1.
    public mutating func readBool(_ field: String) throws(WireError) -> Bool {
        switch try readUInt8() {
        case 0: return false
        case 1: return true
        default: throw .invalid(field)
        }
    }

    public mutating func readBytes(_ count: Int) throws(WireError) -> ArraySlice<UInt8> {
        let i = try take(count)
        return bytes[i..<(i + count)]
    }

    public mutating func skip(_ count: Int) throws(WireError) {
        _ = try take(count)
    }

    /// A canonical LEB128 varint (see `Varint`).
    public mutating func readVarint() throws(WireError) -> Int {
        switch try Varint.parsePrefix(bytes[position...]) {
        case .incomplete:
            throw .truncated
        case .complete(let value, let length):
            position += length
            return value
        }
    }

    /// Consumes the next `count` bytes and returns a reader confined to them.
    public mutating func subReader(_ count: Int) throws(WireError) -> WireReader {
        WireReader(try readBytes(count))
    }

    /// Throws if anything is left unread.
    public func finish() throws(WireError) {
        guard isAtEnd else { throw .trailingBytes(remaining) }
    }
}
