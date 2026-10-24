import Crypto
import StreamWire

/// The v3 handshake on the wire (section 3, "Handshake and keys").
///
/// ```
/// initiation  0x01 | major u8 (3) | key ID [8] | e [32] | sealed(sender index u32 | cipher offer u8 | payload)
/// response    0x02 | receiver index u32 | e [32] | sealed(sender index u32 | cipher u8 | payload)
/// ```
///
/// The sealed parts are Noise_NNpsk0 messages 1 and 2. The Noise prologue is
/// `"Longwave-NS3"` followed by the initiation's first ten bytes, so the major
/// and key ID are authenticated even though they travel in the clear. Each side
/// picks its own connection ID and states it inside its sealed part; transport
/// packets carry the receiver's. The payloads are the hello and hello-ack of
/// section 4.6, opaque here.
public enum StreamHandshake {
    public static let protocolMajor: UInt8 = 3
    static let pattern = NoisePattern.nnPSK0
    public static let protocolName = pattern.protocolName()
    static let prologueLabel = Array("Longwave-NS3".utf8)

    static let initiationClearSize = 10            // kind, major, key ID
    static let initiationOverhead = initiationClearSize + Noise.dhLength + 5 + Noise.tagLength
    static let responseClearSize = 5               // kind, receiver index
    static let responseOverhead = responseClearSize + Noise.dhLength + 5 + Noise.tagLength

    /// Largest hello payload whose initiation still fits the default UDP payload.
    public static let maxInitiationPayload = 1200 - initiationOverhead
    /// The same for the hello-ack.
    public static let maxResponsePayload = 1200 - responseOverhead

    /// A random connection ID. Callers pick again on a collision with one they hold.
    public static func randomIndex() -> UInt32 {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }

    /// The key ID of an initiation, so the host can look up the PSK. Fails for
    /// anything that isn't a well-formed initiation of a supported major.
    public static func keyID(ofInitiation datagram: [UInt8]) throws(StreamCryptoError) -> StreamPSK.KeyID {
        guard PacketKind.of(datagram) == .initiation else { throw .malformed("initiation.flags") }
        guard datagram.count >= initiationOverhead else { throw .malformed("initiation.length") }
        guard datagram[1] == protocolMajor else { throw .unsupportedVersion(datagram[1]) }
        return StreamPSK.KeyID(Array(datagram[2..<initiationClearSize]))
    }

    static func prologue(_ initiation: [UInt8]) -> [UInt8] {
        prologueLabel + initiation[..<initiationClearSize]
    }
}

/// The established keys of one session, as either side holds them.
public struct SecureSession: Sendable {
    /// Our connection ID: incoming transport packets carry it.
    public var localIndex: UInt32 { receiver.localIndex }
    /// The peer's connection ID: our transport packets carry it.
    public var remoteIndex: UInt32 { sender.receiverIndex }
    public var cipher: RecordCipher { sender.cipher }
    /// The Noise handshake hash, the same on both sides: a channel binding for
    /// anything that must be tied to this session.
    public let handshakeHash: [UInt8]
    public var sender: RecordSender
    public var receiver: RecordReceiver

    init(cipher: RecordCipher, sendKey: [UInt8], receiveKey: [UInt8], localIndex: UInt32, remoteIndex: UInt32,
         handshakeHash: [UInt8], now: UInt64) {
        sender = RecordSender(key: RecordKey(cipher: cipher, splitKey: sendKey), receiverIndex: remoteIndex, now: now)
        receiver = RecordReceiver(key: RecordKey(cipher: cipher, splitKey: receiveKey), localIndex: localIndex)
        self.handshakeHash = handshakeHash
    }
}

/// The client side: builds an initiation and completes on the host's response.
///
/// One instance is one attempt. A retry after a timeout makes a new initiator,
/// with a fresh ephemeral key, rather than resending the old initiation (as
/// WireGuard does), so a host's replay filter never has to tell a retry from a
/// replay.
public struct StreamInitiator {
    public let localIndex: UInt32
    /// The datagram to send.
    public let initiation: [UInt8]
    private var state: NoiseHandshakeState

    public init(psk: StreamPSK, localIndex: UInt32, ciphers: [RecordCipher] = RecordCipher.allCases,
                payload: [UInt8]) throws(StreamCryptoError) {
        try self.init(psk: psk, localIndex: localIndex, ciphers: ciphers, payload: payload, ephemeral: nil)
    }

    init(psk: StreamPSK, localIndex: UInt32, ciphers: [RecordCipher], payload: [UInt8],
         ephemeral: Curve25519.KeyAgreement.PrivateKey?) throws(StreamCryptoError) {
        guard !ciphers.isEmpty else { throw .invalidState("no record cipher offered") }
        guard payload.count <= StreamHandshake.maxInitiationPayload else { throw .malformed("initiation.payload") }
        let clear = [PacketKind.initiation.rawValue, StreamHandshake.protocolMajor] + psk.keyID.bytes
        var state = NoiseHandshakeState(role: .initiator, pattern: StreamHandshake.pattern,
                                        prologue: StreamHandshake.prologue(clear), psks: [psk.bytes],
                                        ephemeral: ephemeral)
        var inner = WireWriter(reservingCapacity: 5 + payload.count)
        inner.writeUInt32(localIndex)
        inner.writeUInt8(RecordCipher.offer(ciphers))
        inner.writeBytes(payload)
        initiation = clear + (try state.writeMessage(payload: inner.bytes))
        self.state = state
        self.localIndex = localIndex
    }

    /// Completes the handshake. Errors mean "not our response": keep waiting.
    public func complete(response datagram: [UInt8], now: UInt64) throws(StreamCryptoError) -> (session: SecureSession, payload: [UInt8]) {
        guard PacketKind.of(datagram) == .response else { throw .malformed("response.flags") }
        guard datagram.count >= StreamHandshake.responseOverhead else { throw .malformed("response.length") }
        guard littleEndian(datagram[1..<5]) as UInt32 == localIndex else { throw .unknownConnection }
        var state = state
        let inner = try state.readMessage(Array(datagram[StreamHandshake.responseClearSize...]))
        guard inner.count >= 5 else { throw .malformed("response.inner") }
        let remoteIndex: UInt32 = littleEndian(inner[0..<4])
        guard let cipher = RecordCipher(rawValue: inner[4]) else { throw .malformed("response.cipher") }
        let keys = try state.split()
        let session = SecureSession(cipher: cipher, sendKey: keys.initiatorToResponder,
                                    receiveKey: keys.responderToInitiator, localIndex: localIndex,
                                    remoteIndex: remoteIndex, handshakeHash: state.handshakeHash, now: now)
        return (session, Array(inner[5...]))
    }
}

/// The host side: an initiation that authenticated, waiting for the host to
/// choose its hello-ack.
///
/// The host answers nothing that fails here, so the port stays silent to
/// anyone without a paired key. It should also run a session made from an
/// initiation alongside, not instead of, an existing one with the same device
/// until the new one's first transport packet authenticates
/// (`receiver.hasAcceptedPacket`): only the real client can send that, so a
/// replayed initiation can't tear a live session down.
public struct StreamResponder {
    public let initiatorIndex: UInt32
    /// The client's hello.
    public let payload: [UInt8]
    public let offeredCiphers: [RecordCipher]
    /// The client's ephemeral public key: the key for `InitiationReplayFilter`.
    public let initiatorEphemeral: [UInt8]
    public let keyID: StreamPSK.KeyID
    private var state: NoiseHandshakeState

    /// Authenticates an initiation. `lookup` returns the PSK for a key ID, or nil.
    public init(initiation datagram: [UInt8], lookup: (StreamPSK.KeyID) -> StreamPSK?) throws(StreamCryptoError) {
        try self.init(initiation: datagram, lookup: lookup, ephemeral: nil)
    }

    init(initiation datagram: [UInt8], lookup: (StreamPSK.KeyID) -> StreamPSK?,
         ephemeral: Curve25519.KeyAgreement.PrivateKey?) throws(StreamCryptoError) {
        let keyID = try StreamHandshake.keyID(ofInitiation: datagram)
        guard let psk = lookup(keyID), psk.keyID == keyID else { throw .unknownKey }
        var state = NoiseHandshakeState(role: .responder, pattern: StreamHandshake.pattern,
                                        prologue: StreamHandshake.prologue(datagram), psks: [psk.bytes],
                                        ephemeral: ephemeral)
        let message = Array(datagram[StreamHandshake.initiationClearSize...])
        let inner = try state.readMessage(message)
        guard inner.count >= 5 else { throw .malformed("initiation.inner") }
        initiatorIndex = littleEndian(inner[0..<4])
        offeredCiphers = RecordCipher.offered(in: inner[4])
        guard !offeredCiphers.isEmpty else { throw .malformed("initiation.ciphers") }
        payload = Array(inner[5...])
        initiatorEphemeral = Array(message[..<Noise.dhLength])
        self.keyID = keyID
        self.state = state
    }

    /// The first of `preferred` the client offered, if any.
    public func choose(from preferred: [RecordCipher]) -> RecordCipher? {
        preferred.first { offeredCiphers.contains($0) }
    }

    /// Writes the response and returns the session with the datagram to send.
    public func respond(localIndex: UInt32, cipher: RecordCipher, payload: [UInt8],
                        now: UInt64) throws(StreamCryptoError) -> (session: SecureSession, response: [UInt8]) {
        guard offeredCiphers.contains(cipher) else { throw .invalidState("cipher not offered") }
        guard payload.count <= StreamHandshake.maxResponsePayload else { throw .malformed("response.payload") }
        var state = state
        var inner = WireWriter(reservingCapacity: 5 + payload.count)
        inner.writeUInt32(localIndex)
        inner.writeUInt8(cipher.rawValue)
        inner.writeBytes(payload)
        var clear = WireWriter(reservingCapacity: StreamHandshake.responseClearSize)
        clear.writeUInt8(PacketKind.response.rawValue)
        clear.writeUInt32(initiatorIndex)
        let response = clear.bytes + (try state.writeMessage(payload: inner.bytes))
        let keys = try state.split()
        let session = SecureSession(cipher: cipher, sendKey: keys.responderToInitiator,
                                    receiveKey: keys.initiatorToResponder, localIndex: localIndex,
                                    remoteIndex: initiatorIndex, handshakeHash: state.handshakeHash, now: now)
        return (session, response)
    }
}

/// Remembers recently answered initiations by the client's ephemeral key.
///
/// An exact repeat is either a replay or the client re-sending because the
/// response was lost; since clients retry with a fresh initiation, the host
/// resends its cached response once and never builds a second session from it.
public struct InitiationReplayFilter<Response> {
    public let lifetime: UInt64
    public let capacity: Int
    private var entries: [[UInt8]: (seenAt: UInt64, response: Response)] = [:]

    /// `lifetime` in nanoseconds; the default covers a client's whole retry run.
    public init(lifetime: UInt64 = 120_000_000_000, capacity: Int = 256) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    /// The response cached for this ephemeral key, if it was answered recently.
    public mutating func lookup(_ ephemeral: [UInt8], now: UInt64) -> Response? {
        expire(now: now)
        return entries[ephemeral]?.response
    }

    public mutating func remember(_ ephemeral: [UInt8], response: Response, now: UInt64) {
        expire(now: now)
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.seenAt < $1.value.seenAt })?.key {
            entries[oldest] = nil
        }
        entries[ephemeral] = (now, response)
    }

    private mutating func expire(now: UInt64) {
        entries = entries.filter { now &- $0.value.seenAt < lifetime }
    }
}
