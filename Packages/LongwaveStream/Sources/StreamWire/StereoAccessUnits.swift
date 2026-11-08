/// Two independently encoded eye pictures sharing one native frame number,
/// capture time and render pose. Only used with `StereoLayout.separateAccessUnits`.
/// HEVC parameter sets occur in each eye's IDR as usual; no decode/re-encode is
/// required to hand either eye to another presenter.
/// Wire: left byte count u32, right byte count u32, left AU, right AU.
public struct StereoAccessUnits: WireCodable {
    public static let maximumEyeBytes = 4 * 1024 * 1024
    public var left: ArraySlice<UInt8>
    public var right: ArraySlice<UInt8>

    public init(left: [UInt8], right: [UInt8]) {
        self.left = left[...]
        self.right = right[...]
    }

    private func validate() throws(WireError) {
        guard !left.isEmpty, !right.isEmpty else { throw .invalid("stereoAccessUnits.emptyEye") }
        guard left.count <= Self.maximumEyeBytes, right.count <= Self.maximumEyeBytes else {
            throw .tooLarge("stereoAccessUnits.eye")
        }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        let leftCount = Int(try reader.readUInt32())
        let rightCount = Int(try reader.readUInt32())
        guard leftCount <= Self.maximumEyeBytes, rightCount <= Self.maximumEyeBytes else {
            throw .tooLarge("stereoAccessUnits.eye")
        }
        left = try reader.readBytes(leftCount)
        right = try reader.readBytes(rightCount)
        try validate()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt32(UInt32(left.count))
        writer.writeUInt32(UInt32(right.count))
        writer.writeBytes(left)
        writer.writeBytes(right)
    }

    public func encoded() throws(WireError) -> [UInt8] {
        var writer = WireWriter(reservingCapacity: 8 + left.count + right.count)
        try encode(to: &writer)
        return writer.bytes
    }
}
