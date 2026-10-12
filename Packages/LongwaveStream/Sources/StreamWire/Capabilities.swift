/// A v3 feature negotiated in the handshake (section 4.6). The raw value is
/// the capability's bit number; append-only.
public struct Capability: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let windowStreams = Capability(rawValue: 0)
    public static let alphaVideo = Capability(rawValue: 1)
    public static let hevc422 = Capability(rawValue: 2)
    public static let hevc10bitHDR = Capability(rawValue: 3)
    public static let av1 = Capability(rawValue: 4)
    public static let h264 = Capability(rawValue: 5)
    public static let ltrRecovery = Capability(rawValue: 6)
    public static let rfiRecovery = Capability(rawValue: 7)
    public static let nack = Capability(rawValue: 8)
    public static let audioOpus = Capability(rawValue: 9)
    public static let audioPCM24 = Capability(rawValue: 10)
    public static let audioMultichannel = Capability(rawValue: 11)
    public static let spatialObjects = Capability(rawValue: 12)
    public static let gamepad = Capability(rawValue: 13)
    public static let relativePointer = Capability(rawValue: 14)
    public static let clipboard = Capability(rawValue: 15)
    public static let virtualDisplay = Capability(rawValue: 16)
    public static let localCursor = Capability(rawValue: 17)
    public static let sideData = Capability(rawValue: 18)
    public static let depthVideo = Capability(rawValue: 19)
    public static let pcvr = Capability(rawValue: 20)
    public static let gaze = Capability(rawValue: 21)

    /// Every capability this build implements the wire side of.
    public static let known: [Capability] = (0...21).map { Capability(rawValue: $0) }

    /// Capabilities that are meaningless without others. Negotiation drops a
    /// capability whose requirements didn't survive.
    public static let requirements: [Capability: [Capability]] = [
        .depthVideo: [.sideData],
        .pcvr: [.sideData],
        .gaze: [.pcvr],
    ]

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        let names = ["windowStreams", "alphaVideo", "hevc422", "hevc10bitHDR", "av1", "h264", "ltrRecovery",
                     "rfiRecovery", "nack", "audioOpus", "audioPCM24", "audioMultichannel", "spatialObjects",
                     "gamepad", "relativePointer", "clipboard", "virtualDisplay", "localCursor", "sideData",
                     "depthVideo", "pcvr", "gaze"]
        return Int(rawValue) < names.count ? names[Int(rawValue)] : "capability(\(rawValue))"
    }
}

/// A set of capabilities, on the wire as `byteCount u8 | bitmap`: bit n of
/// byte n / 8 is capability n. We write the shortest bitmap (no trailing zero
/// bytes); a decoder accepts trailing zero bytes and keeps unknown bits, which
/// negotiation then drops, so an unknown capability is ignored, never fatal.
public struct CapabilitySet: WireCodable, Hashable, Sequence {
    public static let maxBytes = 32 // 256 capabilities

    private var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

    public init() {}

    public init(_ capabilities: some Sequence<Capability>) {
        for capability in capabilities { insert(capability) }
    }

    public static let known = CapabilitySet(Capability.known)

    private func word(_ index: Int) -> UInt64 {
        switch index {
        case 0: words.0
        case 1: words.1
        case 2: words.2
        default: words.3
        }
    }

    private mutating func setWord(_ index: Int, _ value: UInt64) {
        switch index {
        case 0: words.0 = value
        case 1: words.1 = value
        case 2: words.2 = value
        default: words.3 = value
        }
    }

    public func contains(_ capability: Capability) -> Bool {
        let bit = Int(capability.rawValue)
        return word(bit / 64) & (1 << UInt64(bit % 64)) != 0
    }

    public mutating func insert(_ capability: Capability) {
        let bit = Int(capability.rawValue)
        setWord(bit / 64, word(bit / 64) | 1 << UInt64(bit % 64))
    }

    public mutating func remove(_ capability: Capability) {
        let bit = Int(capability.rawValue)
        setWord(bit / 64, word(bit / 64) & ~(1 << UInt64(bit % 64)))
    }

    public func intersection(_ other: CapabilitySet) -> CapabilitySet {
        var result = CapabilitySet()
        for index in 0..<4 { result.setWord(index, word(index) & other.word(index)) }
        return result
    }

    public var isEmpty: Bool { (0..<4).allSatisfy { word($0) == 0 } }

    public func makeIterator() -> IndexingIterator<[Capability]> {
        (0...255).compactMap { bit -> Capability? in
            let capability = Capability(rawValue: UInt8(bit))
            return contains(capability) ? capability : nil
        }.makeIterator()
    }

    /// What a session runs with: the capabilities both sides listed that this
    /// build knows, minus any whose requirements aren't all present.
    public static func negotiated(_ a: CapabilitySet, _ b: CapabilitySet) -> CapabilitySet {
        var result = a.intersection(b).intersection(.known)
        var changed = true
        while changed { // requirements can chain (gaze -> pcvr -> sideData)
            changed = false
            for (capability, required) in Capability.requirements where result.contains(capability) {
                if !required.allSatisfy(result.contains) {
                    result.remove(capability)
                    changed = true
                }
            }
        }
        return result
    }

    public static func == (a: CapabilitySet, b: CapabilitySet) -> Bool {
        (0..<4).allSatisfy { a.word($0) == b.word($0) }
    }

    public func hash(into hasher: inout Hasher) {
        for index in 0..<4 { hasher.combine(word(index)) }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        let count = Int(try reader.readUInt8())
        guard count <= Self.maxBytes else { throw .tooLarge("capabilities") }
        let bitmap = try reader.readBytes(count)
        for (offset, byte) in bitmap.enumerated() {
            let index = offset / 8
            setWord(index, word(index) | UInt64(byte) << UInt64(offset % 8 * 8))
        }
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        var bytes: [UInt8] = []
        for index in 0..<4 {
            let value = word(index)
            for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
        }
        while bytes.last == 0 { bytes.removeLast() }
        writer.writeUInt8(UInt8(bytes.count))
        writer.writeBytes(bytes)
    }
}
