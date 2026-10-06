import Foundation
import Observation
import Security
import WatchConnectivity

/// The Mac the watch streams from: an address and the Companion's pairing
/// token. The token is the pre-shared key of both streams, so it lives in the
/// keychain; the address is not secret.
///
/// It arrives from the paired iPhone (`WatchConnectivity`, sent by
/// LongwaveiOS) or, for the simulator and development, from the launch
/// arguments `-watchHost <address> -watchToken <token>`.
@Observable
final class WatchHostStore: NSObject {
    struct Host: Equatable {
        var name: String
        var address: String
        var token: String
    }

    private(set) var host: Host?

    private static let hostKey = "watch.host.address"
    private static let nameKey = "watch.host.name"
    private static let account = "watch.host.token"
    private var session: WCSession?

    override init() {
        super.init()
        host = Self.load()
        if let seeded = Self.seedFromLaunchArguments() {
            apply(seeded)
        }
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
        }
    }

    func apply(_ host: Host) {
        self.host = host
        UserDefaults.standard.set(host.address, forKey: Self.hostKey)
        UserDefaults.standard.set(host.name, forKey: Self.nameKey)
        Self.storeToken(host.token)
    }

    func forget() {
        host = nil
        UserDefaults.standard.removeObject(forKey: Self.hostKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        Self.storeToken(nil)
    }

    private static func load() -> Host? {
        guard let address = UserDefaults.standard.string(forKey: hostKey),
              let token = readToken(), !address.isEmpty else { return nil }
        return Host(
            name: UserDefaults.standard.string(forKey: nameKey) ?? address,
            address: address,
            token: token
        )
    }

    private static func seedFromLaunchArguments() -> Host? {
        let defaults = UserDefaults.standard
        guard let address = defaults.string(forKey: "watchHost"),
              let token = defaults.string(forKey: "watchToken"),
              !address.isEmpty, !token.isEmpty else { return nil }
        return Host(name: defaults.string(forKey: "watchHostName") ?? address, address: address, token: token)
    }

    // MARK: Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "pro.longwave.watch",
            kSecAttrAccount as String: account,
        ]
    }

    private static func readToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func storeToken(_ token: String?) {
        SecItemDelete(baseQuery() as CFDictionary)
        guard let token else { return }
        var item = baseQuery()
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

extension WatchHostStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext
        if !context.isEmpty { Task { @MainActor in self.receive(context) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.receive(applicationContext) }
    }

    private func receive(_ context: [String: Any]) {
        guard let address = context["address"] as? String,
              let token = context["token"] as? String,
              !address.isEmpty, !token.isEmpty else { return }
        apply(Host(name: context["name"] as? String ?? address, address: address, token: token))
    }
}
