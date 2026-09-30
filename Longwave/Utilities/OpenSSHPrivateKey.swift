import Crypto
import Foundation
import NIOSSH

/// Reads an unencrypted OpenSSH `ssh-ed25519` private key file
/// (`-----BEGIN OPENSSH PRIVATE KEY-----`, the `openssh-key-v1` container that
/// `ssh-keygen -t ed25519 -N ''` writes).
///
/// The headset authenticates with its Secure Enclave key; the Mac client talks
/// to the local agent sandbox with the file key `install.sh` generated
/// (`~/.ssh/longwave_sandbox_ed25519`), which it then shares with the
/// Terminal.app attach command. Passphrase-protected keys are rejected rather
/// than decrypted — install.sh never makes one.
enum OpenSSHPrivateKey {
    enum ParseError: Error, Equatable, CustomStringConvertible {
        case notOpenSSHFormat
        case encrypted
        case unsupportedKeyType(String)
        case malformed

        var description: String {
            switch self {
            case .notOpenSSHFormat: return "Not an OpenSSH private key"
            case .encrypted: return "The key is passphrase-protected"
            case .unsupportedKeyType(let t): return "Unsupported key type \(t)"
            case .malformed: return "The key file is malformed"
            }
        }
    }

    /// The 32-byte Ed25519 seed from the PEM text.
    static func ed25519Seed(fromPEM pem: String) throws -> Data {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----"
        guard let b = pem.range(of: begin), let e = pem.range(of: end), b.upperBound <= e.lowerBound else {
            throw ParseError.notOpenSSHFormat
        }
        let body = pem[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard let blob = Data(base64Encoded: String(body)) else { throw ParseError.malformed }
        var r = Reader(blob)
        guard r.bytes(15) == Data("openssh-key-v1\0".utf8) else { throw ParseError.notOpenSSHFormat }
        let cipher = try r.string(), kdf = try r.string()
        _ = try r.string()  // kdf options
        guard cipher == Data("none".utf8), kdf == Data("none".utf8) else { throw ParseError.encrypted }
        guard try r.uint32() == 1 else { throw ParseError.malformed }
        _ = try r.string()  // public key blob
        var priv = Reader(try r.string())
        // Two equal random check words guard against a wrong passphrase; with
        // no cipher they must still match.
        guard try priv.uint32() == (try priv.uint32()) else { throw ParseError.malformed }
        let type = String(decoding: try priv.string(), as: UTF8.self)
        guard type == "ssh-ed25519" else { throw ParseError.unsupportedKeyType(type) }
        let pub = try priv.string()
        let secret = try priv.string()  // seed ‖ public key
        guard pub.count == 32, secret.count == 64, secret.suffix(32) == pub else { throw ParseError.malformed }
        return Data(secret.prefix(32))
    }

    static func nioPrivateKey(fromPEM pem: String) throws -> NIOSSHPrivateKey {
        let seed = try ed25519Seed(fromPEM: pem)
        return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    static func nioPrivateKey(contentsOf url: URL) throws -> NIOSSHPrivateKey {
        try nioPrivateKey(fromPEM: String(contentsOf: url, encoding: .utf8))
    }

    private struct Reader {
        private let data: Data
        private var offset = 0
        init(_ data: Data) { self.data = Data(data) }

        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: offset..<(offset + n))
        }

        mutating func uint32() throws -> UInt32 {
            guard let b = bytes(4) else { throw ParseError.malformed }
            return b.reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() throws -> Data {
            let n = Int(try uint32())
            guard let b = bytes(n) else { throw ParseError.malformed }
            return b
        }
    }
}
