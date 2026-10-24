import Crypto

/// The pre-shared key one paired device uses for v3 (section 3, "Per-device PSK").
///
/// `psk = HKDF-SHA256(token, salt: "Longwave-NS3-PSK", info: identity)`, where
/// `token` is the credential the Companion minted for the device and `identity`
/// is its device ID. A credential from before per-device enrollment (the shared
/// token) uses the headset ID instead, so two headsets on one token still get
/// different keys.
public struct StreamPSK: Sendable, Equatable {
    public static let salt = Array("Longwave-NS3-PSK".utf8)
    public static let keyIDLength = 8

    public let bytes: [UInt8]
    /// `HMAC-SHA256(psk, "kid")[0..<8]`: lets a host holding several PSKs pick the
    /// right one from the initiation without trial decryption.
    public let keyID: KeyID

    public init(token: String, identity: String) {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Array(token.utf8)),
                                         salt: Self.salt, info: Array(identity.utf8), outputByteCount: 32)
        self.init(bytes: key.withUnsafeBytes { Array($0) })
    }

    /// A raw 32-byte PSK (tests, and pairing revisions that mint random keys).
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "a Noise PSK is 32 bytes")
        self.bytes = bytes
        let code = HMAC<SHA256>.authenticationCode(for: Array("kid".utf8), using: SymmetricKey(data: bytes))
        keyID = KeyID(Array(code.prefix(Self.keyIDLength)))
    }

    /// Eight bytes, compared in constant time.
    public struct KeyID: Sendable, Hashable, CustomStringConvertible {
        public let bytes: [UInt8]

        public init(_ bytes: [UInt8]) {
            precondition(bytes.count == StreamPSK.keyIDLength)
            self.bytes = bytes
        }

        public static func == (a: Self, b: Self) -> Bool {
            var difference: UInt8 = 0
            for (x, y) in zip(a.bytes, b.bytes) { difference |= x ^ y }
            return difference == 0
        }

        public func hash(into hasher: inout Hasher) { hasher.combine(bytes) }

        public var description: String {
            bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        }
    }
}
