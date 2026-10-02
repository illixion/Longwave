import Foundation
import Security

/// Wire protocol for streaming uncompressed system audio from the macOS
/// sender (Longwave Companion) to the visionOS receiver, plus
/// now-playing metadata (sender → receiver) and media transport commands
/// (receiver → sender) for controlling Music.app on the Mac.
///
/// Transport: TLS 1.3-PSK over TCP. The pairing token is the pre-shared key
/// (see `AudioCrypto`), so the handshake both authenticates the peer and
/// encrypts the channel — only a holder of the token can connect. Once the
/// secure channel is up the sender writes the fixed 16-byte header, followed
/// by typed, length-prefixed frames in both directions. All integers are
/// little-endian. There is no app-layer auth frame: a wrong token fails the
/// TLS handshake before any frame is exchanged.
///
/// Low-latency mode adds a parallel DTLS-PSK-over-UDP flow that carries *only*
/// PCM frames. After the TCP channel is established, the receiver opens a UDP
/// *listener* on an ephemeral port and sends a `udpHello` frame **over the TCP
/// channel** carrying that port number. The sender reads the receiver's
/// address from the TCP connection, opens an outbound DTLS connection to
/// (receiver IP, that port), and routes subsequent PCM there (one PCM frame
/// per datagram) instead of over TCP. Receiver-listens / sender-connects
/// avoids connected-UDP source filtering; DTLS's replay window plus the shared
/// PSK make spoofed/injected datagrams unforgeable. The TCP channel still
/// carries the header, metadata, artwork, and commands.
///
/// Both channels are encrypted and mutually authenticated from the token — no
/// external Tailscale/WireGuard tunnel is required.
///
/// Header layout (16 bytes):
///   0-3   magic "VVAS"
///   4     protocol version (8)
///   5     channel count
///   6     capability flags (`AudioStreamHeader.Capabilities`; 0 from
///         a sender that predates them)
///   7     reserved (0)
///   8-15  sample rate, Float64 bit pattern
///
/// Frame layout (v3):
///   0-3   body byte count (type byte + payload), UInt32
///   4     frame type (FrameType)
///   5-    payload
///
/// PCM payloads carry interleaved **signed 24-bit little-endian** samples
/// (3 bytes each) as of v6 — a 25% bandwidth cut over the old Float32 wire
/// format with no audible loss for the already-mixed [-1, 1] signal. Float ↔
/// int24 conversion lives in `PCM24`.
///
/// As of v8 every PCM payload starts with a 9-byte `PCMStamp` — the capture
/// sample index of its first frame plus a flags byte — ahead of the samples.
/// UDP can drop and reorder datagrams, and without a position on each one a
/// hole was silently spliced shut: a click, a permanently shallower cushion,
/// and nothing in any metric. The index is also what lets the receiver
/// measure jitter against the *media* clock rather than between arrivals. The receiver still feeds AVAudioEngine
/// deinterleaved Float32 (its required graph format) — the conversion happens
/// at the wire boundary on both ends.
///
/// Both apps are released together; version mismatches hard-fail at the
/// header parse (no older-version compatibility path).
nonisolated enum AudioStreamProtocol {
    static let magic: [UInt8] = Array("VVAS".utf8)
    static let version: UInt8 = 8
    static let headerSize = 16
    static let frameLengthPrefixSize = 4
    static let defaultPort: UInt16 = 4855
    /// Bytes per PCM sample on the wire: signed 24-bit, packed little-endian.
    static let bytesPerSample = 3
    /// Sanity cap for a single frame (1 MB ≈ 1.75 s of 48 kHz stereo int24)
    static let maxFrameBytes: UInt32 = 1 << 20
    /// Bytes of artwork carried by one `artwork` frame. Sized so a chunk
    /// queued ahead of PCM delays it by well under a millisecond of link
    /// time, while still delivering a typical cover in a fraction of a second.
    static let artworkChunkBytes = 8 * 1024
    /// Reassembly cap on the receiver. The sender scales artwork to a 600 px
    /// JPEG, so this is orders of magnitude of headroom — it exists only so a
    /// malformed or hostile stream can't grow the buffer without bound.
    static let maxArtworkBytes = 4 * 1024 * 1024

    /// Splits artwork bytes into `artwork` frames ready to send, in order.
    /// Empty input yields a single final empty chunk, which clears the
    /// receiver's artwork.
    static func encodeArtworkFrames(_ artwork: Data) -> [Data] {
        var frames: [Data] = []
        var offset = artwork.startIndex
        repeat {
            let end = min(
                artwork.index(offset, offsetBy: artworkChunkBytes, limitedBy: artwork.endIndex) ?? artwork.endIndex,
                artwork.endIndex
            )
            var payload = Data(capacity: 1 + (end - offset))
            payload.append(end == artwork.endIndex ? 1 : 0)
            payload.append(artwork[offset..<end])
            frames.append(encodeFrame(.artwork, payload))
            offset = end
        } while offset < artwork.endIndex
        return frames
    }

    enum FrameType: UInt8, Sendable {
        /// A `PCMStamp` followed by interleaved signed 24-bit little-endian
        /// PCM samples (sender → receiver). See `PCM24` for the packing.
        case pcm = 0x00
        /// NowPlayingInfo JSON (sender → receiver).
        case nowPlaying = 0x01
        /// One chunk of scaled JPEG artwork (sender → receiver). Payload is
        /// a 1-byte continuation flag (1 == final chunk, 0 == more follows)
        /// followed by the chunk bytes; the receiver concatenates until the
        /// final flag. The complete artwork always immediately precedes the
        /// nowPlaying frame carrying the matching artworkID.
        ///
        /// Chunked as of v7 because artwork rides the *same ordered TCP
        /// stream* as PCM: a whole ~150 KB JPEG handed to one `send` sits in
        /// front of every subsequent audio frame until it drains, which on a
        /// Wi-Fi link is comfortably longer than the receiver's jitter
        /// cushion — an audible dropout on every track change. Small chunks
        /// dribbled out between PCM frames cost ~0.6 ms of link time each.
        case artwork = 0x02
        /// MediaCommandMessage JSON (receiver → sender).
        case command = 0x03
        // 0x04 / 0x05 were the legacy plaintext auth / authFailed frames,
        // removed in v5 — TLS-PSK now authenticates at the transport layer.
        /// Low-latency UDP setup, sent by the receiver over the TCP channel
        /// once the secure channel is up (receiver → sender). Payload is the receiver's
        /// UDP listener port as a little-endian UInt16. The sender opens an
        /// outbound UDP connection to the receiver at that port and routes PCM
        /// there. Sent only over TCP — never as a datagram.
        case udpHello = 0x06
        /// Empty heartbeat sent periodically over the UDP/DTLS path
        /// (sender → receiver). Lets the receiver confirm the low-latency
        /// path is live even when no audio is playing — without it, silence
        /// produces no PCM datagrams and the receiver's grace window would
        /// wrongly fall back to TCP. Carries no payload; ignored for audio.
        case keepAlive = 0x07
        /// The headset's microphone (receiver → sender): a `MicrophonePacket`.
        /// Rides the UDP/DTLS flow when one is up — the receiver sends it
        /// back down the connection the sender opened — and TCP otherwise.
        /// Sent only to a sender whose header advertised
        /// `acceptsMicrophone`.
        case microphone = 0x08
        /// The headset stopped sending its microphone (receiver → sender,
        /// TCP, no payload), so the sender can let go of its output device
        /// at once rather than waiting out a silence timeout.
        case microphoneStopped = 0x09
    }

    /// Wraps a payload in a typed, length-prefixed frame.
    static func encodeFrame(_ type: FrameType, _ payload: Data) -> Data {
        var frame = Data(capacity: frameLengthPrefixSize + 1 + payload.count)
        var length = UInt32(1 + payload.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }

    /// Convenience for the hot audio path.
    static func encodeFrame(_ payload: Data) -> Data {
        encodeFrame(.pcm, payload)
    }

    /// Reads the frame length prefix (type byte + payload count) from the
    /// start of `data`. Returns nil if fewer than 4 bytes are available.
    static func decodeFrameLength(_ data: Data) -> UInt32? {
        guard data.count >= frameLengthPrefixSize else { return nil }
        var value: UInt32 = 0
        for i in 0..<frameLengthPrefixSize {
            value |= UInt32(data[data.startIndex + i]) << (8 * i)
        }
        return value
    }
}

// MARK: - PCM stamp

/// Position header at the front of every `pcm` payload (v8): the capture
/// sample index of the payload's first sample frame, then a flags byte.
///
/// The index comes from the Mac's IO device sample clock, so it keeps
/// advancing through everything that removes audio from the stream — a
/// datagram lost on Wi-Fi, a buffer the frame ring had to drop, a stretch of
/// suppressed silence. The receiver tells those apart: a gap flagged
/// `resumed` is the sender coming back from silence suppression and costs
/// nothing; an unflagged gap is audio that should have arrived and didn't.
nonisolated struct PCMStamp: Sendable, Equatable {
    static let size = 9

    struct Flags: OptionSet, Sendable, Equatable {
        let rawValue: UInt8
        /// First payload after the sender suppressed silence (or the first
        /// of the stream). The index gap in front of it is intentional.
        static let resumed = Flags(rawValue: 1 << 0)
    }

    var sampleIndex: UInt64
    var flags: Flags = []

    /// Writes the stamp into the first `size` bytes of `destination`, which
    /// the caller guarantees exist. Allocation-free — the sender calls this
    /// from the Core Audio realtime thread.
    func write(to destination: UnsafeMutableRawBufferPointer) {
        let index = sampleIndex
        for i in 0..<8 {
            destination[i] = UInt8(truncatingIfNeeded: index >> (8 * UInt64(i)))
        }
        destination[8] = flags.rawValue
    }

    func encoded() -> Data {
        var data = Data(count: Self.size)
        data.withUnsafeMutableBytes { write(to: $0) }
        return data
    }

    /// Parses the stamp at the front of a `pcm` payload. Nil when the payload
    /// is too short to hold one.
    init?(parsing payload: Data) {
        guard payload.count >= Self.size else { return nil }
        let base = payload.startIndex
        var index: UInt64 = 0
        for i in 0..<8 {
            index |= UInt64(payload[base + i]) << (8 * UInt64(i))
        }
        sampleIndex = index
        flags = Flags(rawValue: payload[base + 8])
    }

    init(sampleIndex: UInt64, flags: Flags = []) {
        self.sampleIndex = sampleIndex
        self.flags = flags
    }
}

// MARK: - 24-bit PCM packing

/// Signed 24-bit PCM packing used on the wire for `pcm` frames. Samples are
/// interleaved, 3 bytes each, little-endian. Both ends share this so the
/// float ↔ int24 scaling is guaranteed identical.
///
/// A normalized [-1, 1] float maps onto the full signed-24-bit range
/// [-2²³, 2²³−1]. 24 bits gives ~144 dB of dynamic range — inaudibly close
/// to the Float32 source for an already-mixed stereo signal — while shaving
/// 25% off the byte count versus 4-byte floats.
nonisolated enum PCM24 {
    static let scale: Float = 8_388_608      // 2²³
    static let inverseScale: Float = 1 / 8_388_608
    static let maxSample: Int32 = 8_388_607  // 2²³ − 1
    static let minSample: Int32 = -8_388_608 // −2²³

    /// Converts one normalized Float32 sample to its little-endian int24
    /// representation and writes it at `byteOffset`. The caller guarantees
    /// three bytes are in bounds. Allocation-free — the sender calls this
    /// from the Core Audio realtime thread, where `malloc` is forbidden.
    /// Conversion statistics gathered on the realtime thread. `peak` is what
    /// says whether the clipping matters: a mixdown touching 1.01 loses
    /// essentially nothing, while one hitting 1.4 is flattening 29% off every
    /// transient and is plainly audible. A count alone cannot tell them apart.
    struct EncodeStats {
        var clipped = 0
        var peak: Float32 = 0
    }

    @inline(__always)
    static func write(
        _ sample: Float32,
        to destination: UnsafeMutableRawBufferPointer,
        at byteOffset: Int,
        stats: inout EncodeStats
    ) {
        // A float mixdown can legitimately exceed ±1 when several loud
        // sources sum, and the wire format cannot carry that — so the clamp
        // below is hard clipping, which crackles on peaks and sounds like a
        // buffering fault while having nothing to do with buffering. Measured
        // so the two can be told apart from the log.
        let magnitude = abs(sample)
        if magnitude > stats.peak { stats.peak = magnitude }
        if magnitude > 1 { stats.clipped &+= 1 }
        var s = Int32((max(-1, min(1, sample)) * scale).rounded())
        if s > maxSample { s = maxSample } else if s < minSample { s = minSample }
        let u = UInt32(bitPattern: s)
        destination[byteOffset] = UInt8(u & 0xff)
        destination[byteOffset &+ 1] = UInt8((u >> 8) & 0xff)
        destination[byteOffset &+ 2] = UInt8((u >> 16) & 0xff)
    }

    /// Reads one little-endian int24 sample at byte offset `i` and returns it
    /// as a normalized Float32. The caller guarantees `i + 2` is in bounds.
    @inline(__always)
    static func sample(_ bytes: UnsafeBufferPointer<UInt8>, at i: Int) -> Float {
        var u = UInt32(bytes[i]) | (UInt32(bytes[i &+ 1]) << 8) | (UInt32(bytes[i &+ 2]) << 16)
        if u & 0x80_0000 != 0 { u |= 0xFF00_0000 } // sign-extend bit 23
        return Float(Int32(bitPattern: u)) * inverseScale
    }
}

// MARK: - Now Playing / Media Commands

/// Snapshot of the Mac's Music.app playback state, sent as JSON in a
/// `nowPlaying` frame on every state/track change (and replayed to newly
/// connected clients). `elapsedSeconds` is a snapshot — the receiver
/// extrapolates locally while `isPlaying`.
nonisolated struct NowPlayingInfo: Codable, Sendable, Equatable {
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var isPlaying: Bool = false
    var durationSeconds: Double? = nil
    var elapsedSeconds: Double? = nil
    /// Identity of the current artwork (Music persistent ID). The receiver
    /// pairs the preceding `artwork` frame with this id and caches it.
    var artworkID: String? = nil

    /// True when there is an actual track to show.
    var hasTrack: Bool { title != nil }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Returns nil on malformed JSON — a bad metadata frame must never
    /// kill the audio stream.
    static func decode(_ data: Data) -> NowPlayingInfo? {
        try? JSONDecoder().decode(NowPlayingInfo.self, from: data)
    }
}

/// Transport command sent by the receiver to control Music.app on the Mac.
nonisolated enum MediaCommand: String, Codable, Sendable {
    case play, pause, toggle, next, previous
}

nonisolated struct MediaCommandMessage: Codable, Sendable {
    let command: MediaCommand

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> MediaCommandMessage? {
        try? JSONDecoder().decode(MediaCommandMessage.self, from: data)
    }
}

// MARK: - Static Auth Token

/// Persistent shared secret gating the audio stream. The macOS sender
/// generates one (`generate()`); both ends derive the TLS-PSK from it (see
/// `AudioCrypto`), so it both authorizes *who* may connect and keys the
/// encryption. Delivered out-of-band via AirDrop or clipboard (`AudioTokenURL`).
nonisolated enum AudioToken {
    /// Generates a 256-bit URL-safe token (base64url, no padding).
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// x-callback-style URL the macOS sender shares (via AirDrop) so the
/// visionOS app can auto-fill the token without manual copy/paste:
///   longwave://x-callback-url/setAudioToken?token=<token>
/// Registered as a custom URL scheme in the visionOS app's Info.plist.
nonisolated enum AudioTokenURL {
    static let scheme = "longwave"
    /// The scheme this app answered to before the rename. Still accepted on the
    /// way in, so a Companion the user has not updated yet keeps working; never
    /// produced by `make`.
    static let legacyScheme = "visionvnc"
    static let host = "x-callback-url"
    static let action = "setAudioToken"

    static func accepts(scheme candidate: String?) -> Bool {
        guard let candidate = candidate?.lowercased() else { return false }
        return candidate == scheme || candidate == legacyScheme
    }

    static func make(token: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + action
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    /// Returns the token if `url` is a well-formed setAudioToken callback.
    static func parseToken(from url: URL) -> String? {
        guard accepts(scheme: url.scheme),
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == "/" + action else { return nil }
        let token = components.queryItems?.first { $0.name == "token" }?.value
        return (token?.isEmpty == false) ? token : nil
    }
}

/// Stream format negotiation header, sent once by the sender on connect.
nonisolated struct AudioStreamHeader: Sendable, Equatable {
    /// What the sender can do beyond streaming audio out, in header byte 6.
    /// A sender that predates the field sends 0 there, so an older Companion
    /// reads as offering nothing and the headset hides what it can't use.
    struct Capabilities: OptionSet, Sendable, Equatable {
        let rawValue: UInt8
        /// It plays `microphone` frames into a virtual input device that
        /// other apps on the Mac can choose as a microphone.
        static let acceptsMicrophone = Capabilities(rawValue: 1 << 0)
    }

    let sampleRate: Double
    let channelCount: Int
    let capabilities: Capabilities

    init(sampleRate: Double, channelCount: Int, capabilities: Capabilities = []) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.capabilities = capabilities
    }

    func encoded() -> Data {
        var data = Data(capacity: AudioStreamProtocol.headerSize)
        data.append(contentsOf: AudioStreamProtocol.magic)
        data.append(AudioStreamProtocol.version)
        data.append(UInt8(channelCount))
        data.append(capabilities.rawValue)
        data.append(0)
        var bits = sampleRate.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        return data
    }

    /// Parses the first 16 bytes of `data`. Returns nil on short data,
    /// bad magic, version mismatch, or nonsensical format values.
    init?(parsing data: Data) {
        guard data.count >= AudioStreamProtocol.headerSize else { return nil }
        let bytes = [UInt8](data.prefix(AudioStreamProtocol.headerSize))
        guard Array(bytes[0..<4]) == AudioStreamProtocol.magic,
              bytes[4] == AudioStreamProtocol.version else { return nil }

        let channels = Int(bytes[5])
        guard (1...8).contains(channels) else { return nil }

        var bits: UInt64 = 0
        for i in 0..<8 {
            bits |= UInt64(bytes[8 + i]) << (8 * i)
        }
        let rate = Double(bitPattern: bits)
        guard rate.isFinite, rate >= 8_000, rate <= 384_000 else { return nil }

        self.sampleRate = rate
        self.channelCount = channels
        self.capabilities = Capabilities(rawValue: bytes[6])
    }
}

// MARK: - Microphone

/// One run of the headset's microphone, as carried by a `microphone` frame:
/// a `PCMStamp`, the capture sample rate (UInt32) and channel count (UInt8),
/// then interleaved int24 samples as in `pcm` frames.
///
/// The format rides on every packet rather than being negotiated once, so a
/// lost datagram or a sender that joins mid-stream never leaves the other end
/// guessing, and a change of input route (which can change the rate) needs no
/// separate message.
nonisolated struct MicrophonePacket: Sendable, Equatable {
    static let headerSize = PCMStamp.size + 5
    /// Sample frames per packet: 5 ms at 48 kHz, which keeps a mono int24
    /// datagram well under a Wi-Fi MTU once DTLS has wrapped it.
    static let maxFramesPerPacket = 240

    var stamp: PCMStamp
    var sampleRate: Double
    var channelCount: Int
    /// Interleaved int24 samples (see `PCM24`).
    var samples: Data

    var frameCount: Int {
        samples.count / max(1, channelCount * AudioStreamProtocol.bytesPerSample)
    }

    /// The whole frame — length prefix, type and payload — ready to send.
    func encodedFrame() -> Data {
        var payload = stamp.encoded()
        var rate = UInt32(sampleRate.rounded()).littleEndian
        withUnsafeBytes(of: &rate) { payload.append(contentsOf: $0) }
        payload.append(UInt8(channelCount))
        payload.append(samples)
        return AudioStreamProtocol.encodeFrame(.microphone, payload)
    }

    /// Parses a `microphone` payload (the bytes after the type byte). Nil when
    /// it is too short or describes a format nothing could play.
    init?(parsing payload: Data) {
        guard payload.count >= Self.headerSize, let stamp = PCMStamp(parsing: payload) else { return nil }
        let base = payload.startIndex + PCMStamp.size
        var rate: UInt32 = 0
        for i in 0..<4 {
            rate |= UInt32(payload[base + i]) << (8 * UInt32(i))
        }
        let channels = Int(payload[base + 4])
        guard (8_000...192_000).contains(rate), (1...8).contains(channels) else { return nil }
        self.stamp = stamp
        self.sampleRate = Double(rate)
        self.channelCount = channels
        self.samples = payload.subdata(in: (base + 5)..<payload.endIndex)
    }

    init(stamp: PCMStamp, sampleRate: Double, channelCount: Int, samples: Data) {
        self.stamp = stamp
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
    }
}
