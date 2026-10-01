import Foundation
import Security

/// Minimal generic-password Keychain store for small secrets — e.g. the
/// per-host Claude OAuth token that's injected over the encrypted SSH channel.
///
/// Uses the same accessibility tier as the SSH device key
/// (`…AfterFirstUnlockThisDeviceOnly`): survives reboot once the device is
/// unlocked, never syncs to iCloud, never leaves this device. The high-value
/// secret therefore lives **only on the Vision Pro** and is streamed into each
/// session as an environment variable — it's never written to the Mac at rest.
enum KeychainStore {

    /// Stores `value` for `(service, account)`, replacing any existing item.
    /// An empty value deletes the item (no empty secrets persisted).
    static func set(service: String, account: String, value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
