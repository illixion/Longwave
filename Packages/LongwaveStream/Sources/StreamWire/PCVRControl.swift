// The PCVR profile's session control (NATIVE_V3_PROTOCOL.md section 4.7,
// "Pacing" and "Presets"): what a headset tells the host about its display and
// what it wants, and what the host settled on. Plain numbers only: each
// platform's client owns its presets, because only it knows its display.

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

/// Client -> host (`pcvrPreferences`): what this headset wants the PC to do,
/// in plain numbers the client worked out for itself. Presets, densities and
/// which rates make an even cadence belong to each platform's client (it knows
/// its display); the host only obeys. Sent after the hello and on every change;
/// the host applies it as soon as it can (a render size change restarts the
/// game's swapchain, so it may wait for the next title).
///
/// Body: `renderEye PixelSize (4) | maxStreamMillihertz u32 | minStreamMillihertz u32` (12).
public struct PCVRPreferences: WireCodable, Hashable {
    public static let wireSize = 12

    /// The size to render each eye at; 0x0 = the PC chooses.
    public var renderEye: PixelSize
    /// The stream's rate cap; 0 = follow the display.
    public var maxStreamMillihertz: UInt32
    /// The slowest stream the host may step down to when it can't keep up; 0 = no floor.
    public var minStreamMillihertz: UInt32

    public init(renderEye: PixelSize, maxStreamMillihertz: UInt32, minStreamMillihertz: UInt32) {
        self.renderEye = renderEye
        self.maxStreamMillihertz = maxStreamMillihertz
        self.minStreamMillihertz = minStreamMillihertz
    }

    public var asksForRenderEye: Bool { renderEye.width > 0 && renderEye.height > 0 }

    public init(from reader: inout WireReader) throws(WireError) {
        renderEye = PixelSize(width: try reader.readUInt16(), height: try reader.readUInt16())
        maxStreamMillihertz = try reader.readUInt32()
        minStreamMillihertz = try reader.readUInt32()
        try validate()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt16(renderEye.width)
        writer.writeUInt16(renderEye.height)
        writer.writeUInt32(maxStreamMillihertz)
        writer.writeUInt32(minStreamMillihertz)
    }

    private func validate() throws(WireError) {
        if asksForRenderEye {
            guard (256...8192).contains(renderEye.width), (256...8192).contains(renderEye.height),
                  renderEye.width % 2 == 0, renderEye.height % 2 == 0 else { throw .invalid("pcvrPreferences.renderEye") }
        } else if renderEye.width != 0 || renderEye.height != 0 {
            throw .invalid("pcvrPreferences.renderEye")
        }
        if maxStreamMillihertz != 0, minStreamMillihertz > maxStreamMillihertz {
            throw .inconsistent("pcvrPreferences.minStream")
        }
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
