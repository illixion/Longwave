// The PCVR profile's session control (NATIVE_V3_PROTOCOL.md section 4.7,
// "Pacing" and "Presets"): what a headset tells the host about its display and
// what it wants, and what the host settled on. Shared by every PCVR client
// (visionOS today, others later) so presets mean the same thing everywhere.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

/// Client -> host (`pcvrDisplay`): the display's refresh now, and the rates it
/// can run. Sent after the hello and again on every change, so the host paces
/// from what the headset says rather than inferring it from the pose rate.
///
/// Body: `refreshMillihertz u32 | count u8 | supported u32 * count` (5 + 4n).
public struct PCVRDisplayRate: WireCodable, Hashable {
    public static let maxSupported = 16

    /// The display's current refresh, e.g. 90000; 0 when unknown.
    public var refreshMillihertz: UInt32
    /// Rates the display can switch to, ascending; may be empty.
    public var supportedMillihertz: [UInt32]

    public init(refreshMillihertz: UInt32, supportedMillihertz: [UInt32] = []) {
        self.refreshMillihertz = refreshMillihertz
        self.supportedMillihertz = supportedMillihertz
    }

    public init(hertz: Double, supported: [Double] = []) {
        self.init(refreshMillihertz: Self.millihertz(hertz), supportedMillihertz: supported.map(Self.millihertz).sorted())
    }

    public var hertz: Double { Double(refreshMillihertz) / 1000 }

    static func millihertz(_ hertz: Double) -> UInt32 {
        guard hertz.isFinite, hertz > 0 else { return 0 }
        return UInt32(min(hertz * 1000, Double(UInt32.max)).rounded())
    }

    public init(from reader: inout WireReader) throws(WireError) {
        refreshMillihertz = try reader.readUInt32()
        let count = Int(try reader.readUInt8())
        guard count <= Self.maxSupported else { throw .invalid("pcvrDisplay.count") }
        var rates: [UInt32] = []
        for _ in 0..<count { rates.append(try reader.readUInt32()) }
        supportedMillihertz = rates
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        guard supportedMillihertz.count <= Self.maxSupported else { throw .tooLarge("pcvrDisplay.supported") }
        writer.writeUInt32(refreshMillihertz)
        writer.writeUInt8(UInt8(supportedMillihertz.count))
        for rate in supportedMillihertz { writer.writeUInt32(rate) }
    }
}

/// How much picture a PCVR game renders: a scale of the headset's native
/// density over its whole view (1.0 renders as many pixels per degree as the
/// display shows at its centre). The host derives each eye's render size from
/// it and the eye's field of view.
public enum PCVRQualityPreset: UInt8, CaseIterable, Sendable, Codable {
    case performance = 1
    case balanced = 2
    case quality = 3
    case maximum = 4

    /// Per mille of native density.
    public var renderScalePermille: UInt16 {
        switch self {
        case .performance: 700
        case .balanced: 850
        case .quality: 1000
        case .maximum: 1150
        }
    }
}

/// What a PCVR stream's frame rate follows. `matchDisplay` keeps one stream
/// frame per display refresh, stepping down when the PC can't keep up; the
/// others cap the stream (and with it the game) whatever the display runs.
public enum PCVRFrameRatePreset: UInt8, CaseIterable, Sendable, Codable {
    case matchDisplay = 0
    case cap60 = 1
    case cap72 = 2
    case cap90 = 3
    case cap120 = 4

    /// The cap in millihertz; 0 for `matchDisplay`.
    public var capMillihertz: UInt32 {
        switch self {
        case .matchDisplay: 0
        case .cap60: 60_000
        case .cap72: 72_000
        case .cap90: 90_000
        case .cap120: 120_000
        }
    }
}

/// Client -> host (`pcvrPreferences`): what the wearer chose. Sent after the
/// hello and on every change; the host applies it as soon as it can (a render
/// size change restarts the game's swapchain, so it may wait for the next
/// title). Explicit values, so a client can offer settings between presets.
///
/// Body: `renderScalePermille u16 | maxStreamMillihertz u32 | quality u8 | frameRate u8` (8).
public struct PCVRPreferences: WireCodable, Hashable {
    public static let wireSize = 8
    public static let scaleRange: ClosedRange<UInt16> = 300...1500

    /// Render density, per mille of native (`PCVRQualityPreset`).
    public var renderScalePermille: UInt16
    /// The stream's rate cap; 0 = follow the display.
    public var maxStreamMillihertz: UInt32
    /// The presets these values came from, for display on the host; 0 = custom.
    public var qualityPreset: UInt8
    public var frameRatePreset: UInt8

    public init(renderScalePermille: UInt16, maxStreamMillihertz: UInt32, qualityPreset: UInt8 = 0, frameRatePreset: UInt8 = 0) {
        self.renderScalePermille = renderScalePermille
        self.maxStreamMillihertz = maxStreamMillihertz
        self.qualityPreset = qualityPreset
        self.frameRatePreset = frameRatePreset
    }

    public init(quality: PCVRQualityPreset, frameRate: PCVRFrameRatePreset) {
        self.init(renderScalePermille: quality.renderScalePermille, maxStreamMillihertz: frameRate.capMillihertz,
                  qualityPreset: quality.rawValue, frameRatePreset: frameRate.rawValue)
    }

    public static let `default` = PCVRPreferences(quality: .quality, frameRate: .matchDisplay)

    public var quality: PCVRQualityPreset? { PCVRQualityPreset(rawValue: qualityPreset) }
    public var frameRate: PCVRFrameRatePreset? { PCVRFrameRatePreset(rawValue: frameRatePreset) }
    public var renderScale: Double { Double(renderScalePermille) / 1000 }

    public init(from reader: inout WireReader) throws(WireError) {
        renderScalePermille = try reader.readUInt16()
        maxStreamMillihertz = try reader.readUInt32()
        qualityPreset = try reader.readUInt8()
        frameRatePreset = try reader.readUInt8()
        guard Self.scaleRange.contains(renderScalePermille) else { throw .invalid("pcvrPreferences.renderScale") }
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        guard Self.scaleRange.contains(renderScalePermille) else { throw .invalid("pcvrPreferences.renderScale") }
        writer.writeUInt16(renderScalePermille)
        writer.writeUInt32(maxStreamMillihertz)
        writer.writeUInt8(qualityPreset)
        writer.writeUInt8(frameRatePreset)
    }
}

/// Host -> client (`pcvrSessionState`): what the host is doing with the
/// preferences, sent on every change. A client shows it; nothing depends on it.
///
/// Body: `renderEye PixelSize (4) | streamMillihertz u32 | producer u8 | flags u8` (10).
public struct PCVRSessionState: WireCodable, Hashable {
    public static let wireSize = 10

    public enum Producer: UInt8, Sendable {
        /// Nothing renders for the headset.
        case none = 0
        /// The VR compositor runs without a title (its home view).
        case home = 1
        /// A title renders.
        case title = 2
    }

    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// The stream rate is below the cap or display because the PC can't keep up.
        public static let rateLimitedByHost = Flags(rawValue: 1 << 0)
        /// The asked-for render size waits for the next title.
        public static let renderSizePending = Flags(rawValue: 1 << 1)
    }

    /// The size each eye is rendered at (before any foveation warp).
    public var renderEye: PixelSize
    public var streamMillihertz: UInt32
    public var producer: Producer
    public var flags: Flags

    public init(renderEye: PixelSize, streamMillihertz: UInt32, producer: Producer, flags: Flags = []) {
        self.renderEye = renderEye
        self.streamMillihertz = streamMillihertz
        self.producer = producer
        self.flags = flags
    }

    public init(from reader: inout WireReader) throws(WireError) {
        renderEye = PixelSize(width: try reader.readUInt16(), height: try reader.readUInt16())
        streamMillihertz = try reader.readUInt32()
        producer = Producer(rawValue: try reader.readUInt8()) ?? .none
        flags = Flags(rawValue: try reader.readUInt8())
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        writer.writeUInt16(renderEye.width)
        writer.writeUInt16(renderEye.height)
        writer.writeUInt32(streamMillihertz)
        writer.writeUInt8(producer.rawValue)
        writer.writeUInt8(flags.rawValue)
    }
}

public extension PCVRProfile {
    /// The render eye for `fov` at `scale` of `nativePixelsPerTangent` (pixels
    /// per unit tangent at the display centre), even and wire-aligned. The
    /// Vision Pro's is about 1860 (`visionProPixelsPerTangent`).
    static func renderEye(fov: (left: Float, right: Float, up: Float, down: Float),
                          scale: Double, nativePixelsPerTangent: Double) -> PixelSize {
        func span(_ a: Float, _ b: Float) -> Double { tan(Double(b)) - tan(Double(a)) }
        let s = max(scale, 0.1) * nativePixelsPerTangent
        func aligned(_ v: Double) -> UInt16 {
            let a = Double(wireAlignment)
            return UInt16(min(max((v / a).rounded() * a, a), 8192))
        }
        return PixelSize(width: aligned(span(fov.left, fov.right) * s), height: aligned(span(fov.down, fov.up) * s))
    }

    /// The Vision Pro's display density at its centre, pixels per unit tangent:
    /// 5184 px across its ±~54.5 deg rendered frustum with 2% overscan.
    static let visionProPixelsPerTangent = 1860.0
}
