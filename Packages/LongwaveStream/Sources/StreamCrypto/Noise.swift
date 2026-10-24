// StreamCrypto: the v3 handshake and secure records (NATIVE_V3_PROTOCOL.md
// section 3). The handshake is Noise_NNpsk0_25519_ChaChaPoly_SHA256, written to
// revision 34 of the Noise specification and checked against the published
// vectors in StreamCryptoTests. Everything else in this module (packets, key
// IDs, records, replay window) is Longwave's own and is specified in section 3.
//
// The primitives come from swift-crypto, which is CryptoKit on Apple platforms
// and BoringSSL elsewhere. swift-crypto pulls in FoundationEssentials, so unlike
// StreamWire this module is not Foundation-free; its API still takes and returns
// plain byte arrays.

import Crypto

/// Why a handshake or record operation failed. Every case means "drop the
/// datagram and answer nothing": a peer without the key learns nothing from
/// how a packet failed.
public enum StreamCryptoError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The packet is too short, has reserved bits set, or a field is out of range.
    case malformed(String)
    /// The initiation names a protocol major this build doesn't speak.
    case unsupportedVersion(UInt8)
    /// No PSK has the initiation's key ID.
    case unknownKey
    /// AEAD or Noise authentication failed: wrong key, tampering, or noise.
    case authenticationFailed
    /// The packet number was already accepted, or is older than the replay window.
    case replayed
    /// The packet is addressed to a connection ID this endpoint doesn't hold.
    case unknownConnection
    /// The receive key has seen as many forgeries as its cipher tolerates
    /// (RFC 9001 section 6.6); the session must end.
    case integrityLimitReached
    /// A send key ran out of packet numbers (2^64 - 1; unreachable in practice).
    case packetNumbersExhausted
    /// A handshake method was called out of order. A caller bug.
    case invalidState(String)

    public var description: String {
        switch self {
        case .malformed(let what): "malformed \(what)"
        case .unsupportedVersion(let version): "unsupported protocol major \(version)"
        case .unknownKey: "unknown key ID"
        case .authenticationFailed: "authentication failed"
        case .replayed: "replayed or too old"
        case .unknownConnection: "unknown connection ID"
        case .integrityLimitReached: "integrity limit reached"
        case .packetNumbersExhausted: "packet numbers exhausted"
        case .invalidState(let what): "invalid handshake state: \(what)"
        }
    }
}

// MARK: - Noise building blocks (spec sections 4 and 5)

enum Noise {
    static let hashLength = 32
    static let dhLength = 32
    static let tagLength = 16

    static func hash(_ data: some Sequence<UInt8>) -> [UInt8] {
        Array(SHA256.hash(data: Array(data)))
    }

    static func hmac(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// The spec's HKDF (section 4.3): HMAC-based, two or three 32-byte outputs.
    static func hkdf(chainingKey: [UInt8], inputKeyMaterial: [UInt8], outputs: Int) -> [[UInt8]] {
        let tempKey = hmac(key: chainingKey, inputKeyMaterial)
        var result: [[UInt8]] = []
        var previous: [UInt8] = []
        for index in 1...outputs {
            previous = hmac(key: tempKey, previous + [UInt8(index)])
            result.append(previous)
        }
        return result
    }

    /// ChaChaPoly's nonce: 32 bits of zeros, then the 64-bit counter little-endian.
    static func chaChaNonce(_ counter: UInt64) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 12)
        for byte in 0..<8 { nonce[4 + byte] = UInt8(truncatingIfNeeded: counter >> (8 * UInt64(byte))) }
        return nonce
    }

    static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: [UInt8]) throws(StreamCryptoError) -> [UInt8] {
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            return shared.withUnsafeBytes { Array($0) }
        } catch {
            // A low-order point gives an all-zero secret, which swift-crypto refuses.
            throw .authenticationFailed
        }
    }
}

/// The spec's CipherState with ChaChaPoly: a key and a nonce counter.
struct NoiseCipherState {
    private(set) var key: SymmetricKey?
    private(set) var nonce: UInt64 = 0

    var hasKey: Bool { key != nil }

    mutating func initializeKey(_ bytes: [UInt8]) {
        key = SymmetricKey(data: bytes)
        nonce = 0
    }

    mutating func encrypt(ad: [UInt8], _ plaintext: [UInt8]) throws(StreamCryptoError) -> [UInt8] {
        guard let key else { return plaintext }
        // 2^64 - 1 is reserved by the spec (section 5.1).
        guard nonce < UInt64.max else { throw .packetNumbersExhausted }
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: Noise.chaChaNonce(nonce)),
                                          authenticating: ad)
            nonce += 1
            return Array(box.ciphertext) + Array(box.tag)
        } catch {
            throw .invalidState("ChaChaPoly.seal")
        }
    }

    mutating func decrypt(ad: [UInt8], _ ciphertext: [UInt8]) throws(StreamCryptoError) -> [UInt8] {
        guard let key else { return ciphertext }
        guard nonce < UInt64.max else { throw .packetNumbersExhausted }
        guard ciphertext.count >= Noise.tagLength else { throw .malformed("noise.ciphertext") }
        do {
            let split = ciphertext.count - Noise.tagLength
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Noise.chaChaNonce(nonce)),
                                               ciphertext: ciphertext[..<split], tag: ciphertext[split...])
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
            nonce += 1
            return Array(plaintext)
        } catch {
            throw .authenticationFailed
        }
    }
}

/// The spec's SymmetricState: chaining key, handshake hash and a CipherState.
struct NoiseSymmetricState {
    private(set) var chainingKey: [UInt8]
    private(set) var handshakeHash: [UInt8]
    private(set) var cipher = NoiseCipherState()

    init(protocolName: String) {
        let name = Array(protocolName.utf8)
        handshakeHash = name.count <= Noise.hashLength
            ? name + [UInt8](repeating: 0, count: Noise.hashLength - name.count)
            : Noise.hash(name)
        chainingKey = handshakeHash
    }

    mutating func mixKey(_ inputKeyMaterial: [UInt8]) {
        let output = Noise.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, outputs: 2)
        chainingKey = output[0]
        cipher.initializeKey(output[1])
    }

    mutating func mixHash(_ data: [UInt8]) {
        handshakeHash = Noise.hash(handshakeHash + data)
    }

    mutating func mixKeyAndHash(_ inputKeyMaterial: [UInt8]) {
        let output = Noise.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, outputs: 3)
        chainingKey = output[0]
        mixHash(output[1])
        cipher.initializeKey(output[2])
    }

    mutating func encryptAndHash(_ plaintext: [UInt8]) throws(StreamCryptoError) -> [UInt8] {
        let ciphertext = try cipher.encrypt(ad: handshakeHash, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: [UInt8]) throws(StreamCryptoError) -> [UInt8] {
        let plaintext = try cipher.decrypt(ad: handshakeHash, ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// The two transport keys: initiator-to-responder first.
    func split() -> (initiatorToResponder: [UInt8], responderToInitiator: [UInt8]) {
        let output = Noise.hkdf(chainingKey: chainingKey, inputKeyMaterial: [], outputs: 2)
        return (output[0], output[1])
    }
}

/// The tokens the NN family uses. Patterns with static keys (IKpsk2, the
/// planned successor) would add `s`, `es`, `se` and `ss`.
enum NoiseToken: Equatable {
    case e, ee, psk
}

struct NoisePattern {
    var name: String
    var messages: [[NoiseToken]]

    var usesPSK: Bool { messages.contains { $0.contains(.psk) } }

    static let nn = NoisePattern(name: "NN", messages: [[.e], [.e, .ee]])
    static let nnPSK0 = NoisePattern(name: "NNpsk0", messages: [[.psk, .e], [.e, .ee]])
    static let nnPSK2 = NoisePattern(name: "NNpsk2", messages: [[.e], [.e, .ee, .psk]])
    static let nnPSK0PSK2 = NoisePattern(name: "NNpsk0+psk2", messages: [[.psk, .e], [.e, .ee, .psk]])

    func protocolName() -> String { "Noise_\(name)_25519_ChaChaPoly_SHA256" }
}

/// The spec's HandshakeState for the NN family (section 5.3), driven by
/// pattern tokens so the code reads like the specification.
struct NoiseHandshakeState {
    enum Role { case initiator, responder }

    let role: Role
    let pattern: NoisePattern
    private(set) var symmetric: NoiseSymmetricState
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: [UInt8]?
    private var psks: [[UInt8]]
    private var messageIndex = 0

    /// `ephemeral` is for test vectors only; a real handshake generates its own.
    init(role: Role, pattern: NoisePattern, prologue: [UInt8], psks: [[UInt8]],
         ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.role = role
        self.pattern = pattern
        self.psks = psks
        self.ephemeral = ephemeral
        symmetric = NoiseSymmetricState(protocolName: pattern.protocolName())
        symmetric.mixHash(prologue)
    }

    var isFinished: Bool { messageIndex == pattern.messages.count }
    var handshakeHash: [UInt8] { symmetric.handshakeHash }

    /// Whether the next message is ours to write.
    var isOurTurn: Bool { (messageIndex % 2 == 0) == (role == .initiator) }

    mutating func writeMessage(payload: [UInt8]) throws(StreamCryptoError) -> [UInt8] {
        guard !isFinished, isOurTurn else { throw .invalidState("write out of turn") }
        var message: [UInt8] = []
        for token in pattern.messages[messageIndex] {
            switch token {
            case .e:
                let key = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
                ephemeral = key
                let publicKey = Array(key.publicKey.rawRepresentation)
                message += publicKey
                symmetric.mixHash(publicKey)
                if pattern.usesPSK { symmetric.mixKey(publicKey) }
            case .ee:
                try mixEE()
            case .psk:
                try mixPSK()
            }
        }
        message += try symmetric.encryptAndHash(payload)
        messageIndex += 1
        return message
    }

    mutating func readMessage(_ message: [UInt8]) throws(StreamCryptoError) -> [UInt8] {
        guard !isFinished, !isOurTurn else { throw .invalidState("read out of turn") }
        var offset = 0
        for token in pattern.messages[messageIndex] {
            switch token {
            case .e:
                guard message.count - offset >= Noise.dhLength else { throw .malformed("noise.e") }
                let publicKey = Array(message[offset..<(offset + Noise.dhLength)])
                offset += Noise.dhLength
                remoteEphemeral = publicKey
                symmetric.mixHash(publicKey)
                if pattern.usesPSK { symmetric.mixKey(publicKey) }
            case .ee:
                try mixEE()
            case .psk:
                try mixPSK()
            }
        }
        let payload = try symmetric.decryptAndHash(Array(message[offset...]))
        messageIndex += 1
        return payload
    }

    func split() throws(StreamCryptoError) -> (initiatorToResponder: [UInt8], responderToInitiator: [UInt8]) {
        guard isFinished else { throw .invalidState("split before the last message") }
        return symmetric.split()
    }

    private mutating func mixEE() throws(StreamCryptoError) {
        guard let ephemeral, let remoteEphemeral else { throw .invalidState("ee without both ephemerals") }
        symmetric.mixKey(try Noise.dh(ephemeral, remoteEphemeral))
    }

    private mutating func mixPSK() throws(StreamCryptoError) {
        guard !psks.isEmpty else { throw .invalidState("psk token without a PSK") }
        symmetric.mixKeyAndHash(psks.removeFirst())
    }
}
