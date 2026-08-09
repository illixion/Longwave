import Foundation
import Security
import os

/// Logging for BroadcastCore, which compiles into both the app and the
/// broadcast extension (where `AppLog` isn't available). Public privacy,
/// same caveat as `Logger.line()`: never log secrets.
nonisolated let broadcastLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.illixion.Longwave",
    category: "Broadcast")

nonisolated func broadcastLog(_ message: String) {
    broadcastLogger.log("\(message, privacy: .public)")
}

/// Configuration shared between the app (writes, via the Broadcast tab) and
/// the broadcast upload extension (reads, in its own process) — hence the
/// app-group defaults and app-group keychain access group.
nonisolated enum BroadcastShared {
    /// Preferred App Group (what the checked-in entitlements declare —
    /// granted on Xcode-signed builds).
    static let preferredAppGroup = "group.com.illixion.Longwave"
    static let keychainService = "com.illixion.Longwave.broadcast"
    static let keychainAccount = "publish-password"
    /// The extension's bundle identifier (must stay in sync with the
    /// `LongwaveBroadcast` target and `RPSystemBroadcastPickerView`).
    static let extensionBundleID = "com.illixion.Longwave.broadcast"

    /// The App Group both processes actually share. Sideload re-signing
    /// (scripts/build-and-sign.sh) replaces our entitlements with the
    /// provisioning profile's, whose group IDs we don't control — so resolve
    /// the group from the bundle's embedded.mobileprovision at runtime
    /// (the script embeds the same profile in app and extension, and both
    /// pick deterministically: preferred group if granted, else first
    /// sorted). Simulator/Xcode builds fall back to the preferred group.
    static let appGroup: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              // The profile is CMS/DER-wrapped plist; latin1 keeps the XML
              // payload findable without real CMS parsing.
              let text = String(data: raw, encoding: .isoLatin1),
              let keyRange = text.range(of: "<key>com.apple.security.application-groups</key>") else {
            return preferredAppGroup
        }
        let tail = text[keyRange.upperBound...]
        guard let arrayEnd = tail.range(of: "</array>") else { return preferredAppGroup }
        let groups = tail[..<arrayEnd.lowerBound]
            .components(separatedBy: "<string>").dropFirst()
            .compactMap { $0.components(separatedBy: "</string>").first }
            .filter { !$0.isEmpty }
        if groups.contains(preferredAppGroup) { return preferredAppGroup }
        return groups.sorted().first ?? preferredAppGroup
    }()

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    enum Keys {
        static let camera = "broadcast.cameraID"
        static let mic = "broadcast.micEnabled"
        static let host = "broadcast.host"
        static let port = "broadcast.port"
        static let path = "broadcast.path"
        static let viewPath = "broadcast.viewPath"
        static let username = "broadcast.username"
        static let bitrate = "broadcast.bitrateMbps"
        /// SHA-256 of the server TLS cert (DER, lowercase hex); empty = plain RTSP.
        static let certFingerprint = "broadcast.certFingerprint"
    }

    struct ServerConfig {
        let host: String
        let port: UInt16
        let path: String
        let username: String?
        let password: String?
        let bitrateMbps: Int
        /// Non-nil enables RTSPS with this pinned cert hash.
        let pinnedCertSHA256: Data?
    }

    static func dataFromHex(_ hex: String) -> Data? {
        let chars = Array(hex.lowercased())
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: chars.count / 2)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    // MARK: - View-sharing liveness (extension → app)

    /// The broadcast extension heartbeats into the shared defaults while it
    /// publishes; the app polls this to drive its "view sharing live"
    /// indicator (no other cross-process signal is available).
    private static let viewHeartbeatKey = "broadcast.viewHeartbeat"

    static func recordViewHeartbeat() {
        defaults.set(Date().timeIntervalSince1970, forKey: viewHeartbeatKey)
    }

    static func clearViewHeartbeat() {
        defaults.removeObject(forKey: viewHeartbeatKey)
    }

    /// True while a heartbeat landed within the last `window` seconds.
    static func isViewSharingActive(window: TimeInterval = 6) -> Bool {
        let last = defaults.double(forKey: viewHeartbeatKey)
        return last > 0 && Date().timeIntervalSince1970 - last < window
    }

    // MARK: - Publish password (app-group keychain)

    /// The publish password lives in a keychain item scoped to the app
    /// group (`kSecAttrAccessGroup`) so the broadcast extension — a separate
    /// process — can read it. Same accessibility tier as `KeychainStore`.
    /// Item attributes; `grouped` selects the app-group access group. The
    /// no-group variant is the fallback for builds without any app-group
    /// entitlement (simulator, stripped re-signs) — app-only, but functional.
    private static func keychainBase(grouped: Bool) -> [String: Any] {
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        if grouped { base[kSecAttrAccessGroup as String] = appGroup }
        return base
    }

    /// Defaults-mirror of the publish password. Cross-process keychain
    /// sharing via app-group access groups is unreliable under sideload
    /// re-signing (the extension reads nil → unauthenticated publish → 401),
    /// so the password is also mirrored into the shared defaults. Keychain
    /// remains the preferred read. Tradeoff: plaintext at rest in the app
    /// group container — acceptable for a LAN/tailnet stream password.
    private static let passwordMirrorKey = "broadcast.publishPassword"

    static func setPassword(_ value: String) {
        defaults.set(value.isEmpty ? nil : value, forKey: passwordMirrorKey)
        for grouped in [true, false] {
            let base = keychainBase(grouped: grouped)
            SecItemDelete(base as CFDictionary)
            guard !value.isEmpty else { continue }
            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            if grouped, status == errSecSuccess {
                // Grouped write worked — drop any stale ungrouped copy and stop.
                SecItemDelete(keychainBase(grouped: false) as CFDictionary)
                return
            }
            if grouped, status != errSecMissingEntitlement { return }
        }
    }

    static func getPassword() -> String? {
        for grouped in [true, false] {
            var query = keychainBase(grouped: grouped)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
               let data = out as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return defaults.string(forKey: passwordMirrorKey)
    }

    /// Server settings as the broadcast extension consumes them.
    /// `viewStream: true` selects the Mirror My View stream path.
    static func serverConfig(viewStream: Bool, password: String?) -> ServerConfig? {
        let d = defaults
        guard let host = d.string(forKey: Keys.host), !host.isEmpty else { return nil }
        let port = d.object(forKey: Keys.port) as? Int ?? 8554
        let path = viewStream
            ? (d.string(forKey: Keys.viewPath) ?? "visionpro-view")
            : (d.string(forKey: Keys.path) ?? "visionpro")
        let username = d.string(forKey: Keys.username)
        let fingerprint = d.string(forKey: Keys.certFingerprint).flatMap(dataFromHex)
        return ServerConfig(
            host: host, port: UInt16(clamping: port), path: path,
            username: (username?.isEmpty ?? true) ? nil : username,
            password: (password?.isEmpty ?? true) ? nil : password,
            bitrateMbps: d.object(forKey: Keys.bitrate) as? Int ?? 10,
            pinnedCertSHA256: fingerprint)
    }
}
