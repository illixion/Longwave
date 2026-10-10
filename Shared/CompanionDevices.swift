import CryptoKit
import Foundation
import Network
import Security

// Per-device Companion access (COMPANION_ENROLLMENT_PLAN.md).
//
// Every pairing mints a token for that one device, and the host keeps which
// features ("grants") the user allowed it in the one-time pairing dialog. Each
// feature still derives its own TLS-PSK from the token with its own salt; the
// PSK identity names the device, so a listener can hold every enrolled device's
// key at once. Because Network.framework can't tell a server which PSK a
// connection used, each connection then *identifies* itself: the device id and
// an HMAC under its token over a TLS exporter value, so a device can neither
// claim another device's grants nor replay the proof on another connection.

/// What a paired device may do. Chosen in the host's pairing dialog, edited in
/// its Devices tab, and enforced by the host on every connection.
nonisolated enum CompanionGrant: String, Codable, CaseIterable, Sendable, Identifiable {
    case screen, audio, input, projects, sshKey
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: "See the screen"
        case .audio: "Hear audio"
        case .input: "Control the Mac (pointer, keys, typing)"
        case .projects: "Run coding agents in the sandbox"
        case .sshKey: "Sign in over SSH as you"
        }
    }

    /// What a pairing asks for unless the device says otherwise, and what the
    /// dialog ticks by default. Projects and SSH are always opt-in.
    static let defaults: Set<CompanionGrant> = [.screen, .audio, .input]

    /// What a device still holding the old shared token is allowed during the
    /// transition: everything the shared token used to unlock, nothing more.
    static let legacy: Set<CompanionGrant> = [.screen, .audio, .input]
}

/// The secret a client presents to a Companion. `deviceID` is nil for the
/// deprecated shared token, which uses the old fixed PSK identities.
nonisolated struct CompanionCredential: Sendable, Equatable, Hashable {
    let token: String
    let deviceID: String?

    init(token: String, deviceID: String?) {
        self.token = token
        self.deviceID = deviceID
    }

    var isLegacy: Bool { deviceID == nil }

    /// `<base>` for the shared token, `<base>/<device id>` for a device token.
    func pskIdentity(base: String) -> Data {
        Data((deviceID.map { "\(base)/\($0)" } ?? base).utf8)
    }

    /// 256-bit URL-safe token, the same shape the shared token always had.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A connection's first message: who it is, bound to this TLS session.
nonisolated struct CompanionIdentify: Codable, Sendable, Equatable {
    /// Nil: the deprecated shared token.
    var deviceID: String?
    var proof: Data

    /// Per-feature exporter labels, so a proof made for one channel is useless
    /// on another.
    enum Channel: String, Sendable {
        case native = "EXPORTER-Longwave-Native-Device-v1"
        case audio = "EXPORTER-Longwave-Audio-Device-v1"
        case inject = "EXPORTER-Longwave-Inject-Device-v1"
    }

    static func make(_ credential: CompanionCredential, channel: Channel, connection: NWConnection) -> CompanionIdentify? {
        guard let binding = binding(connection, channel: channel) else { return nil }
        return CompanionIdentify(deviceID: credential.deviceID, proof: proof(token: credential.token, binding: binding))
    }

    static func binding(_ connection: NWConnection, channel: Channel) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let label = channel.rawValue
        guard let secret = label.withCString({
            sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, $0, 32)
        }) else { return nil }
        return Data(secret as DispatchData)
    }

    static func proof(token: String, binding: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: binding, using: proofKey(token)))
    }

    static func validates(_ proof: Data, token: String, binding: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: binding, using: proofKey(token))
    }

    private static func proofKey(_ token: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
                               salt: Data("Longwave-Device-Proof-v1".utf8), info: Data(), outputByteCount: 32)
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ data: Data) -> CompanionIdentify? { try? JSONDecoder().decode(Self.self, from: data) }
}

/// The host's current set of enrolled devices, as its servers read it: from
/// their own queues, so it's a lock-protected snapshot rather than an actor.
nonisolated final class CompanionKeyring: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let credential: CompanionCredential
        let grants: Set<CompanionGrant>
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    init(_ entries: [Entry] = []) { self.entries = entries }

    func replace(_ entries: [Entry]) {
        lock.lock(); defer { lock.unlock() }
        self.entries = entries
    }

    /// Every credential a listener should accept.
    var credentials: [CompanionCredential] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.credential)
    }

    /// Enrolled devices holding a grant (the watch lane tries each one's key).
    func entries(with grant: CompanionGrant) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.grants.contains(grant) }
    }

    func entry(deviceID: String?) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.credential.deviceID == deviceID }
    }

    /// Checks a connection's identify message. Returns the entry it proves.
    func verify(_ identify: CompanionIdentify, binding: Data) -> Entry? {
        guard let entry = entry(deviceID: identify.deviceID),
              CompanionIdentify.validates(identify.proof, token: entry.credential.token, binding: binding) else { return nil }
        return entry
    }

    /// Whether this device (nil: the shared token) is still enrolled with the grant.
    func allows(_ deviceID: String?, _ grant: CompanionGrant) -> Bool {
        entry(deviceID: deviceID)?.grants.contains(grant) == true
    }
}

/// TLS-PSK options shared by the Companion channels: one PSK per credential,
/// TLS 1.2 PSK-AES128-GCM-SHA256 as before.
nonisolated enum CompanionPSK {
    static let ciphersuite = tls_ciphersuite_t(rawValue: 0x00A8)!

    static func derive(token: String, salt: Data, info: Data) -> DispatchData {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
                                         salt: salt, info: info, outputByteCount: 32)
        return key.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    static func add(_ credentials: [CompanionCredential], to options: sec_protocol_options_t,
                    identityBase: String, salt: Data, info: Data) {
        for credential in credentials {
            let identity = credential.pskIdentity(base: identityBase)
            sec_protocol_options_add_pre_shared_key(
                options,
                derive(token: credential.token, salt: salt, info: info) as __DispatchData,
                identity.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
            )
        }
    }
}

/// The address hint the Mac AirDrops (or copies) to a headset that can't see
/// it over Bonjour: the Mac's id, name and every address it has, and the port
/// its direct pairing listener uses. **It carries no secret** — anyone could
/// write one, and it grants nothing. The headset tries each address and runs
/// the normal six-digit pairing over the first that answers.
///
///   longwave://pair?mac=<id>&name=<name>&port=4859&addr=192.168.1.5&addr=100.64.0.3
nonisolated struct CompanionPairLink: Equatable, Sendable {
    static let action = "pair"
    /// The direct pairing listener, between the stream ports and Projects.
    static let defaultPort: UInt16 = 4859

    var macID: String
    var name: String
    var port: UInt16 = CompanionPairLink.defaultPort
    var addresses: [String]

    var url: URL? {
        var components = URLComponents()
        components.scheme = "longwave"
        components.host = Self.action
        components.queryItems = [
            URLQueryItem(name: "mac", value: macID),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "port", value: String(port)),
        ] + addresses.map { URLQueryItem(name: "addr", value: $0) }
        return components.url
    }

    init(macID: String, name: String, port: UInt16 = CompanionPairLink.defaultPort, addresses: [String]) {
        self.macID = macID
        self.name = name
        self.port = port
        self.addresses = addresses
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "longwave", url.host?.lowercased() == Self.action,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let mac = items.first(where: { $0.name == "mac" })?.value, !mac.isEmpty, mac.count <= 64 else { return nil }
        let addresses = items.filter { $0.name == "addr" }.compactMap(\.value)
            .filter { !$0.isEmpty && $0.count < 64 }.prefix(12)
        guard !addresses.isEmpty else { return nil }
        self.macID = mac
        self.name = String((items.first { $0.name == "name" }?.value ?? "Mac").prefix(80))
        self.port = items.first { $0.name == "port" }?.value.flatMap(UInt16.init) ?? Self.defaultPort
        self.addresses = Array(addresses)
    }
}
