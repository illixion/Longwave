import CryptoKit
import Foundation

/// Finding and pairing with a Companion on the local network, with no token
/// for the user to copy and no port open on the Mac until a headset asks.
///
/// Three Bonjour services carry it, and none of them needs more than the
/// `NSBonjourServices` declaration and the local-network prompt:
///
/// - `_longwave-mac._tcp`, advertised by the Mac for as long as the Companion
///   runs. A record only — no socket listens behind it. Its TXT carries the
///   Mac's identity, its LAN addresses (wired first) and whether its stream
///   ports are open right now.
/// - `_longwave-knock._tcp`, advertised by the headset while it wants the Mac.
///   For a paired headset the TXT carries a tag only a holder of the pairing
///   secret can make, rolling every minute; seeing a valid one, the Mac opens
///   its ports, and it closes them again once the knock is withdrawn and the
///   last viewer has left. An unpaired headset knocks with `pair=1` instead.
/// - `_longwave-pair._tcp`, advertised by the Mac only while it answers one
///   pairing request: a plain TCP listener that runs `PairingExchange`.
///
/// A knock can be copied or forged by anything on the LAN, and that is fine:
/// it only decides whether a port is listening. Getting in still takes the
/// pairing secret, exactly as before.
nonisolated enum CompanionDiscovery {
    static let macServiceType = "_longwave-mac._tcp"
    static let knockServiceType = "_longwave-knock._tcp"
    static let pairServiceType = "_longwave-pair._tcp"

    /// TXT keys. Short, because a record travels in every mDNS answer.
    enum Key {
        static let version = "v"
        static let macID = "id"
        static let addresses = "addr"
        static let open = "open"
        static let headsetID = "hs"
        static let tag = "t"
        static let pairRequest = "pair"
        static let name = "n"
    }

    static let version = "1"

    /// How long a knock tag stays valid: its own minute and the one either side,
    /// so clock skew between the devices of up to a minute still works.
    static let tagWindowMinutes: Int64 = 1

    static func minute(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// The knock tag a paired headset advertises: HMAC of the Mac, the headset
    /// and the minute under a key derived from the pairing token. Truncated —
    /// it gates a listener, it isn't the authentication.
    static func knockTag(token: String, macID: String, headsetID: String, minute: Int64) -> String {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
            salt: Data("Longwave-Knock-v1".utf8),
            info: Data("knock".utf8),
            outputByteCount: 32
        )
        let message = Data("\(macID)|\(headsetID)|\(minute)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac.prefix(12)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isValidKnock(
        tag: String, token: String, macID: String, headsetID: String, now: Date = Date()
    ) -> Bool {
        let current = minute(of: now)
        for offset in -tagWindowMinutes...tagWindowMinutes {
            let expected = knockTag(token: token, macID: macID, headsetID: headsetID, minute: current + offset)
            if constantTimeEqual(expected, tag) { return true }
        }
        return false
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<x.count { difference |= x[i] ^ y[i] }
        return difference == 0
    }
}

// MARK: - Pairing exchange

/// What the Mac hands a headset once the user has approved it.
nonisolated struct PairingGrant: Codable, Sendable, Equatable {
    var token: String
    var macID: String
    var macName: String
    /// LAN addresses, wired first, as a starting host for the connection.
    var addresses: [String]
}

/// One numeric-comparison pairing, as both ends run it.
///
/// The headset commits to its key and nonce before it sees the Mac's, and
/// reveals them only after; both ends then show a six-digit code drawn from
/// the whole transcript, and the user approves on the Mac only if the codes
/// match. Something sitting between the two would have had to fix its keys on
/// each side before learning what the other side would contribute, so its two
/// codes match by chance one time in a million. The agreed key then seals the
/// grant (the Companion's token) on its way to the headset.
///
/// Messages are length-prefixed JSON (`PairingMessage`), on a plain TCP
/// connection: everything that needs protecting is protected by the exchange.
nonisolated struct PairingExchange {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let nonce: Data

    init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data = PairingExchange.randomNonce()) {
        self.privateKey = privateKey
        self.nonce = nonce
    }

    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    static func randomNonce() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    /// The headset's opening move: a hash binding its key and nonce.
    static func commitment(publicKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: publicKey + nonce))
    }

    struct Agreement {
        /// Six digits, for both screens.
        let code: String
        let key: SymmetricKey
    }

    /// Runs on both ends once all four values are known. Returns nil when the
    /// revealed headset values don't match the commitment, or a key is bad.
    static func agree(
        mine: PairingExchange,
        theirPublicKey: Data,
        commitment: Data,
        headsetPublicKey: Data, headsetNonce: Data,
        macPublicKey: Data, macNonce: Data
    ) -> Agreement? {
        guard Self.commitment(publicKey: headsetPublicKey, nonce: headsetNonce) == commitment,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPublicKey),
              let shared = try? mine.privateKey.sharedSecretFromKeyAgreement(with: theirs) else {
            return nil
        }
        let transcript = Data(SHA256.hash(data: commitment + macPublicKey + macNonce + headsetPublicKey + headsetNonce))
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: transcript, sharedInfo: Data("Longwave-Pair-v1".utf8), outputByteCount: 32
        )
        let number = transcript.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return Agreement(code: String(format: "%06u", number), key: key)
    }

    static func seal(_ grant: PairingGrant, with key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(JSONEncoder().encode(grant), using: key).combined
    }

    static func open(_ sealed: Data, with key: SymmetricKey) throws -> PairingGrant {
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        return try JSONDecoder().decode(PairingGrant.self, from: ChaChaPoly.open(box, using: key))
    }

    /// "123456" → "123 456".
    static func display(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

/// The messages of a pairing, in order: headset `commit`, Mac `macHello`,
/// headset `reveal`, Mac `accept` or `deny`.
nonisolated enum PairingMessage: Codable, Sendable, Equatable {
    case commit(headsetID: String, headsetName: String, commitment: Data)
    case macHello(macID: String, macName: String, publicKey: Data, nonce: Data)
    case reveal(publicKey: Data, nonce: Data)
    case accept(sealedGrant: Data)
    case deny

    static let maxBytes = 16 * 1024

    func framed() throws -> Data {
        let body = try JSONEncoder().encode(self)
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Pulls one complete message off the front of `buffer`, if it holds one.
    static func take(from buffer: inout Data) throws -> PairingMessage? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard length <= maxBytes else { throw CocoaError(.coderReadCorrupt) }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + length))
        buffer.removeFirst(4 + length)
        return try JSONDecoder().decode(PairingMessage.self, from: body)
    }
}
