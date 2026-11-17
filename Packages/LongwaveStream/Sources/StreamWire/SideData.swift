// Frame side data (section 4.2): per-frame facts that travel inside the frame
// payload, so FEC and NACK protect them and they can't be paired with the
// wrong picture.

/// Side data item types. Append-only and open: unknown types are skipped.
public struct SideDataType: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let renderPose = SideDataType(rawValue: 1)
    public static let foveation = SideDataType(rawValue: 2)
    public static let depthRange = SideDataType(rawValue: 3)
    /// The PC's input bridge rendezvous (its addresses, ports and session
    /// token), opaque here, from the VR compositor about once a second. It
    /// rides the encrypted stream so a PCVR client finds the bridge without a
    /// side channel.
    public static let inputBridge = SideDataType(rawValue: 4)
    /// The game's own image motion per block of a PCVR depth frame
    /// (`MotionField`, capability `motionField`), for extrapolating the
    /// display frames that repeat it.
    public static let motionField = SideDataType(rawValue: 5)
    /// Producer to host only, never on the wire (a host strips it): the
    /// frame's alpha is 1 minus the head-locked HUD's coverage, so the host can
    /// mark those pixels for the headset (section 4.8). One byte, 1.
    public static let hudMark = SideDataType(rawValue: 6)

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "sideData(\(rawValue))" }
}

/// The pose a PCVR frame was rendered from (section 4.7). 102 bytes:
///
/// ```
///   0  u32  poseSequence   the head-pose snapshot it was rendered from
///   4  u16  spaceEpoch     that snapshot's space epoch
///   6  u64  displayTime    host ns the frame was rendered for
///  14  44   left eye       Pose (28) + FieldOfView (16), immersive space
///  58  44   right eye
/// ```
public struct RenderPose: Sendable, Hashable {
    public static let wireSize = 14 + 2 * EyeView.wireSize

    public var poseSequence: UInt32
    public var spaceEpoch: UInt16
    public var displayTime: UInt64
    public var left: EyeView
    public var right: EyeView

    public init(poseSequence: UInt32, spaceEpoch: UInt16, displayTime: UInt64, left: EyeView, right: EyeView) {
        self.poseSequence = poseSequence
        self.spaceEpoch = spaceEpoch
        self.displayTime = displayTime
        self.left = left
        self.right = right
    }

    func validate() throws(WireError) {
        try left.validate("renderPose.left")
        try right.validate("renderPose.right")
    }

    init(from reader: inout WireReader) throws(WireError) {
        poseSequence = try reader.readUInt32()
        spaceEpoch = try reader.readUInt16()
        displayTime = try reader.readUInt64()
        left = try reader.readEyeView()
        right = try reader.readEyeView()
        try validate()
    }

    func encode(to writer: inout WireWriter) {
        writer.writeUInt32(poseSequence)
        writer.writeUInt16(spaceEpoch)
        writer.writeUInt64(displayTime)
        writer.writeEyeView(left)
        writer.writeEyeView(right)
    }
}

/// A point in an eye image, normalised: (0, 0) top left, (1, 1) bottom right.
public struct NormalizedPoint: Sendable, Hashable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public static let centre = NormalizedPoint(x: 0.5, y: 0.5)

    func validate(_ field: String) throws(WireError) {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { throw .invalid(field) }
    }
}

/// Where the foveation warp was centred in each unwarped render image
/// (top-left UVs), before the centre interval is shifted inside the edges.
/// Reference equations: `CentreEdgeMapping`. 20 bytes:
/// `parameterEpoch u32 | left centre (x, y f32) | right centre (x, y f32)`.
/// The warp's shape comes from the stream's `FoveationParameters`; the epoch
/// must match them, or the receiver's unwarp would not invert the encoder's.
public struct FoveationSideData: Sendable, Hashable {
    public static let wireSize = 20

    public var parameterEpoch: UInt32
    public var leftCentre: NormalizedPoint
    public var rightCentre: NormalizedPoint

    public init(parameterEpoch: UInt32, leftCentre: NormalizedPoint = .centre, rightCentre: NormalizedPoint = .centre) {
        self.parameterEpoch = parameterEpoch
        self.leftCentre = leftCentre
        self.rightCentre = rightCentre
    }

    func validate() throws(WireError) {
        try leftCentre.validate("foveation.leftCentre")
        try rightCentre.validate("foveation.rightCentre")
    }

    init(from reader: inout WireReader) throws(WireError) {
        parameterEpoch = try reader.readUInt32()
        leftCentre = NormalizedPoint(x: try reader.readFloat32(), y: try reader.readFloat32())
        rightCentre = NormalizedPoint(x: try reader.readFloat32(), y: try reader.readFloat32())
        try validate()
    }

    func encode(to writer: inout WireWriter) {
        writer.writeUInt32(parameterEpoch)
        writer.writeFloat32(leftCentre.x)
        writer.writeFloat32(leftCentre.y)
        writer.writeFloat32(rightCentre.x)
        writer.writeFloat32(rightCentre.y)
    }
}

/// A depth frame's planes (section 4.8). 13 bytes:
/// `flags u8 (bit 0 empty, others reserved) | near f32 | far f32 | convergence f32`,
/// metres. An empty frame (a pre-rendered cutscene: no usable depth) has all
/// three at zero; the headset falls back to estimated depth.
public enum DepthRange: Sendable, Hashable {
    case empty
    /// `far` may be +infinity (an infinite far plane, common with reversed Z);
    /// inverse depth maps it to 0. `convergence` 0 means no suggestion.
    case planes(near: Float, far: Float, convergence: Float)

    public static let wireSize = 13

    func validate() throws(WireError) {
        guard case .planes(let near, let far, let convergence) = self else { return }
        guard near.isFinite, near > 0 else { throw .invalid("depthRange.near") }
        guard far > near else { throw .invalid("depthRange.far") } // false for NaN
        guard convergence.isFinite, convergence >= 0 else { throw .invalid("depthRange.convergence") }
    }

    init(from reader: inout WireReader) throws(WireError) {
        let flags = try reader.readUInt8()
        guard flags & ~1 == 0 else { throw .invalid("depthRange.flags") }
        let near = try reader.readFloat32()
        let far = try reader.readFloat32()
        let convergence = try reader.readFloat32()
        if flags & 1 != 0 {
            // Bit patterns, so -0.0 is rejected too and re-encoding is exact.
            guard near.bitPattern == 0, far.bitPattern == 0, convergence.bitPattern == 0 else {
                throw .inconsistent("depthRange.empty")
            }
            self = .empty
        } else {
            self = .planes(near: near, far: far, convergence: convergence)
            try validate()
        }
    }

    func encode(to writer: inout WireWriter) {
        switch self {
        case .empty:
            writer.writeUInt8(1)
            for _ in 0..<3 { writer.writeFloat32(0) }
        case .planes(let near, let far, let convergence):
            writer.writeUInt8(0)
            writer.writeFloat32(near)
            writer.writeFloat32(far)
            writer.writeFloat32(convergence)
        }
    }
}

/// The game's own image motion in a PCVR frame (section 4.8, capability
/// `motionField`), on the depth auxiliary's frame of the same number: per block
/// of each eye's render image, where that block's content was in the previous
/// eye frame, with the part the change of render pose explains removed (the
/// headset's warp already moves each frame from its render pose to the display
/// pose). So the content at render pixel `p` was at `p + v` one `interval`
/// earlier; a display frame shown `t` after the frame's own time samples it at
/// `p + v * t / interval` to carry the motion on.
///
/// ```
///  0  u8   flags          reserved, 0
///  1  u8   cellSize       render pixels per block side, both axes
///  2  u16  columns        blocks per eye row
///  4  u16  rows           block rows per eye
///  6  u16  renderWidth    the render eye the blocks tile (the last column and row may overhang it)
///  8  u16  renderHeight
/// 10  u32  interval       microseconds from the previous frame's render time to this one's
/// 14  f32  scale          render pixels per vector unit
/// 18  ...  vectors        left eye then right, rows top first, each block x i8 then y i8;
///                         x = -128 marks a block with no motion known (y then 0)
/// ```
public struct MotionField: Sendable, Hashable {
    public static let headerSize = 18
    /// The marker in a block's x for "no motion known".
    public static let unknown: Int8 = -128

    public var cellSize: UInt8
    public var columns: UInt16
    public var rows: UInt16
    public var renderSize: PixelSize
    public var interval: UInt32
    public var scale: Float
    /// `2 * 2 * columns * rows` values: per eye, per block, x then y.
    public var vectors: [Int8]

    public init(cellSize: UInt8, columns: UInt16, rows: UInt16, renderSize: PixelSize, interval: UInt32, scale: Float,
                vectors: [Int8]) {
        self.cellSize = cellSize
        self.columns = columns
        self.rows = rows
        self.renderSize = renderSize
        self.interval = interval
        self.scale = scale
        self.vectors = vectors
    }

    public var wireSize: Int { Self.headerSize + vectors.count }

    /// The most blocks per eye that fit one side data item beside the others.
    public static let maxBlocksPerEye = (Int(UInt16.max) - headerSize - 512) / 4

    func validate() throws(WireError) {
        guard cellSize > 0, columns > 0, rows > 0, Int(columns) * Int(rows) <= Self.maxBlocksPerEye else {
            throw .invalid("motionField.size")
        }
        guard renderSize.isNonZero, Int(columns) * Int(cellSize) >= Int(renderSize.width),
              Int(rows) * Int(cellSize) >= Int(renderSize.height),
              Int(columns - 1) * Int(cellSize) < Int(renderSize.width), Int(rows - 1) * Int(cellSize) < Int(renderSize.height)
        else { throw .inconsistent("motionField.renderSize") }
        guard interval > 0 else { throw .invalid("motionField.interval") }
        guard scale.isFinite, scale > 0 else { throw .invalid("motionField.scale") }
        guard vectors.count == 4 * Int(columns) * Int(rows) else { throw .inconsistent("motionField.vectors") }
    }

    init(from reader: inout WireReader) throws(WireError) {
        guard try reader.readUInt8() == 0 else { throw .invalid("motionField.flags") }
        cellSize = try reader.readUInt8()
        columns = try reader.readUInt16()
        rows = try reader.readUInt16()
        renderSize = PixelSize(width: try reader.readUInt16(), height: try reader.readUInt16())
        interval = try reader.readUInt32()
        scale = try reader.readFloat32()
        let count = 4 * Int(columns) * Int(rows)
        vectors = try reader.readBytes(count).map { Int8(bitPattern: $0) }
        try validate()
    }

    func encode(to writer: inout WireWriter) {
        writer.writeUInt8(0)
        writer.writeUInt8(cellSize)
        writer.writeUInt16(columns)
        writer.writeUInt16(rows)
        writer.writeUInt16(renderSize.width)
        writer.writeUInt16(renderSize.height)
        writer.writeUInt32(interval)
        writer.writeFloat32(scale)
        writer.writeBytes(vectors.map { UInt8(bitPattern: $0) })
    }
}

/// The side data of one frame: each known item at most once.
///
/// Wire: a sequence of `type u8 | length u16 | value` items, in ascending type
/// order when we encode. A decoder skips unknown types by length, rejects a
/// repeated known type, and accepts a known value longer than its defined size
/// (the extra bytes are a later revision's appended fields, ignored).
public struct SideData: Sendable, Hashable {
    public var renderPose: RenderPose?
    public var foveation: FoveationSideData?
    public var depthRange: DepthRange?
    /// Opaque (`SideDataType.inputBridge`), at most `maxInputBridge` bytes.
    public var inputBridge: [UInt8]?
    public static let maxInputBridge = 512
    public var motionField: MotionField?
    /// `SideDataType.hudMark`: producer to host only.
    public var hudMark = false

    public init(renderPose: RenderPose? = nil, foveation: FoveationSideData? = nil, depthRange: DepthRange? = nil,
                inputBridge: [UInt8]? = nil, motionField: MotionField? = nil, hudMark: Bool = false) {
        self.renderPose = renderPose
        self.foveation = foveation
        self.depthRange = depthRange
        self.inputBridge = inputBridge
        self.motionField = motionField
        self.hudMark = hudMark
    }

    public static let none = SideData()

    public var isEmpty: Bool { presentTypes.isEmpty }

    public var presentTypes: Set<SideDataType> {
        var types: Set<SideDataType> = []
        if renderPose != nil { types.insert(.renderPose) }
        if foveation != nil { types.insert(.foveation) }
        if depthRange != nil { types.insert(.depthRange) }
        if inputBridge != nil { types.insert(.inputBridge) }
        if motionField != nil { types.insert(.motionField) }
        if hudMark { types.insert(.hudMark) }
        return types
    }

    public func validate() throws(WireError) {
        try renderPose?.validate()
        try foveation?.validate()
        try depthRange?.validate()
        if let inputBridge, inputBridge.isEmpty || inputBridge.count > Self.maxInputBridge {
            throw .invalid("sideData.inputBridge")
        }
        try motionField?.validate()
    }

    /// Decodes items until the reader is exhausted.
    public init(items reader: inout WireReader) throws(WireError) {
        self.init()
        while !reader.isAtEnd {
            let type = SideDataType(rawValue: try reader.readUInt8())
            let length = Int(try reader.readUInt16())
            var value = try reader.subReader(length)
            switch type {
            case .renderPose:
                guard renderPose == nil else { throw .duplicate("sideData.renderPose") }
                renderPose = try RenderPose(from: &value)
            case .foveation:
                guard foveation == nil else { throw .duplicate("sideData.foveation") }
                foveation = try FoveationSideData(from: &value)
            case .depthRange:
                guard depthRange == nil else { throw .duplicate("sideData.depthRange") }
                depthRange = try DepthRange(from: &value)
            case .inputBridge:
                guard inputBridge == nil else { throw .duplicate("sideData.inputBridge") }
                guard length > 0, length <= Self.maxInputBridge else { throw .invalid("sideData.inputBridge") }
                inputBridge = Array(try value.readBytes(length))
            case .motionField:
                guard motionField == nil else { throw .duplicate("sideData.motionField") }
                motionField = try MotionField(from: &value)
            case .hudMark:
                guard !hudMark else { throw .duplicate("sideData.hudMark") }
                guard length >= 1, try value.readUInt8() == 1 else { throw .invalid("sideData.hudMark") }
                hudMark = true
            default:
                break // unknown: skipped by length
            }
        }
    }

    public func encodeItems(to writer: inout WireWriter) throws(WireError) {
        try validate()
        if let renderPose {
            writeItem(.renderPose, length: RenderPose.wireSize, to: &writer) { renderPose.encode(to: &$0) }
        }
        if let foveation {
            writeItem(.foveation, length: FoveationSideData.wireSize, to: &writer) { foveation.encode(to: &$0) }
        }
        if let depthRange {
            writeItem(.depthRange, length: DepthRange.wireSize, to: &writer) { depthRange.encode(to: &$0) }
        }
        if let inputBridge {
            writeItem(.inputBridge, length: inputBridge.count, to: &writer) { $0.writeBytes(inputBridge) }
        }
        if let motionField {
            writeItem(.motionField, length: motionField.wireSize, to: &writer) { motionField.encode(to: &$0) }
        }
        if hudMark {
            writeItem(.hudMark, length: 1, to: &writer) { $0.writeUInt8(1) }
        }
    }

    private func writeItem(_ type: SideDataType, length: Int, to writer: inout WireWriter,
                           _ body: (inout WireWriter) -> Void) {
        writer.writeUInt8(type.rawValue)
        writer.writeUInt16(UInt16(length))
        body(&writer)
    }

    /// Bytes `encodeItems` writes.
    public var encodedItemsLength: Int {
        (renderPose == nil ? 0 : 3 + RenderPose.wireSize)
            + (foveation == nil ? 0 : 3 + FoveationSideData.wireSize)
            + (depthRange == nil ? 0 : 3 + DepthRange.wireSize)
            + (inputBridge.map { 3 + $0.count } ?? 0)
            + (motionField.map { 3 + $0.wireSize } ?? 0)
            + (hudMark ? 4 : 0)
    }
}

/// The bytes a video frame is split into shards from (section 4.2):
///
/// ```
///  0  u32  contentLength    bytes after this field, before the padding
///  4  u16  sideDataLength
///  6  ...  side data items  (SideData)
///  .  ...  access unit      length-prefixed NAL units as v2 (4-byte big-endian
///                           lengths, AVCC/HVCC), or AV1 OBUs; may be empty
///  .  ...  zero padding     up to the end of the last data shard
/// ```
///
/// The side-data section is always present (length 0 when the frame has none)
/// so parsing never depends on the format message. The content length is here
/// rather than in the shard header because a data shard rebuilt from parity
/// must carry it too, and only the payload is FEC-protected.
public enum FramePayload {
    public static let headerSize = 6

    public struct Decoded: Sendable, Equatable {
        public var sideData: SideData
        /// A slice of the input. Empty means the frame carries side data only
        /// (an auxiliary placeholder such as an empty depth frame); don't feed
        /// it to a decoder.
        public var accessUnit: ArraySlice<UInt8>
    }

    /// Bytes `encode` produces before padding.
    public static func encodedLength(sideData: SideData, accessUnitLength: Int) -> Int {
        headerSize + sideData.encodedItemsLength + accessUnitLength
    }

    public static func encode(sideData: SideData, accessUnit: some Collection<UInt8>) throws(WireError) -> [UInt8] {
        let sideLength = sideData.encodedItemsLength
        guard sideLength <= Int(UInt16.max) else { throw .tooLarge("framePayload.sideData") }
        let contentLength = 2 + sideLength + accessUnit.count
        guard contentLength <= Int(UInt32.max) else { throw .tooLarge("framePayload.content") }
        var writer = WireWriter(reservingCapacity: 4 + contentLength)
        writer.writeUInt32(UInt32(contentLength))
        writer.writeUInt16(UInt16(sideLength))
        try sideData.encodeItems(to: &writer)
        writer.writeBytes(accessUnit)
        return writer.bytes
    }

    /// Splits reassembled frame data (possibly with trailing zero padding)
    /// into side data and access unit.
    public static func decode(_ data: ArraySlice<UInt8>) throws(WireError) -> Decoded {
        var reader = WireReader(data)
        let contentLength = Int(try reader.readUInt32())
        var content = try reader.subReader(contentLength)
        guard reader.bytes[reader.position...].allSatisfy({ $0 == 0 }) else { throw .invalid("framePayload.padding") }
        let sideLength = Int(try content.readUInt16())
        var items = try content.subReader(sideLength)
        let sideData = try SideData(items: &items)
        return Decoded(sideData: sideData, accessUnit: try content.readBytes(content.remaining))
    }

    public static func decode(_ data: [UInt8]) throws(WireError) -> Decoded {
        try decode(data[...])
    }
}
