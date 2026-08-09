//  GameLibraryProtocol.swift
//
//  Swift half of the game-library ops on the controller-bridge data channel
//  (`CB_PACKET_LIBRARY`, 0x09 — see OpenXRLayer/protocol/controller_bridge_protocol.h).
//
//  The one request/response exchange on an otherwise one-way channel: ask the
//  Windows companion for the titles the user chose to expose, for a title's
//  cover art, and to launch one. Bodies are JSON produced by the host's
//  GameLibrary (C#) and forwarded verbatim by the OpenXR layer, so this file
//  decodes the backend's own models rather than a bespoke wire format.
//
//  Responses arrive in ≤1024-byte chunks sharing a request id; `Reassembler`
//  joins them.
//
//  The transport is the bridge's TCP control link (`BridgeControlLink`), not the
//  message channel. The channel is only the rendezvous: it hands over the host's
//  addresses and a per-connection token (`ControllerBridgeRendezvous`), because on
//  this host a channel lasts about twelve seconds and cannot carry anything
//  continuous. Chunked responses need ordered delivery — a gap fails the whole
//  response, which on UDP made a ~24-chunk cover a coin flip.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation

enum GameLibraryProtocol {
    static let packetLibrary: UInt8 = 0x09
    static let headerSize = 16
    static let maxBody = 1024
    static let tokenBytes = 32

    enum Op: UInt8 {
        case listRequest = 1
        case listResponse = 2
        case launch = 3
        case launchResult = 4
        case artRequest = 5
        case artResponse = 6
    }

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let lastChunk = Flags(rawValue: 1 << 0)
        static let error = Flags(rawValue: 1 << 1)
    }

    /// Encode one request. `body` is the params object the host passes straight
    /// through to the backend RPC (empty = no params).
    ///
    /// Nothing here authenticates: the whole packet is sealed by `BridgeSeal`
    /// before it goes out, and the host serves nothing off the UDP port that does
    /// not open. That is why the session token no longer appears on the wire.
    static func request(op: Op, requestId: UInt32, body: Data = Data()) -> Data {
        precondition(body.count <= maxBody, "library request bodies must fit one chunk")
        var d = Data(capacity: headerSize + body.count)
        d.append(packetLibrary)                        // off 0
        d.append(ControllerBridgeProtocol.version)     // off 1
        d.append(op.rawValue)                          // off 2
        d.append(0)                                    // off 3  flags (unused on requests)
        d.appendLE(requestId)                          // off 4
        d.appendLE(UInt32(0))                          // off 8  chunk_index
        d.appendLE(UInt32(body.count))                 // off 12
        d.append(body)                                 // off 16
        return d
    }

    struct Chunk {
        var op: Op
        var flags: Flags
        var requestId: UInt32
        var chunkIndex: UInt32
        var body: Data

        /// nil when the data is not a library packet at all — the same channel
        /// carries haptics and telemetry, so this is the discriminator.
        init?(_ data: Data) {
            guard data.count >= GameLibraryProtocol.headerSize else { return nil }
            let b = [UInt8](data)
            guard b[0] == GameLibraryProtocol.packetLibrary,
                  b[1] == ControllerBridgeProtocol.version,
                  let op = Op(rawValue: b[2]) else { return nil }
            let length = Int(GameLibraryProtocol.u32(b, 12))
            guard data.count >= GameLibraryProtocol.headerSize + length else { return nil }
            self.op = op
            flags = Flags(rawValue: b[3])
            requestId = GameLibraryProtocol.u32(b, 4)
            chunkIndex = GameLibraryProtocol.u32(b, 8)
            let start = data.startIndex + GameLibraryProtocol.headerSize
            body = data[start ..< (start + length)]
        }
    }

    fileprivate static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    /// Joins chunked responses. Keyed by request id, so an art fetch completing
    /// while a listing is still arriving does not corrupt either.
    ///
    /// Out-of-order chunks are treated as a failed response rather than buffered
    /// and sorted: the channel is ordered, so a gap means something is wrong, and
    /// a caller that retries recovers faster than one waiting on a hole to fill.
    struct Reassembler {
        struct Completed {
            var op: Op
            var requestId: UInt32
            var body: Data
            var isError: Bool
        }

        private struct Partial {
            var op: Op
            var body: Data
            var nextIndex: UInt32
            var isError: Bool
        }

        private var partials: [UInt32: Partial] = [:]

        /// Feeds one chunk; returns the joined response when this was its last.
        mutating func accept(_ chunk: Chunk) -> Completed? {
            var partial = partials[chunk.requestId]
                ?? Partial(op: chunk.op, body: Data(), nextIndex: 0, isError: false)
            guard chunk.chunkIndex == partial.nextIndex else {
                partials[chunk.requestId] = nil
                return nil
            }
            partial.body.append(chunk.body)
            partial.nextIndex += 1
            partial.isError = partial.isError || chunk.flags.contains(.error)

            guard chunk.flags.contains(.lastChunk) else {
                partials[chunk.requestId] = partial
                return nil
            }
            partials[chunk.requestId] = nil
            return Completed(op: partial.op, requestId: chunk.requestId,
                             body: partial.body, isError: partial.isError)
        }

        /// Drops everything in flight — used when the channel drops, so a
        /// reconnect does not resume onto a half-received body.
        mutating func reset() { partials.removeAll() }
    }
}

/// The host's rendezvous announcement (`cb_rendezvous_t`, 0x0A, 232 bytes) — the
/// only packet the message channel carries. Everything real then runs on the
/// direct link to one of `endpoints`, sealed with keys derived from `token` (see
/// BridgeSeal).
///
/// The ports are the host's ACTUAL bind results, not the protocol constants: when
/// a fixed port is taken by unrelated software the host binds an ephemeral one and
/// announces it here, so the client must always use these.
///
/// The token is key material, not a credential to present: it never leaves the
/// device. Receiving it over the message channel is only safe because that channel
/// is CloudXR's own encrypted session.
struct ControllerBridgeRendezvous: Equatable {
    var token: Data
    var inputPort: UInt16
    var libraryPort: UInt16
    /// TCP control stream port. Hosts older than the field announce a 224-byte
    /// packet; the constant fills in for them.
    var controlPort: UInt16
    /// Whether the process that minted this also owns the input port, and can
    /// therefore open sealed input. When false the client refuses to stream input
    /// at all (sealing into a process without the key would drop every packet
    /// silently, and plaintext input is not something to put on a LAN).
    var sealsInput: Bool
    /// Every local IPv4 the host has, LAN first then tailnet. The host cannot know
    /// which one this headset can reach, so the client probes them in order.
    var endpoints: [String]

    static let packetType: UInt8 = 0x0A
    static let size = 224           // minimum (pre-control_port hosts)
    static let sizeWithControlPort = 226
    private static let flagSealedInput: UInt8 = 1 << 1
    private static let maxEndpoints = 4
    private static let addrLen = 46

    init?(_ data: Data) {
        guard data.count >= Self.size else { return nil }
        let b = [UInt8](data)
        guard b[0] == Self.packetType, b[1] == ControllerBridgeProtocol.version else { return nil }

        let count = min(Int(b[2]), Self.maxEndpoints)
        sealsInput = (b[3] & Self.flagSealedInput) != 0
        inputPort = UInt16(b[4]) | (UInt16(b[5]) << 8)
        libraryPort = UInt16(b[6]) | (UInt16(b[7]) << 8)
        controlPort = data.count >= Self.sizeWithControlPort
            ? UInt16(b[224]) | (UInt16(b[225]) << 8)
            : ControllerBridgeProtocol.portControl
        if controlPort == 0 { controlPort = ControllerBridgeProtocol.portControl }
        if inputPort == 0 { inputPort = ControllerBridgeProtocol.portInput }
        let tokenStart = data.startIndex + 8
        token = data[tokenStart ..< (tokenStart + GameLibraryProtocol.tokenBytes)]

        var addresses: [String] = []
        for i in 0 ..< count {
            let start = 40 + i * Self.addrLen
            let slice = b[start ..< (start + Self.addrLen)]
            // NUL-padded C strings.
            let text = String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
            if !text.isEmpty { addresses.append(text) }
        }
        endpoints = addresses
        guard !token.allSatisfy({ $0 == 0 }) else { return nil }
    }
}

// MARK: - Host models (mirror CompanionWindows/backend/Foveated/GameLibrary.cs)

/// One title as the host describes it. Only the exposed subset ever arrives here.
struct GameLibraryTitle: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var source: String
    var steamAppId: UInt32?
    var installDir: String?
    /// Host-side paths. Useless to the headset as paths — their presence is what
    /// matters: it says whether asking for art is worth a round trip.
    var portraitArt: String?
    var landscapeArt: String?

    var hasPortraitArt: Bool { portraitArt?.isEmpty == false }
    var isSteam: Bool { source == "steam" }
}

/// Answer to an art request. A title with no cover is a normal answer
/// (`unavailable` set, `data` nil) rather than an error.
struct GameLibraryArt: Decodable {
    var id: String
    var mime: String?
    var data: String?
    var unavailable: String?
}

/// The host's `{"error": "..."}` body, sent with CB_LIB_FLAG_ERROR.
struct GameLibraryError: Decodable {
    var error: String
}

private extension Data {
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
#endif
