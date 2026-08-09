import Foundation
import Crypto
import NIOSSH
import Security
import os

enum SSHKeyError: Error {
    case keychain(OSStatus)
}

/// The Vision Pro's SSH client identity (`ecdsa-sha2-nistp256`).
///
/// Prefers a **Secure Enclave** P-256 key: the private key is generated in and
/// never leaves the chip — it signs the SSH user-auth payload in-enclave, so
/// even a compromised app process can't exfiltrate it. Where the Secure Enclave
/// is unavailable (the visionOS simulator) it falls back to a software P-256
/// key in the Keychain. Either way the *public* key is what the Mac stores in
/// `~/.ssh/authorized_keys` — a non-secret — so malware on the Mac learns
/// nothing it can authenticate with.
struct SecureEnclaveSSHKey: @unchecked Sendable {
    enum Backing {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)
    }

    let backing: Backing

    /// True when backed by the Secure Enclave (non-extractable).
    var isHardwareBacked: Bool {
        if case .secureEnclave = backing { return true }
        return false
    }

    /// The signing key handed to swift-nio-ssh. For the Secure Enclave variant
    /// this signs in-chip; the key material is never materialized.
    var nioPrivateKey: NIOSSHPrivateKey {
        switch backing {
        case .secureEnclave(let key): return NIOSSHPrivateKey(secureEnclaveP256Key: key)
        case .software(let key): return NIOSSHPrivateKey(p256Key: key)
        }
    }

    private var publicKey: P256.Signing.PublicKey {
        switch backing {
        case .secureEnclave(let key): return key.publicKey
        case .software(let key): return key.publicKey
        }
    }

    /// The SSH wire-format public-key blob: ssh-string("ecdsa-sha2-nistp256"),
    /// ssh-string("nistp256"), ssh-string(Q) where Q is the uncompressed point
    /// (0x04‖X‖Y), which is exactly the P-256 X9.63 representation.
    private var sshKeyBlob: Data {
        let q = publicKey.x963Representation
        var blob = Data()
        func appendString(_ d: Data) {
            var len = UInt32(d.count).bigEndian
            withUnsafeBytes(of: &len) { blob.append(contentsOf: $0) }
            blob.append(d)
        }
        appendString(Data("ecdsa-sha2-nistp256".utf8))
        appendString(Data("nistp256".utf8))
        appendString(q)
        return blob
    }

    /// An `authorized_keys` line: `ecdsa-sha2-nistp256 <base64-blob> <comment>`.
    func openSSHPublicKeyLine(comment: String) -> String {
        "ecdsa-sha2-nistp256 \(sshKeyBlob.base64EncodedString()) \(comment)"
    }

    /// The OpenSSH `SHA256:…` fingerprint (base64 of SHA-256 over the key blob,
    /// no padding) — matches `ssh-keygen -lf`.
    func sshFingerprint() -> String {
        let digest = SHA256.hash(data: sshKeyBlob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    // MARK: - Persistence

    private static let service = "pro.longwave.sshDeviceKey"
    private static let log = Logger(subsystem: "pro.longwave", category: "SSHKey")

    /// Loads the persisted device key, generating one on first use.
    static func loadOrCreate() throws -> SecureEnclaveSSHKey {
        if let data = keychainRead(account: "se"),
           let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            return SecureEnclaveSSHKey(backing: .secureEnclave(key))
        }
        if let data = keychainRead(account: "sw"),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return SecureEnclaveSSHKey(backing: .software(key))
        }

        if SecureEnclave.isAvailable {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            try keychainWrite(account: "se", data: key.dataRepresentation)
            log.info("Generated Secure Enclave SSH device key")
            return SecureEnclaveSSHKey(backing: .secureEnclave(key))
        } else {
            let key = P256.Signing.PrivateKey()
            try keychainWrite(account: "sw", data: key.rawRepresentation)
            log.info("Generated software SSH device key (Secure Enclave unavailable)")
            return SecureEnclaveSSHKey(backing: .software(key))
        }
    }

    private static func keychainWrite(account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHKeyError.keychain(status) }
    }

    private static func keychainRead(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
