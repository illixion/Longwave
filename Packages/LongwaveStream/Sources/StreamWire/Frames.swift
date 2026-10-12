/// Frame types inside a sealed datagram body (section 4.1). Append-only; a
/// receiver skips types it doesn't know by their length.
public enum FrameType: UInt8, Sendable, CaseIterable {
    /// The one frame without a length: a single 0x00 byte, so any run of zero
    /// bytes is valid padding of exactly that size (as in QUIC).
    case padding = 0x00
    /// Reliable ordered bytes for one channel (body defined by the transport).
    case control = 0x01
    /// Selective ACK ranges for the reliable channels (transport).
    case ack = 0x02
    /// One video shard: `VideoShardHeader` then shard data.
    case video = 0x03
    /// One audio shard: `AudioShardHeader` then the packet.
    case audio = 0x04
    /// One latest-wins snapshot (`StateSnapshot`).
    case state = 0x05
    /// Receive report for rate control (section 6.1).
    case feedback = 0x06
    /// Clock sync and liveness (section 5).
    case ping = 0x07
    case pong = 0x08

    /// Media frames never share a datagram, so FEC shard boundaries are
    /// packet boundaries.
    public var isMedia: Bool { self == .video || self == .audio }
}

/// One frame of a datagram body. `body` is a slice of the datagram.
public struct Frame: Sendable, Equatable {
    public var type: FrameType
    public var body: ArraySlice<UInt8>

    public init(type: FrameType, body: ArraySlice<UInt8>) {
        self.type = type
        self.body = body
    }
}

/// Iterates the frames of one decrypted datagram body.
///
/// Unknown frame types are skipped by length; padding bytes are swallowed.
/// Any error means the datagram is malformed and the caller
/// drops it whole: it passed AEAD, so the peer has a bug, and nothing in it is
/// trustworthy.
public struct FrameReader: Sendable {
    private var reader: WireReader
    private var sawMedia = false
    public private(set) var skippedUnknownFrames = 0

    public init(_ body: ArraySlice<UInt8>) {
        reader = WireReader(body)
    }

    public init(_ body: [UInt8]) {
        self.init(body[...])
    }

    public mutating func next() throws(WireError) -> Frame? {
        while !reader.isAtEnd {
            let rawType = try reader.readUInt8()
            if rawType == FrameType.padding.rawValue { continue } // no length field
            let length = try reader.readVarint()
            let body = try reader.readBytes(length)
            guard let type = FrameType(rawValue: rawType) else {
                skippedUnknownFrames += 1
                continue
            }
            if type.isMedia {
                guard !sawMedia else { throw .inconsistent("datagram.mediaFrames") }
                sawMedia = true
            }
            return Frame(type: type, body: body)
        }
        return nil
    }

    /// Reads every frame; convenience for tests and tools.
    public static func frames(in body: [UInt8]) throws(WireError) -> [Frame] {
        var reader = FrameReader(body)
        var frames: [Frame] = []
        while let frame = try reader.next() { frames.append(frame) }
        return frames
    }
}

extension WireWriter {
    /// Appends `type | varint length | body`. Padding has no length; use
    /// `appendPadding`.
    public mutating func appendFrame(_ type: FrameType, body: some Collection<UInt8>) throws(WireError) {
        guard type != .padding else { throw .invalid("frame.padding") }
        writeUInt8(type.rawValue)
        try writeVarint(body.count)
        writeBytes(body)
    }

    /// Appends a video frame without first copying header and shard into a
    /// temporary body.
    public mutating func appendVideoShard(_ header: VideoShardHeader, data: some Collection<UInt8>) throws(WireError) {
        writeUInt8(FrameType.video.rawValue)
        try writeVarint(VideoShardHeader.wireSize + data.count)
        try header.encode(to: &self)
        writeBytes(data)
    }

    /// Appends an audio frame (header and packet) in place.
    public mutating func appendAudioShard(_ header: AudioShardHeader, packet: some Collection<UInt8>) throws(WireError) {
        writeUInt8(FrameType.audio.rawValue)
        try writeVarint(AudioShardHeader.wireSize + packet.count)
        try header.encode(to: &self)
        writeBytes(packet)
    }

    /// Appends `count` bytes of padding (zero bytes, one padding frame each).
    public mutating func appendPadding(_ count: Int) {
        guard count > 0 else { return }
        writeBytes(repeatElement(UInt8(0), count: count))
    }
}

/// Byte budget of one datagram (sections 3 and 4.2).
///
/// The outer header and AEAD tag belong to the crypto layer; they are here so
/// the shard size the packetizer uses accounts for every byte on the wire.
public enum DatagramLayout {
    /// type/flags u8, receiver connection ID u32, packet number u64.
    public static let outerHeaderSize = 13
    /// AES-256-GCM and ChaCha20-Poly1305 both append 16 bytes.
    public static let authenticationTagSize = 16
    /// Fits Tailscale's 1280-byte MTU and the IPv6 minimum with IPv6 + UDP headers.
    public static let defaultUDPPayload = 1200
    /// Largest UDP payload a direct LAN path is probed up to.
    public static let maxProbedUDPPayload = 1452

    /// Bytes available for frames after the outer header and tag.
    public static func sealedBodyCapacity(udpPayload: Int) -> Int {
        udpPayload - outerHeaderSize - authenticationTagSize
    }

    /// Data bytes per video shard when the shard is the only frame in its
    /// datagram: UDP payload minus outer header, tag, frame type and length,
    /// and the 24-byte shard header. 1144 at the default 1200.
    public static func videoShardDataCapacity(udpPayload: Int) -> Int {
        mediaDataCapacity(udpPayload: udpPayload, headerSize: VideoShardHeader.wireSize)
    }

    /// The same for audio (16-byte header).
    public static func audioPacketCapacity(udpPayload: Int) -> Int {
        mediaDataCapacity(udpPayload: udpPayload, headerSize: AudioShardHeader.wireSize)
    }

    private static func mediaDataCapacity(udpPayload: Int, headerSize: Int) -> Int {
        let body = sealedBodyCapacity(udpPayload: udpPayload)
        var data = body - 1 - headerSize - 1
        while data > 0, 1 + Varint.encodedLength(headerSize + data) + headerSize + data > body { data -= 1 }
        return max(0, data)
    }
}
