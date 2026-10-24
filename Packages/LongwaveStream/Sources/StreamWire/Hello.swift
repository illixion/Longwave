// The handshake payloads (sections 3 and 4.6): what v2's JSON `Hello` and
// `HelloAck` carried, binary, sealed inside Noise messages 1 and 2. Each is a
// fixed core and then items (`type u8 | length u16 | value`, as side data),
// so a later field is a new item an older peer skips. At their largest both
// are under 200 bytes, far inside the handshake's 1,137 and 1,142.

/// What a peer runs on. Drives copy and expectations; capabilities, not the
/// platform, gate behaviour. Open: an unknown value decodes and is kept.
public struct DevicePlatform: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let unspecified = DevicePlatform(rawValue: 0)
    public static let visionOS = DevicePlatform(rawValue: 1)
    public static let iOS = DevicePlatform(rawValue: 2)
    public static let macOS = DevicePlatform(rawValue: 3)
    public static let watchOS = DevicePlatform(rawValue: 4)
    public static let windows = DevicePlatform(rawValue: 5)
    public static let linux = DevicePlatform(rawValue: 6)
    public static let android = DevicePlatform(rawValue: 7)

    public var description: String {
        let names = ["unspecified", "visionOS", "iOS", "macOS", "watchOS", "windows", "linux", "android"]
        return Int(rawValue) < names.count ? names[Int(rawValue)] : "platform(\(rawValue))"
    }
}

/// How the host reads `keyDown`/`keyUp` key codes (v2's `KeyCodeSpace`).
public enum KeyCodeSpace: UInt8, Sendable, Hashable, CaseIterable {
    /// macOS virtual key codes (`kVK_*`).
    case macVirtual = 0
    /// USB HID keyboard usage IDs (page 7), for every non-Mac host.
    case hidUsage = 1
}

/// What the client wants from the session at the start. Unknown bits are a
/// later client's wishes: kept, and ignored by a host that doesn't know them.
public struct SessionIntent: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The desktop stream (v2's `wantsScreen`): without it the host doesn't
    /// start capture, for a session that's audio-only from the start.
    public static let screen = SessionIntent(rawValue: 1 << 0)
    public static let audio = SessionIntent(rawValue: 1 << 1)
    /// JPEG stills of a viewport instead of video (a watch, v2's `stillsOnly`).
    public static let stillsOnly = SessionIntent(rawValue: 1 << 2)
}

/// What this device may do on the host, bit n for the macOS Companion's
/// `CompanionGrant` case n (`screen, audio, input, projects, sshKey`).
/// Unknown bits are kept.
public struct SessionGrants: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let screen = SessionGrants(rawValue: 1 << 0)
    public static let audio = SessionGrants(rawValue: 1 << 1)
    public static let input = SessionGrants(rawValue: 1 << 2)
    public static let projects = SessionGrants(rawValue: 1 << 3)
    public static let sshKey = SessionGrants(rawValue: 1 << 4)
}

/// Shared rules for the two payloads.
public enum HelloLimits {
    static let minorVersion: UInt8 = 0
    /// RFC 9000's floor; the transport never sends less.
    public static let minUDPPayload = 1_200
    /// The IPv4 UDP maximum.
    public static let maxUDPPayload = 65_507
    public static let maxNameBytes = 64
    public static let maxSoftwareBytes = 32

    static func validateUDPPayload(_ value: Int, _ field: String) throws(WireError) {
        guard (minUDPPayload...maxUDPPayload).contains(value) else { throw .invalid(field) }
    }

    static func validateText(_ text: String, max: Int, _ field: String) throws(WireError) {
        let count = text.utf8.count
        guard count > 0 else { throw .invalid(field) }
        guard count <= max else { throw .tooLarge(field) }
    }

    /// UTF-8 that survives a decode unchanged, so a malformed sequence is
    /// rejected rather than replaced.
    static func readText(_ reader: inout WireReader, max: Int, _ field: String) throws(WireError) -> String {
        let bytes = try reader.readBytes(reader.remaining)
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.utf8.elementsEqual(bytes) else { throw .invalid(field) }
        try validateText(text, max: max, field)
        return text
    }

    static func writeItem(_ type: UInt8, _ text: String?, to writer: inout WireWriter) {
        guard let text else { return }
        writer.writeUInt8(type)
        writer.writeUInt16(UInt16(text.utf8.count))
        writer.writeBytes(text.utf8)
    }
}

/// The client's hello, in Noise message 1:
///
/// ```
///  0  u8   minor            0; capabilities, not this, gate features
///  1  ...  capabilities     CapabilitySet: what the client supports
///  .  u8   platform         DevicePlatform
///  .  u16  maxUDPPayload    largest datagram the client takes, 1200–65507
///  .  u8   intent           SessionIntent
///  .  ...  items            type u8 | length u16 | value, until the end
///             1  deviceName   UTF-8, 1–64 bytes
///             2  software     UTF-8, 1–32 bytes ("Longwave 1.4 (812)")
/// ```
public struct ClientHello: WireCodable, Hashable {
    public var minor: UInt8
    public var capabilities: CapabilitySet
    public var platform: DevicePlatform
    public var maxUDPPayload: Int
    public var intent: SessionIntent
    public var deviceName: String?
    public var software: String?

    public init(capabilities: CapabilitySet, platform: DevicePlatform, maxUDPPayload: Int = HelloLimits.minUDPPayload,
                intent: SessionIntent = [.screen, .audio], deviceName: String? = nil, software: String? = nil) {
        minor = HelloLimits.minorVersion
        self.capabilities = capabilities
        self.platform = platform
        self.maxUDPPayload = maxUDPPayload
        self.intent = intent
        self.deviceName = deviceName
        self.software = software
    }

    public func validate() throws(WireError) {
        try HelloLimits.validateUDPPayload(maxUDPPayload, "hello.maxUDPPayload")
        if let deviceName { try HelloLimits.validateText(deviceName, max: HelloLimits.maxNameBytes, "hello.deviceName") }
        if let software { try HelloLimits.validateText(software, max: HelloLimits.maxSoftwareBytes, "hello.software") }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        minor = try reader.readUInt8()
        capabilities = try CapabilitySet(from: &reader)
        platform = DevicePlatform(rawValue: try reader.readUInt8())
        maxUDPPayload = Int(try reader.readUInt16())
        intent = SessionIntent(rawValue: try reader.readUInt8())
        deviceName = nil
        software = nil
        while !reader.isAtEnd {
            let type = try reader.readUInt8()
            var value = try reader.subReader(Int(try reader.readUInt16()))
            switch type {
            case 1:
                guard deviceName == nil else { throw .duplicate("hello.deviceName") }
                deviceName = try HelloLimits.readText(&value, max: HelloLimits.maxNameBytes, "hello.deviceName")
            case 2:
                guard software == nil else { throw .duplicate("hello.software") }
                software = try HelloLimits.readText(&value, max: HelloLimits.maxSoftwareBytes, "hello.software")
            default:
                break // a later revision's item
            }
        }
        try validate()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt8(minor)
        try capabilities.encode(to: &writer)
        writer.writeUInt8(platform.rawValue)
        writer.writeUInt16(UInt16(maxUDPPayload))
        writer.writeUInt8(intent.rawValue)
        HelloLimits.writeItem(1, deviceName, to: &writer)
        HelloLimits.writeItem(2, software, to: &writer)
    }

    /// What the session runs with once `ack` arrives: the negotiated set again,
    /// so a host can't turn on something this client never offered.
    public func sessionCapabilities(from ack: HostHelloAck) -> CapabilitySet {
        .negotiated(capabilities, ack.capabilities)
    }
}

/// The host's answer, in Noise message 2:
///
/// ```
///  0  u8   minor            0
///  1  ...  capabilities     CapabilitySet: the negotiated set
///  .  u8   platform         DevicePlatform of the host
///  .  u8   keyCodeSpace     KeyCodeSpace; other values are invalid
///  .  u16  grants           SessionGrants this device holds; 0 = refused
///  .  u16  maxUDPPayload    the smaller of the two sides', 1200–65507
///  .  ...  items            as in the hello
///             1  hostName     UTF-8, 1–64 bytes
///             2  software     UTF-8, 1–32 bytes
/// ```
///
/// A host that won't serve a paired device still answers, with no grants, so
/// the client can say why instead of timing out.
public struct HostHelloAck: WireCodable, Hashable {
    public var minor: UInt8
    public var capabilities: CapabilitySet
    public var platform: DevicePlatform
    public var keyCodeSpace: KeyCodeSpace
    public var grants: SessionGrants
    public var maxUDPPayload: Int
    public var hostName: String?
    public var software: String?

    public init(capabilities: CapabilitySet, platform: DevicePlatform, keyCodeSpace: KeyCodeSpace,
                grants: SessionGrants, maxUDPPayload: Int = HelloLimits.minUDPPayload,
                hostName: String? = nil, software: String? = nil) {
        minor = HelloLimits.minorVersion
        self.capabilities = capabilities
        self.platform = platform
        self.keyCodeSpace = keyCodeSpace
        self.grants = grants
        self.maxUDPPayload = maxUDPPayload
        self.hostName = hostName
        self.software = software
    }

    /// The host's answer to `hello`: capabilities negotiated, datagram size
    /// the smaller of the two.
    public init(answering hello: ClientHello, hostCapabilities: CapabilitySet, platform: DevicePlatform,
                keyCodeSpace: KeyCodeSpace, grants: SessionGrants, maxUDPPayload: Int,
                hostName: String? = nil, software: String? = nil) {
        self.init(capabilities: .negotiated(hello.capabilities, hostCapabilities), platform: platform,
                  keyCodeSpace: keyCodeSpace, grants: grants, maxUDPPayload: min(hello.maxUDPPayload, maxUDPPayload),
                  hostName: hostName, software: software)
    }

    public var refused: Bool { grants.isEmpty }

    public func validate() throws(WireError) {
        try HelloLimits.validateUDPPayload(maxUDPPayload, "helloAck.maxUDPPayload")
        if let hostName { try HelloLimits.validateText(hostName, max: HelloLimits.maxNameBytes, "helloAck.hostName") }
        if let software { try HelloLimits.validateText(software, max: HelloLimits.maxSoftwareBytes, "helloAck.software") }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        minor = try reader.readUInt8()
        capabilities = try CapabilitySet(from: &reader)
        platform = DevicePlatform(rawValue: try reader.readUInt8())
        guard let space = KeyCodeSpace(rawValue: try reader.readUInt8()) else { throw .invalid("helloAck.keyCodeSpace") }
        keyCodeSpace = space
        grants = SessionGrants(rawValue: try reader.readUInt16())
        maxUDPPayload = Int(try reader.readUInt16())
        hostName = nil
        software = nil
        while !reader.isAtEnd {
            let type = try reader.readUInt8()
            var value = try reader.subReader(Int(try reader.readUInt16()))
            switch type {
            case 1:
                guard hostName == nil else { throw .duplicate("helloAck.hostName") }
                hostName = try HelloLimits.readText(&value, max: HelloLimits.maxNameBytes, "helloAck.hostName")
            case 2:
                guard software == nil else { throw .duplicate("helloAck.software") }
                software = try HelloLimits.readText(&value, max: HelloLimits.maxSoftwareBytes, "helloAck.software")
            default:
                break
            }
        }
        try validate()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt8(minor)
        try capabilities.encode(to: &writer)
        writer.writeUInt8(platform.rawValue)
        writer.writeUInt8(keyCodeSpace.rawValue)
        writer.writeUInt16(grants.rawValue)
        writer.writeUInt16(UInt16(maxUDPPayload))
        HelloLimits.writeItem(1, hostName, to: &writer)
        HelloLimits.writeItem(2, software, to: &writer)
    }
}
