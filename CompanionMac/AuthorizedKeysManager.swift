import Foundation
import CryptoKit

/// A parsed SSH public key from `authorized_keys`.
struct AuthorizedKey: Identifiable, Hashable {
    let type: String
    let base64: String
    let comment: String

    var line: String { comment.isEmpty ? "\(type) \(base64)" : "\(type) \(base64) \(comment)" }
    var id: String { base64 }

    /// OpenSSH `SHA256:…` fingerprint (base64 of SHA-256 over the key blob, no
    /// padding) — matches `ssh-keygen -lf`.
    var fingerprint: String {
        guard let blob = Data(base64Encoded: base64) else { return "SHA256:?" }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// Reads/writes the current user's `~/.ssh/authorized_keys`. The companion is
/// un-sandboxed, so this is a plain file write the user's account already owns
/// — no elevation needed (unlike enabling Remote Login, which is a system
/// daemon). StrictModes-compatible perms are enforced (`~/.ssh` 0700, file
/// 0600). A key is only ever added for a paired device the user allowed SSH
/// in the pairing dialog or the Devices tab (`CompanionDeviceRegistry`).
enum AuthorizedKeysManager {
    enum KeyError: LocalizedError {
        case invalid
        var errorDescription: String? { "Not a valid SSH public key." }
    }

    private static let validTypes: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ssh-dss",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    static func parse(_ line: String) -> AuthorizedKey? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2,
              validTypes.contains(parts[0]),
              Data(base64Encoded: parts[1]) != nil else { return nil }
        let comment = parts.count >= 3 ? parts[2...].joined(separator: " ") : ""
        return AuthorizedKey(type: parts[0], base64: parts[1], comment: comment)
    }

    private static var sshDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }
    private static var authorizedKeysURL: URL {
        sshDir.appendingPathComponent("authorized_keys")
    }

    static func read() -> [AuthorizedKey] {
        guard let content = try? String(contentsOf: authorizedKeysURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { parse(String($0)) }
    }

    static func add(line: String) throws {
        guard let key = parse(line) else { throw KeyError.invalid }
        let fm = FileManager.default
        if !fm.fileExists(atPath: sshDir.path) {
            try fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        var lines = (try? String(contentsOf: authorizedKeysURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        guard !lines.contains(where: { parse($0)?.base64 == key.base64 }) else { return }
        lines.append(key.line)
        try writeLines(lines)
    }

    static func remove(base64: String) throws {
        guard let content = try? String(contentsOf: authorizedKeysURL, encoding: .utf8) else { return }
        let kept = content.split(separator: "\n").map(String.init)
            .filter { parse($0)?.base64 != base64 }
        try writeLines(kept)
    }

    private static func writeLines(_ lines: [String]) throws {
        let out = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try out.write(to: authorizedKeysURL, atomically: true, encoding: .utf8)
        // Atomic write replaces the inode, so re-assert 0600.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: authorizedKeysURL.path)
    }

    /// This Mac's SSH host-key fingerprint, for out-of-band verification of the
    /// host key the client pins on first connect.
    static func macHostFingerprint() -> String? {
        for name in ["ssh_host_ed25519_key.pub", "ssh_host_ecdsa_key.pub", "ssh_host_rsa_key.pub"] {
            let url = URL(fileURLWithPath: "/etc/ssh/").appendingPathComponent(name)
            if let content = try? String(contentsOf: url, encoding: .utf8),
               let key = parse(content.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return key.fingerprint
            }
        }
        return nil
    }
}
