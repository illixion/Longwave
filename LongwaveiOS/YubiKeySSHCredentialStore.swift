import Foundation
import Security

/// A remembered OpenPGP authentication key. The user PIN is held only in the
/// device-only Keychain item alongside its public identity and label.
struct YubiKeySSHCredential: Codable, Hashable, Sendable, Identifiable {
    let fingerprint: String
    var label: String
    let publicKey: Data
    let pin: String

    var id: String { fingerprint }
}

enum YubiKeySSHCredentialStore {
    private static let service = "pro.longwave.yubikey-ssh-credential.v1"

    static func all() -> [YubiKeySSHCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item -> YubiKeySSHCredential? in
            guard let data = item[kSecValueData as String] as? Data else { return nil }
            return try? JSONDecoder().decode(YubiKeySSHCredential.self, from: data)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func credential(fingerprint: String) -> YubiKeySSHCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: fingerprint,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(YubiKeySSHCredential.self, from: data)
    }

    @discardableResult
    static func save(_ credential: YubiKeySSHCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.fingerprint,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(fingerprint: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: fingerprint,
        ] as CFDictionary)
    }
}
