/// Appends little-endian fields to a growing byte buffer.
///
/// Writes of fixed-width fields cannot fail. Varints and length fields can be
/// out of range for their encoding, and throw rather than trap.
public struct WireWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(reservingCapacity capacity: Int = 0) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }

    public mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    public mutating func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    public mutating func writeUInt32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    public mutating func writeUInt64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    public mutating func writeInt16(_ value: Int16) {
        writeUInt16(UInt16(bitPattern: value))
    }

    public mutating func writeInt32(_ value: Int32) {
        writeUInt32(UInt32(bitPattern: value))
    }

    public mutating func writeFloat32(_ value: Float) {
        writeUInt32(value.bitPattern)
    }

    public mutating func writeBool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    public mutating func writeBytes(_ data: some Sequence<UInt8>) {
        bytes.append(contentsOf: data)
    }

    public mutating func writeVarint(_ value: Int) throws(WireError) {
        try Varint.write(value, to: &self)
    }

    /// Writes a u16 length field followed by `data`, checking it fits.
    public mutating func writeLengthPrefixed16(_ data: some Collection<UInt8>, field: String) throws(WireError) {
        guard data.count <= Int(UInt16.max) else { throw .tooLarge(field) }
        writeUInt16(UInt16(data.count))
        writeBytes(data)
    }

    /// Overwrites a u16 previously written at `offset` (for length fields
    /// whose value is known only after the body is written).
    mutating func patchUInt16(_ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}
