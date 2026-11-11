// The client's microphone to the host (capability `microphone`): a format
// message on the control channel, then the samples as audio shards going the
// other way from the host's audio, so a PC game or voice app can hear the
// headset. A session's audio channel is the same either way; only the sender
// differs.

/// Client -> host (`microphoneFormat`): the microphone's sample rate, sent
/// before its first samples and again on any change; a rate of 0 means it
/// stopped (the host may close its playback). Mono, PCM24.
///
/// Body: `sampleRate u32 | channels u8` (5).
public struct MicrophoneFormat: WireCodable, Hashable {
    public var sampleRate: UInt32
    public var channels: UInt8

    public init(sampleRate: UInt32, channels: UInt8 = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public static let stopped = MicrophoneFormat(sampleRate: 0, channels: 0)
    public var isStopped: Bool { sampleRate == 0 }

    public init(from reader: inout WireReader) throws(WireError) {
        sampleRate = try reader.readUInt32()
        channels = try reader.readUInt8()
        guard isStopped || (8_000...192_000).contains(sampleRate) else { throw .invalid("microphoneFormat.sampleRate") }
        guard isStopped || channels == 1 else { throw .invalid("microphoneFormat.channels") }
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        writer.writeUInt32(sampleRate)
        writer.writeUInt8(channels)
    }
}

/// One microphone packet's samples: PCM24 as v3 carries it (VVAS's format,
/// unchanged: signed 24-bit little-endian, interleaved), mono. The headset's
/// `MicrophoneUplink` already captures in exactly this packing.
public enum MicrophoneAudio {
    /// 5 ms at 48 kHz: small enough to keep the voice's latency low, large
    /// enough that headers stay a small share of the datagram.
    public static let framesPerPacket = 240
    public static let bytesPerSample = 3

    /// The shard header for samples starting at `firstSample`. FEC isn't used
    /// (a lost 5 ms of voice is filled with silence): every shard is data,
    /// `fecIndex` counting 0...3 within its group so the header stays valid.
    public static func header(firstSample: UInt64, frames: Int, sequence: UInt32,
                              discontinuity: Bool) -> AudioShardHeader {
        AudioShardHeader(channelID: 0, fecIndex: UInt8(sequence % UInt32(AudioShardHeader.fecDataShards)),
                         discontinuity: discontinuity, codec: .pcm24, firstSample: firstSample,
                         frameSamples: UInt16(clamping: frames),
                         fecGroup: UInt16(truncatingIfNeeded: sequence / UInt32(AudioShardHeader.fecDataShards)))
    }

    /// Little-endian int24 to float in [-1, 1).
    public static func decode(_ bytes: some Collection<UInt8>) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(bytes.count / 3)
        var iterator = bytes.makeIterator()
        while let a = iterator.next(), let b = iterator.next(), let c = iterator.next() {
            var v = Int32(c) << 16 | Int32(b) << 8 | Int32(a)
            if v & 0x80_0000 != 0 { v -= 0x100_0000 }
            out.append(Float(v) / 8_388_608)
        }
        return out
    }

    /// Float to little-endian int24, clipped.
    public static func encode(_ samples: some Collection<Float>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(samples.count * 3)
        for sample in samples {
            let v = Int32((max(-1, min(1, sample)) * 8_388_607).rounded())
            out.append(UInt8(truncatingIfNeeded: v))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
            out.append(UInt8(truncatingIfNeeded: v >> 16))
        }
        return out
    }
}
