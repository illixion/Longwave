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
///   4     protocol version (6)
///   5     channel count
///   6-7   reserved (0)
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
/// int24 conversion lives in `PCM24`. The receiver still feeds AVAudioEngine
/// deinterleaved Float32 (its required graph format) — the conversion happens
/// at the wire boundary on both ends.
///
/// Both apps are released together; version mismatches hard-fail at the
/// header parse (no older-version compatibility path).
nonisolated enum AudioStreamProtocol {
    static let magic: [UInt8] = Array("VVAS".utf8)
    static let version: UInt8 = 6
    static let headerSize = 16
    static let frameLengthPrefixSize = 4
    static let defaultPort: UInt16 = 4855
    /// Bytes per PCM sample on the wire: signed 24-bit, packed little-endian.
    static let bytesPerSample = 3
    /// Sanity cap for a single frame (1 MB ≈ 1.75 s of 48 kHz stereo int24)
    static let maxFrameBytes: UInt32 = 1 << 20

    enum FrameType: UInt8, Sendable {
        /// Interleaved signed 24-bit little-endian PCM samples (sender →
        /// receiver). See `PCM24` for the packing.
        case pcm = 0x00
        /// NowPlayingInfo JSON (sender → receiver).
        case nowPlaying = 0x01
        /// Scaled JPEG artwork bytes; always immediately precedes the
        /// nowPlaying frame carrying the matching artworkID (sender → receiver).
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

    /// Packs interleaved normalized Float32 samples into little-endian int24.
    /// Runs on a realtime audio thread on the sender — allocation-light.
    static func encode(_ floats: UnsafeBufferPointer<Float32>) -> Data {
        var out = Data(count: floats.count * 3)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self)
            var j = 0
            for f in floats {
                var s = Int32((max(-1, min(1, f)) * scale).rounded())
                if s > maxSample { s = maxSample } else if s < minSample { s = minSample }
                let u = UInt32(bitPattern: s)
                dst[j] = UInt8(u & 0xff)
                dst[j &+ 1] = UInt8((u >> 8) & 0xff)
                dst[j &+ 2] = UInt8((u >> 16) & 0xff)
                j &+= 3
            }
        }
        return out
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
    let sampleRate: Double
    let channelCount: Int

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    func encoded() -> Data {
        var data = Data(capacity: AudioStreamProtocol.headerSize)
        data.append(contentsOf: AudioStreamProtocol.magic)
        data.append(AudioStreamProtocol.version)
        data.append(UInt8(channelCount))
        data.append(contentsOf: [0, 0])
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
    }
}
