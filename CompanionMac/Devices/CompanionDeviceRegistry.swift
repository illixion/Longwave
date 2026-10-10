import DebugTrace
import Foundation

/// A device paired with this Mac: who it is and what the user allowed it in
/// the pairing dialog. Its token lives in this Mac's keychain, never here.
struct CompanionDevice: Codable, Identifiable, Equatable, Sendable {
    /// The device's own pairing identity (`CompanionLocator.headsetID`).
    let id: String
    var name: String
    var grants: Set<CompanionGrant>
    var pairedAt: Date
    var lastSeen: Date?
    /// The SSH public key it offered at pairing. In `authorized_keys` exactly
    /// while it holds the `sshKey` grant.
    var sshPublicKey: String?
}

/// The paired devices and the one shared token from before per-device
/// pairing, which is still accepted — with the old Screen + Audio + Input
/// reach — until the user stops accepting it.
///
/// Servers read it through `keyring`, a lock-protected snapshot, from their
/// own queues; `onChange` tells the owner to rebuild listeners, which hold
/// their keys for life.
@Observable
@MainActor
final class CompanionDeviceRegistry {
    private(set) var devices: [CompanionDevice] = []
    /// The deprecated shared token, if this Mac ever had one.
    private(set) var legacyToken: String?
    private(set) var acceptsLegacyToken: Bool
    /// The last time a device connected with the shared token: the Devices tab
    /// shows how recently something still relied on it.
    private(set) var legacyLastSeen: Date?

    let keyring = CompanionKeyring()
    @ObservationIgnored private var observers: [() -> Void] = []

    /// Called after every enrollment, revocation or grant change, once the
    /// keyring holds the new set.
    func observe(_ handler: @escaping () -> Void) { observers.append(handler) }

    private static let devicesKey = "companion.devices.v1"
    private static let legacyTokenKey = "audioStreamToken"
    private static let acceptsLegacyKey = "companion.acceptsLegacyToken"
    private static let legacySeenKey = "companion.legacyLastSeen"
    static let keychainService = "pro.longwave.companion.device"
    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "Devices")

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.devicesKey) {
            devices = (try? JSONDecoder().decode([CompanionDevice].self, from: data)) ?? []
        }
        let legacy = defaults.string(forKey: Self.legacyTokenKey).flatMap { $0.isEmpty ? nil : $0 }
        legacyToken = legacy
        acceptsLegacyToken = legacy != nil && (defaults.object(forKey: Self.acceptsLegacyKey) as? Bool ?? true)
        legacyLastSeen = defaults.object(forKey: Self.legacySeenKey) as? Date
        // A device whose keychain item is gone can't connect; don't list it.
        devices.removeAll { KeychainStore.get(service: Self.keychainService, account: $0.id) == nil }
        rebuildKeyring()
    }

    func device(_ id: String) -> CompanionDevice? { devices.first { $0.id == id } }

    /// Pairing approved: a fresh token for this device (pairing again
    /// replaces the old one), with exactly the grants the user ticked.
    func enroll(id: String, name: String, grants: Set<CompanionGrant>, sshPublicKey: String? = nil) -> String? {
        let token = CompanionCredential.generateToken()
        guard KeychainStore.set(service: Self.keychainService, account: id, value: token) else {
            log.error("Couldn't store a paired device's token in the keychain")
            return nil
        }
        let previous = device(id)
        devices.removeAll { $0.id == id }
        // A device that pairs again without a key keeps the one it gave before.
        let device = CompanionDevice(id: id, name: String(name.prefix(80)), grants: grants, pairedAt: Date(),
                                     lastSeen: Date(), sshPublicKey: sshPublicKey ?? previous?.sshPublicKey)
        if let old = previous?.sshPublicKey, old != device.sshPublicKey { removeSSHKey(old) }
        devices.append(device)
        applySSHKey(device)
        changed()
        return token
    }

    func setGrants(_ grants: Set<CompanionGrant>, for id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].grants != grants else { return }
        devices[index].grants = grants
        applySSHKey(devices[index])
        changed()
    }

    func rename(_ id: String, to name: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].name = String(name.prefix(80))
        persist()
    }

    func revoke(_ id: String) {
        if let key = device(id)?.sshPublicKey { removeSSHKey(key) }
        KeychainStore.delete(service: Self.keychainService, account: id)
        devices.removeAll { $0.id == id }
        changed()
    }

    /// Ends the shared token for good: every device still using it has to pair.
    func stopAcceptingLegacyToken() {
        acceptsLegacyToken = false
        legacyToken = nil
        UserDefaults.standard.set(false, forKey: Self.acceptsLegacyKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyTokenKey)
        changed()
    }

    /// A connection proved it is this device (nil: the shared token).
    func noteSeen(_ deviceID: String?) {
        let now = Date()
        if let deviceID {
            guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
            if let last = devices[index].lastSeen, now.timeIntervalSince(last) < 60 { return }
            devices[index].lastSeen = now
            persist()
        } else {
            if let last = legacyLastSeen, now.timeIntervalSince(last) < 60 { return }
            legacyLastSeen = now
            UserDefaults.standard.set(now, forKey: Self.legacySeenKey)
        }
    }

    /// The tokens a knock from this headset may be tagged with: its own, and
    /// while it's still accepted, the shared one.
    func knockTokens(headsetID: String) -> [String] {
        var tokens: [String] = []
        if device(headsetID) != nil, let token = KeychainStore.get(service: Self.keychainService, account: headsetID) {
            tokens.append(token)
        }
        if acceptsLegacyToken, let legacyToken { tokens.append(legacyToken) }
        return tokens
    }

    /// Whether a device can hold the SSH grant at all: only one that sent a key.
    func offersSSH(_ id: String) -> Bool { device(id)?.sshPublicKey != nil }

    /// Keeps `authorized_keys` in step with the grant. The line's comment
    /// carries "longwave" so the Remote tab lists it.
    private func applySSHKey(_ device: CompanionDevice) {
        guard let line = device.sshPublicKey, let key = AuthorizedKeysManager.parse(line) else { return }
        do {
            if device.grants.contains(.sshKey) {
                try AuthorizedKeysManager.add(line: "\(key.type) \(key.base64) longwave \(device.name.replacingOccurrences(of: "\n", with: " "))")
            } else {
                try AuthorizedKeysManager.remove(base64: key.base64)
            }
        } catch {
            log.error("Couldn't update authorized_keys: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeSSHKey(_ line: String) {
        guard let key = AuthorizedKeysManager.parse(line) else { return }
        try? AuthorizedKeysManager.remove(base64: key.base64)
    }

    private func changed() {
        persist()
        rebuildKeyring()
        for observer in observers { observer() }
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: Self.devicesKey)
    }

    private func rebuildKeyring() {
        var entries: [CompanionKeyring.Entry] = devices.compactMap { device in
            KeychainStore.get(service: Self.keychainService, account: device.id).map {
                .init(credential: CompanionCredential(token: $0, deviceID: device.id), grants: device.grants)
            }
        }
        if acceptsLegacyToken, let legacyToken {
            entries.append(.init(credential: CompanionCredential(token: legacyToken, deviceID: nil), grants: CompanionGrant.legacy))
        }
        keyring.replace(entries)
    }
}
