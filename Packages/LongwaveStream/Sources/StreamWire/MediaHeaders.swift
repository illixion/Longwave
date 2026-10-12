// Shard headers for the two media frame types (sections 4.2 and 4.4).

public struct VideoShardFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// An IDR: decodable on its own; resets the reference chain.
    public static let key = VideoShardFlags(rawValue: 1 << 0)
    /// The first frame after a reference invalidation (section 6.3).
    public static let recovery = VideoShardFlags(rawValue: 1 << 1)
    /// The encoder marked this frame as a long-term reference.
    public static let longTermReference = VideoShardFlags(rawValue: 1 << 2)
    /// This shard's block is the frame's last (`block == blockCount - 1`).
    public static let lastBlock = VideoShardFlags(rawValue: 1 << 3)
    /// Nothing references this frame; a damaged one can be skipped.
    public static let discardable = VideoShardFlags(rawValue: 1 << 4)

    public static let defined: VideoShardFlags = [.key, .recovery, .longTermReference, .lastBlock, .discardable]
}

/// The 24-byte header in front of every video shard (section 4.2).
///
/// ```
///  0  u32  streamID
///  4  u32  frameNumber        per stream, wraps
///  8  u64  captureTime        host monotonic ns, same for every shard of a frame
/// 16  u8   flags              VideoShardFlags; bits 5-7 reserved (zero)
/// 17  u8   block              FEC block index within the frame
/// 18  u8   blockCount
/// 19  u8   shardIndex         within the block, data shards first
/// 20  u8   dataShards         k >= 1
/// 21  u8   parityShards       m, k + m <= 255
/// 22  u16  referenceDistance  frameNumber - reference frame; 0 = no reference
/// ```
public struct VideoShardHeader: WireCodable, Hashable {
    public static let wireSize = 24
    public static let maxShardsPerBlock = 255

    public var streamID: UInt32
    public var frameNumber: UInt32
    public var captureTime: UInt64
    public var flags: VideoShardFlags
    public var block: UInt8
    public var blockCount: UInt8
    public var shardIndex: UInt8
    public var dataShards: UInt8
    public var parityShards: UInt8
    /// How many frames back the frame this one predicts from is. 0 means it
    /// predicts from nothing (intra). A distance rather than the reference's
    /// low 16 bits, which the design first had, because a sentinel like
    /// 0xFFFF collides with a real frame number every 65,536 frames.
    public var referenceDistance: UInt16

    public init(streamID: UInt32, frameNumber: UInt32, captureTime: UInt64, flags: VideoShardFlags,
                block: UInt8, blockCount: UInt8, shardIndex: UInt8, dataShards: UInt8, parityShards: UInt8,
                referenceDistance: UInt16) {
        self.streamID = streamID
        self.frameNumber = frameNumber
        self.captureTime = captureTime
        self.flags = flags
        self.block = block
        self.blockCount = blockCount
        self.shardIndex = shardIndex
        self.dataShards = dataShards
        self.parityShards = parityShards
        self.referenceDistance = referenceDistance
    }

    public var isParity: Bool { shardIndex >= dataShards }
    public var totalShards: Int { Int(dataShards) + Int(parityShards) }
    /// The frame this one predicts from, or nil for an intra frame.
    public var referenceFrame: UInt32? {
        referenceDistance == 0 ? nil : frameNumber &- UInt32(referenceDistance)
    }

    public func validate() throws(WireError) {
        guard flags.isSubset(of: .defined) else { throw .invalid("videoShard.flags") }
        guard blockCount >= 1, block < blockCount else { throw .invalid("videoShard.block") }
        guard dataShards >= 1 else { throw .invalid("videoShard.dataShards") }
        guard totalShards <= Self.maxShardsPerBlock else { throw .tooLarge("videoShard.shards") }
        guard Int(shardIndex) < totalShards else { throw .invalid("videoShard.shardIndex") }
        guard flags.contains(.lastBlock) == (block == blockCount - 1) else {
            throw .inconsistent("videoShard.lastBlock")
        }
        if flags.contains(.key), referenceDistance != 0 { throw .inconsistent("videoShard.key") }
        if flags.contains(.discardable), flags.contains(.longTermReference) {
            throw .inconsistent("videoShard.discardable")
        }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        streamID = try reader.readUInt32()
        frameNumber = try reader.readUInt32()
        captureTime = try reader.readUInt64()
        flags = VideoShardFlags(rawValue: try reader.readUInt8())
        block = try reader.readUInt8()
        blockCount = try reader.readUInt8()
        shardIndex = try reader.readUInt8()
        dataShards = try reader.readUInt8()
        parityShards = try reader.readUInt8()
        referenceDistance = try reader.readUInt16()
        try validate()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt32(streamID)
        writer.writeUInt32(frameNumber)
        writer.writeUInt64(captureTime)
        writer.writeUInt8(flags.rawValue)
        writer.writeUInt8(block)
        writer.writeUInt8(blockCount)
        writer.writeUInt8(shardIndex)
        writer.writeUInt8(dataShards)
        writer.writeUInt8(parityShards)
        writer.writeUInt16(referenceDistance)
    }

    /// Splits a video frame body into header and shard data.
    public static func split(_ frameBody: ArraySlice<UInt8>) throws(WireError) -> (header: VideoShardHeader, data: ArraySlice<UInt8>) {
        var reader = WireReader(frameBody)
        let header = try VideoShardHeader(from: &reader)
        return (header, try reader.readBytes(reader.remaining))
    }
}

/// Audio codecs (section 4.4). Negotiated by capability, so a codec a
/// receiver doesn't know is an error rather than something to skip.
public enum AudioCodec: UInt8, Sendable, CaseIterable {
    case opus = 1
    case pcm24 = 2
}

/// The 16-byte header in front of every audio packet (section 4.4).
///
/// ```
///  0  u16  channelID     0 = the bed; 1...65535 = spatial object IDs
///  2  u8   flags         bits 0-2 fecIndex (0-3 data, 4-5 parity),
///                        bit 3 discontinuity, bit 4 inBandFEC, bits 5-7 reserved
///  3  u8   codec         AudioCodec
///  4  u64  firstSample   host audio device sample index of the first sample;
///                        for parity, that of the group's first data packet
/// 12  u16  frameSamples  samples per channel in this packet (1...5760)
/// 14  u16  fecGroup      RS group counter, wraps
/// ```
public struct AudioShardHeader: WireCodable, Hashable {
    public static let wireSize = 16
    /// Every audio FEC group is 4 data packets plus 2 parity in v3.0.
    public static let fecDataShards: UInt8 = 4
    public static let fecParityShards: UInt8 = 2
    /// 120 ms at 48 kHz, Opus's longest frame.
    public static let maxFrameSamples: UInt16 = 5760

    public var channelID: UInt16
    public var fecIndex: UInt8
    /// The host restarted its sample count or dropped audio on purpose: don't
    /// treat the jump in `firstSample` as loss.
    public var discontinuity: Bool
    /// The Opus packet carries in-band FEC (LBRR) for the previous one.
    public var inBandFEC: Bool
    public var codec: AudioCodec
    public var firstSample: UInt64
    public var frameSamples: UInt16
    public var fecGroup: UInt16

    public init(channelID: UInt16, fecIndex: UInt8, discontinuity: Bool = false, inBandFEC: Bool = false,
                codec: AudioCodec, firstSample: UInt64, frameSamples: UInt16, fecGroup: UInt16) {
        self.channelID = channelID
        self.fecIndex = fecIndex
        self.discontinuity = discontinuity
        self.inBandFEC = inBandFEC
        self.codec = codec
        self.firstSample = firstSample
        self.frameSamples = frameSamples
        self.fecGroup = fecGroup
    }

    public var isParity: Bool { fecIndex >= Self.fecDataShards }

    public func validate() throws(WireError) {
        guard fecIndex < Self.fecDataShards + Self.fecParityShards else { throw .invalid("audioShard.fecIndex") }
        guard frameSamples >= 1, frameSamples <= Self.maxFrameSamples else { throw .invalid("audioShard.frameSamples") }
        if isParity, discontinuity || inBandFEC { throw .inconsistent("audioShard.parityFlags") }
    }

    private var flagsByte: UInt8 {
        fecIndex | (discontinuity ? 1 << 3 : 0) | (inBandFEC ? 1 << 4 : 0)
    }

    public init(from reader: inout WireReader) throws(WireError) {
        channelID = try reader.readUInt16()
        let flags = try reader.readUInt8()
        guard flags & 0xE0 == 0 else { throw .invalid("audioShard.flags") }
        fecIndex = flags & 0x07
        discontinuity = flags & 0x08 != 0
        inBandFEC = flags & 0x10 != 0
        guard let codec = AudioCodec(rawValue: try reader.readUInt8()) else { throw .invalid("audioShard.codec") }
        self.codec = codec
        firstSample = try reader.readUInt64()
        frameSamples = try reader.readUInt16()
        fecGroup = try reader.readUInt16()
        try validate()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt16(channelID)
        writer.writeUInt8(flagsByte)
        writer.writeUInt8(codec.rawValue)
        writer.writeUInt64(firstSample)
        writer.writeUInt16(frameSamples)
        writer.writeUInt16(fecGroup)
    }

    /// Splits an audio frame body into header and packet.
    public static func split(_ frameBody: ArraySlice<UInt8>) throws(WireError) -> (header: AudioShardHeader, packet: ArraySlice<UInt8>) {
        var reader = WireReader(frameBody)
        let header = try AudioShardHeader(from: &reader)
        return (header, try reader.readBytes(reader.remaining))
    }
}
