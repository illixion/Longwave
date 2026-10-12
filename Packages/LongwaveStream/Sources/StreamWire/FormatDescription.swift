// The `formatDescription` control message (sections 4.2, 4.7, 4.8).

public enum VideoCodec: UInt8, Sendable, CaseIterable {
    case hevc = 1
    case h264 = 2
    case av1 = 3
}

/// How `FormatDescription.configuration` is encoded. Raw values 0 and 1 are
/// v2's `FormatKind`; 1 is generalised from HEVC to any Annex-B codec.
public enum FormatKind: UInt8, Sendable, CaseIterable {
    /// CoreMedia big-endian ImageDescription blob (Apple hosts).
    case coreMediaImageDescription = 0
    /// Concatenated Annex-B parameter sets with start codes: VPS/SPS/PPS for
    /// HEVC, SPS/PPS for H.264.
    case annexBParameterSets = 1
    /// An AV1 sequence header OBU.
    case av1SequenceHeader = 2
}

/// `chroma_format_idc` as in HEVC and H.273.
public enum ChromaFormat: UInt8, Sendable, CaseIterable {
    case monochrome = 0
    case yuv420 = 1
    case yuv422 = 2
    case yuv444 = 3
}

/// Colour description as ITU-T H.273 code points, which VideoToolbox, NVENC,
/// AMF and VAAPI all map to directly. Any code point is accepted on the wire;
/// a receiver treats ones it can't render as unspecified.
public struct ColourInfo: Sendable, Hashable {
    public var primaries: UInt8
    public var transfer: UInt8
    public var matrix: UInt8
    public var fullRange: Bool

    public init(primaries: UInt8, transfer: UInt8, matrix: UInt8, fullRange: Bool) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.fullRange = fullRange
    }

    public static let bt709 = ColourInfo(primaries: 1, transfer: 1, matrix: 1, fullRange: false)
    public static let bt2020PQ = ColourInfo(primaries: 9, transfer: 16, matrix: 9, fullRange: false)
    public static let bt2020HLG = ColourInfo(primaries: 9, transfer: 18, matrix: 9, fullRange: false)
}

/// SMPTE ST 2086 mastering display colour volume, in the units and order of
/// the HEVC SEI message (green, blue, red), little-endian. 24 bytes.
public struct MasteringDisplay: Sendable, Hashable {
    public static let wireSize = 24

    /// Chromaticity coordinates in units of 0.00002.
    public var greenX, greenY, blueX, blueY, redX, redY, whiteX, whiteY: UInt16
    /// Luminance in units of 0.0001 cd/m².
    public var maxLuminance: UInt32
    public var minLuminance: UInt32

    public init(greenX: UInt16, greenY: UInt16, blueX: UInt16, blueY: UInt16, redX: UInt16, redY: UInt16,
                whiteX: UInt16, whiteY: UInt16, maxLuminance: UInt32, minLuminance: UInt32) {
        self.greenX = greenX
        self.greenY = greenY
        self.blueX = blueX
        self.blueY = blueY
        self.redX = redX
        self.redY = redY
        self.whiteX = whiteX
        self.whiteY = whiteY
        self.maxLuminance = maxLuminance
        self.minLuminance = minLuminance
    }

    /// Display P3 primaries, D65, 1000 / 0.0001 cd/m² - the common HDR10 master.
    public static let p3D65_1000 = MasteringDisplay(
        greenX: 13250, greenY: 34500, blueX: 7500, blueY: 3000, redX: 34000, redY: 16000,
        whiteX: 15635, whiteY: 16450, maxLuminance: 10_000_000, minLuminance: 1)

    func validate() throws(WireError) {
        // H.265 D.3.28: coordinates 0...50000, max luminance above min.
        for value in [greenX, greenY, blueX, blueY, redX, redY, whiteX, whiteY] where value > 50000 {
            throw .invalid("masteringDisplay.chromaticity")
        }
        guard maxLuminance > minLuminance else { throw .invalid("masteringDisplay.luminance") }
    }
}

/// HDR content light level (CTA-861.3), cd/m². 4 bytes.
public struct ContentLightLevel: Sendable, Hashable {
    public static let wireSize = 4

    public var maxContentLightLevel: UInt16
    public var maxFrameAverageLightLevel: UInt16

    public init(maxContentLightLevel: UInt16, maxFrameAverageLightLevel: UInt16) {
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
    }
}

/// What an auxiliary stream carries for its primary (section 4.2).
public enum AuxiliaryRole: UInt8, Sendable, CaseIterable {
    case alpha = 1
    case depth = 2
}

/// Present on an auxiliary stream's format: its frames pair with the primary
/// stream's frames of the same `frameNumber` and `captureTime`.
public struct AuxiliaryStream: Sendable, Hashable {
    public static let wireSize = 5

    public var role: AuxiliaryRole
    public var primaryStreamID: UInt32

    public init(role: AuxiliaryRole, primaryStreamID: UInt32) {
        self.role = role
        self.primaryStreamID = primaryStreamID
    }
}

public struct PixelSize: Sendable, Hashable {
    public var width: UInt16
    public var height: UInt16

    public init(width: UInt16, height: UInt16) {
        self.width = width
        self.height = height
    }

    var isNonZero: Bool { width > 0 && height > 0 }
}

/// How the eyes share a PCVR picture.
public enum StereoLayout: UInt8, Sendable, CaseIterable {
    /// Left eye in the left half, right eye in the right half, no gap.
    case sideBySide = 1
}

/// Shape of the axis-aligned foveation warp: a full-resolution centre
/// rectangle and compressed edges, the scheme ALVR's foveated encoding uses.
/// The per-frame centre comes from `FoveationSideData`.
public struct CentreEdgeWarp: Sendable, Hashable {
    public static let wireSize = 16

    /// Fraction of the render width and height kept at full density, (0, 1].
    public var centreSizeX: Float
    public var centreSizeY: Float
    /// How much the edges are compressed, >= 1 (1 = not at all).
    public var edgeRatioX: Float
    public var edgeRatioY: Float

    public init(centreSizeX: Float, centreSizeY: Float, edgeRatioX: Float, edgeRatioY: Float) {
        self.centreSizeX = centreSizeX
        self.centreSizeY = centreSizeY
        self.edgeRatioX = edgeRatioX
        self.edgeRatioY = edgeRatioY
    }

    func validate() throws(WireError) {
        for size in [centreSizeX, centreSizeY] where !(size > 0 && size <= 1) {
            throw .invalid("foveation.centreSize")
        }
        for ratio in [edgeRatioX, edgeRatioY] where !(ratio.isFinite && ratio >= 1) {
            throw .invalid("foveation.edgeRatio")
        }
    }
}

public enum FoveationWarp: Sendable, Hashable {
    /// Render size equals wire size; nothing to unwarp.
    case none
    case centreEdge(CentreEdgeWarp)

    var kind: UInt8 {
        switch self {
        case .none: 0
        case .centreEdge: 1
        }
    }
}

/// The foveation parameter block shared by the host's warp and the headset's
/// unwarp. Any change bumps `epoch`; every frame's `FoveationSideData` names
/// the epoch it was warped with.
public struct FoveationParameters: Sendable, Hashable {
    public var epoch: UInt32
    public var warp: FoveationWarp

    public init(epoch: UInt32, warp: FoveationWarp) {
        self.epoch = epoch
        self.warp = warp
    }
}

/// The PCVR profile's layout block (section 4.7).
public struct PCVRLayout: Sendable, Hashable {
    public var layout: StereoLayout
    /// Per eye, as the game rendered it (before the warp).
    public var renderSize: PixelSize
    /// Per eye, as encoded (after the warp).
    public var wireSize: PixelSize
    public var foveation: FoveationParameters

    public init(layout: StereoLayout, renderSize: PixelSize, wireSize: PixelSize, foveation: FoveationParameters) {
        self.layout = layout
        self.renderSize = renderSize
        self.wireSize = wireSize
        self.foveation = foveation
    }
}

public enum DepthEncodingKind: UInt8, Sendable, CaseIterable {
    /// Luma `v = round((1/z - 1/far) / (1/near - 1/far) * (2^valueBits - 1))`,
    /// full range, with near and far from the frame's `DepthRange`: near maps
    /// to the maximum, far (or infinity) to 0.
    case inverseLinear = 1
}

/// How a depth auxiliary stream's luma encodes depth (section 4.8).
public struct DepthEncoding: Sendable, Hashable {
    public static let wireSize = 2

    public var kind: DepthEncodingKind
    /// Significant bits of each luma sample, at most the stream's bit depth.
    public var valueBits: UInt8

    public init(kind: DepthEncodingKind, valueBits: UInt8) {
        self.kind = kind
        self.valueBits = valueBits
    }
}

/// One stream's format, sent reliably on channel 0 before its first frame and
/// again on every change. It applies from `firstFrameNumber` on, so a shard
/// that overtakes it is never decoded against the wrong parameter sets.
///
/// Wire: a 22-byte core, the configuration blob, then extension blocks
/// (`type u8 | length u16 | body`, each type at most once, unknown types
/// skipped, known bodies longer than defined accepted with the extra ignored).
///
/// ```
///  0  u32  streamID
///  4  u32  firstFrameNumber
///  8  u8   codec              VideoCodec
///  9  u8   formatKind         FormatKind
/// 10  u16  width              displayed (cropped) picture size, pixels
/// 12  u16  height
/// 14  u8   bitDepth           8...16
/// 15  u8   chromaFormat       ChromaFormat
/// 16  u8   colourPrimaries    H.273
/// 17  u8   transfer           H.273
/// 18  u8   matrix             H.273
/// 19  u8   fullRange          0 or 1
/// 20  u16  configurationLength (>= 1)
/// 22  ...  configuration
///  .  ...  extensions:  1 masteringDisplay  2 contentLightLevel  3 sideDataTypes
///                       4 auxiliary         5 pcvr               6 depthEncoding
/// ```
public struct FormatDescription: WireCodable, Hashable {
    enum Extension: UInt8 {
        case masteringDisplay = 1
        case contentLightLevel = 2
        case sideDataTypes = 3
        case auxiliary = 4
        case pcvr = 5
        case depthEncoding = 6
    }

    public static let coreSize = 22

    public var streamID: UInt32
    public var firstFrameNumber: UInt32
    public var codec: VideoCodec
    public var formatKind: FormatKind
    public var size: PixelSize
    public var bitDepth: UInt8
    public var chromaFormat: ChromaFormat
    public var colour: ColourInfo
    public var configuration: [UInt8]
    public var masteringDisplay: MasteringDisplay?
    public var contentLightLevel: ContentLightLevel?
    /// Side data item types this stream's frames may carry. Empty: none.
    public var sideDataTypes: Set<SideDataType>
    public var auxiliary: AuxiliaryStream?
    public var pcvr: PCVRLayout?
    public var depthEncoding: DepthEncoding?

    public init(streamID: UInt32, firstFrameNumber: UInt32, codec: VideoCodec, formatKind: FormatKind,
                size: PixelSize, bitDepth: UInt8, chromaFormat: ChromaFormat, colour: ColourInfo,
                configuration: [UInt8], masteringDisplay: MasteringDisplay? = nil,
                contentLightLevel: ContentLightLevel? = nil, sideDataTypes: Set<SideDataType> = [],
                auxiliary: AuxiliaryStream? = nil, pcvr: PCVRLayout? = nil, depthEncoding: DepthEncoding? = nil) {
        self.streamID = streamID
        self.firstFrameNumber = firstFrameNumber
        self.codec = codec
        self.formatKind = formatKind
        self.size = size
        self.bitDepth = bitDepth
        self.chromaFormat = chromaFormat
        self.colour = colour
        self.configuration = configuration
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
        self.sideDataTypes = sideDataTypes
        self.auxiliary = auxiliary
        self.pcvr = pcvr
        self.depthEncoding = depthEncoding
    }

    // MARK: Validation

    public func validate() throws(WireError) {
        guard size.isNonZero else { throw .invalid("format.size") }
        guard (8...16).contains(bitDepth) else { throw .invalid("format.bitDepth") }
        guard !configuration.isEmpty else { throw .missing("format.configuration") }
        guard configuration.count <= Int(UInt16.max) else { throw .tooLarge("format.configuration") }
        switch (formatKind, codec) {
        case (.coreMediaImageDescription, _), (.annexBParameterSets, .hevc), (.annexBParameterSets, .h264),
             (.av1SequenceHeader, .av1):
            break
        default:
            throw .inconsistent("format.formatKind")
        }
        try masteringDisplay?.validate()

        if let auxiliary {
            guard auxiliary.primaryStreamID != streamID else { throw .inconsistent("format.auxiliary.primaryStreamID") }
            guard pcvr == nil else { throw .inconsistent("format.pcvr") }
        }
        let isDepth = auxiliary?.role == .depth
        guard isDepth == (depthEncoding != nil) else { throw .inconsistent("format.depthEncoding") }
        if let depthEncoding {
            guard depthEncoding.valueBits >= 1, depthEncoding.valueBits <= bitDepth else {
                throw .invalid("format.depthEncoding.valueBits")
            }
            guard sideDataTypes.contains(.depthRange) else { throw .missing("format.sideDataTypes.depthRange") }
        }
        if let pcvr {
            try validate(pcvr)
        }
    }

    private func validate(_ pcvr: PCVRLayout) throws(WireError) {
        guard pcvr.renderSize.isNonZero, pcvr.wireSize.isNonZero else { throw .invalid("format.pcvr.size") }
        switch pcvr.layout {
        case .sideBySide:
            guard Int(size.width) == 2 * Int(pcvr.wireSize.width), size.height == pcvr.wireSize.height else {
                throw .inconsistent("format.pcvr.wireSize")
            }
        }
        guard sideDataTypes.contains(.renderPose) else { throw .missing("format.sideDataTypes.renderPose") }
        switch pcvr.foveation.warp {
        case .none:
            guard pcvr.renderSize == pcvr.wireSize else { throw .inconsistent("format.pcvr.renderSize") }
        case .centreEdge(let warp):
            try warp.validate()
            guard sideDataTypes.contains(.foveation) else { throw .missing("format.sideDataTypes.foveation") }
        }
    }

    /// Checks one frame's side data against this format: every item must be
    /// declared, PCVR frames need a render pose (and a foveation item with the
    /// current epoch when warped), depth frames need a depth range.
    public func validate(frameSideData sideData: SideData) throws(WireError) {
        guard sideData.presentTypes.isSubset(of: sideDataTypes) else { throw .inconsistent("sideData.undeclared") }
        if let pcvr {
            guard sideData.renderPose != nil else { throw .missing("sideData.renderPose") }
            if case .centreEdge = pcvr.foveation.warp {
                guard let foveation = sideData.foveation else { throw .missing("sideData.foveation") }
                guard foveation.parameterEpoch == pcvr.foveation.epoch else {
                    throw .inconsistent("sideData.foveation.parameterEpoch")
                }
            }
        }
        if depthEncoding != nil, sideData.depthRange == nil { throw .missing("sideData.depthRange") }
    }

    // MARK: Decoding

    public init(from reader: inout WireReader) throws(WireError) {
        streamID = try reader.readUInt32()
        firstFrameNumber = try reader.readUInt32()
        guard let codec = VideoCodec(rawValue: try reader.readUInt8()) else { throw .invalid("format.codec") }
        self.codec = codec
        guard let kind = FormatKind(rawValue: try reader.readUInt8()) else { throw .invalid("format.formatKind") }
        formatKind = kind
        size = PixelSize(width: try reader.readUInt16(), height: try reader.readUInt16())
        bitDepth = try reader.readUInt8()
        guard let chroma = ChromaFormat(rawValue: try reader.readUInt8()) else { throw .invalid("format.chromaFormat") }
        chromaFormat = chroma
        colour = ColourInfo(primaries: try reader.readUInt8(), transfer: try reader.readUInt8(),
                            matrix: try reader.readUInt8(), fullRange: try reader.readBool("format.fullRange"))
        let configurationLength = Int(try reader.readUInt16())
        configuration = Array(try reader.readBytes(configurationLength))
        sideDataTypes = []

        var seen: Set<UInt8> = []
        while !reader.isAtEnd {
            let rawType = try reader.readUInt8()
            var body = try reader.subReader(Int(try reader.readUInt16()))
            guard let type = Extension(rawValue: rawType) else { continue } // unknown: skipped
            guard seen.insert(rawType).inserted else { throw .duplicate("format.extension(\(rawType))") }
            switch type {
            case .masteringDisplay:
                masteringDisplay = MasteringDisplay(
                    greenX: try body.readUInt16(), greenY: try body.readUInt16(),
                    blueX: try body.readUInt16(), blueY: try body.readUInt16(),
                    redX: try body.readUInt16(), redY: try body.readUInt16(),
                    whiteX: try body.readUInt16(), whiteY: try body.readUInt16(),
                    maxLuminance: try body.readUInt32(), minLuminance: try body.readUInt32())
            case .contentLightLevel:
                contentLightLevel = ContentLightLevel(maxContentLightLevel: try body.readUInt16(),
                                                      maxFrameAverageLightLevel: try body.readUInt16())
            case .sideDataTypes:
                sideDataTypes = try Self.decodeSideDataTypes(&body)
            case .auxiliary:
                guard let role = AuxiliaryRole(rawValue: try body.readUInt8()) else { throw .invalid("format.auxiliary.role") }
                auxiliary = AuxiliaryStream(role: role, primaryStreamID: try body.readUInt32())
            case .pcvr:
                pcvr = try Self.decodePCVR(&body)
            case .depthEncoding:
                guard let kind = DepthEncodingKind(rawValue: try body.readUInt8()) else {
                    throw .invalid("format.depthEncoding.kind")
                }
                depthEncoding = DepthEncoding(kind: kind, valueBits: try body.readUInt8())
            }
        }
        try validate()
    }

    /// Strictly ascending type bytes, at least one (an empty declaration is
    /// written as no block at all).
    private static func decodeSideDataTypes(_ body: inout WireReader) throws(WireError) -> Set<SideDataType> {
        guard !body.isAtEnd else { throw .invalid("format.sideDataTypes") }
        var types: Set<SideDataType> = []
        var previous: UInt8?
        while !body.isAtEnd {
            let raw = try body.readUInt8()
            if let previous, raw <= previous { throw .invalid("format.sideDataTypes.order") }
            previous = raw
            types.insert(SideDataType(rawValue: raw))
        }
        return types
    }

    private static func decodePCVR(_ body: inout WireReader) throws(WireError) -> PCVRLayout {
        guard let layout = StereoLayout(rawValue: try body.readUInt8()) else { throw .invalid("format.pcvr.layout") }
        let renderSize = PixelSize(width: try body.readUInt16(), height: try body.readUInt16())
        let wireSize = PixelSize(width: try body.readUInt16(), height: try body.readUInt16())
        let epoch = try body.readUInt32()
        let warp: FoveationWarp
        switch try body.readUInt8() {
        case 0:
            warp = .none
        case 1:
            warp = .centreEdge(CentreEdgeWarp(centreSizeX: try body.readFloat32(), centreSizeY: try body.readFloat32(),
                                              edgeRatioX: try body.readFloat32(), edgeRatioY: try body.readFloat32()))
        default:
            // A warp the receiver can't invert makes the stream undrawable.
            throw .invalid("format.pcvr.warpKind")
        }
        return PCVRLayout(layout: layout, renderSize: renderSize, wireSize: wireSize,
                          foveation: FoveationParameters(epoch: epoch, warp: warp))
    }

    // MARK: Encoding

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt32(streamID)
        writer.writeUInt32(firstFrameNumber)
        writer.writeUInt8(codec.rawValue)
        writer.writeUInt8(formatKind.rawValue)
        writer.writeUInt16(size.width)
        writer.writeUInt16(size.height)
        writer.writeUInt8(bitDepth)
        writer.writeUInt8(chromaFormat.rawValue)
        writer.writeUInt8(colour.primaries)
        writer.writeUInt8(colour.transfer)
        writer.writeUInt8(colour.matrix)
        writer.writeBool(colour.fullRange)
        try writer.writeLengthPrefixed16(configuration, field: "format.configuration")

        if let m = masteringDisplay {
            writeExtension(.masteringDisplay, to: &writer) { w in
                for value in [m.greenX, m.greenY, m.blueX, m.blueY, m.redX, m.redY, m.whiteX, m.whiteY] {
                    w.writeUInt16(value)
                }
                w.writeUInt32(m.maxLuminance)
                w.writeUInt32(m.minLuminance)
            }
        }
        if let c = contentLightLevel {
            writeExtension(.contentLightLevel, to: &writer) { w in
                w.writeUInt16(c.maxContentLightLevel)
                w.writeUInt16(c.maxFrameAverageLightLevel)
            }
        }
        if !sideDataTypes.isEmpty {
            writeExtension(.sideDataTypes, to: &writer) { w in
                for type in sideDataTypes.sorted() { w.writeUInt8(type.rawValue) }
            }
        }
        if let a = auxiliary {
            writeExtension(.auxiliary, to: &writer) { w in
                w.writeUInt8(a.role.rawValue)
                w.writeUInt32(a.primaryStreamID)
            }
        }
        if let p = pcvr {
            writeExtension(.pcvr, to: &writer) { w in
                w.writeUInt8(p.layout.rawValue)
                w.writeUInt16(p.renderSize.width)
                w.writeUInt16(p.renderSize.height)
                w.writeUInt16(p.wireSize.width)
                w.writeUInt16(p.wireSize.height)
                w.writeUInt32(p.foveation.epoch)
                w.writeUInt8(p.foveation.warp.kind)
                if case .centreEdge(let warp) = p.foveation.warp {
                    w.writeFloat32(warp.centreSizeX)
                    w.writeFloat32(warp.centreSizeY)
                    w.writeFloat32(warp.edgeRatioX)
                    w.writeFloat32(warp.edgeRatioY)
                }
            }
        }
        if let d = depthEncoding {
            writeExtension(.depthEncoding, to: &writer) { w in
                w.writeUInt8(d.kind.rawValue)
                w.writeUInt8(d.valueBits)
            }
        }
    }

    /// Every extension body here is far below 64 KB (the side data type list
    /// is at most 256 bytes), so the u16 length can't overflow.
    private func writeExtension(_ type: Extension, to writer: inout WireWriter, _ body: (inout WireWriter) -> Void) {
        writer.writeUInt8(type.rawValue)
        let lengthOffset = writer.count
        writer.writeUInt16(0)
        body(&writer)
        writer.patchUInt16(UInt16(writer.count - lengthOffset - 2), at: lengthOffset)
    }

    /// Encodes as a complete control message (`type | length | body`).
    public func encodedMessage() throws(WireError) -> [UInt8] {
        try MessageFraming.encode(.formatDescription, body: try encoded())
    }
}
