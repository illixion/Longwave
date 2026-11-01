import Foundation
#if canImport(RAVECompanion)
import Network
import RAVECompanion
#endif

// Per-device Companion access (COMPANION_ENROLLMENT_PLAN.md). The mechanism
// (credentials, identify proofs, keyring, TLS-PSK channels, the address link)
// is RAVESDK's `RAVECompanion` since 2026-11-01; Longwave keeps its grants
// and its names for the rest here.
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

#if canImport(RAVECompanion)
/// The secret a client presents to a Companion. `deviceID` is nil for the
/// deprecated shared token, which uses the old fixed PSK identities.
typealias CompanionCredential = RAVECompanionCredential

/// A connection's first message: who it is, bound to this TLS session.
typealias CompanionIdentify = RAVECompanionIdentify

extension RAVECompanionIdentify {
    /// Per-feature exporter labels, so a proof made for one channel is useless
    /// on another.
    enum Channel: String, Sendable {
        case native = "EXPORTER-Longwave-Native-Device-v1"
        case audio = "EXPORTER-Longwave-Audio-Device-v1"
        case inject = "EXPORTER-Longwave-Inject-Device-v1"
    }

    nonisolated static func make(_ credential: CompanionCredential, channel: Channel, connection: NWConnection) -> CompanionIdentify? {
        make(CompanionDiscovery.namespace, credential: credential, exporterLabel: channel.rawValue, connection: connection)
    }

    nonisolated static func binding(_ connection: NWConnection, channel: Channel) -> Data? {
        binding(connection, exporterLabel: channel.rawValue)
    }

    nonisolated static func proof(token: String, binding: Data) -> Data {
        proof(CompanionDiscovery.namespace, token: token, binding: binding)
    }
}

/// The host's current set of enrolled devices, with Longwave's grants.
typealias CompanionKeyring = RAVECompanionKeyring<CompanionGrant>

extension RAVECompanionKeyring where Grant == CompanionGrant {
    nonisolated convenience init(_ entries: [Entry] = []) {
        self.init(CompanionDiscovery.namespace, entries: entries)
    }
}

/// The address hint the Mac AirDrops (or copies) to a headset that can't see
/// it over Bonjour. **It carries no secret** — anyone could write one, and it
/// grants nothing.
///
///   longwave://pair?mac=<id>&name=<name>&port=4859&addr=192.168.1.5&addr=100.64.0.3
typealias CompanionPairLink = RAVECompanionPairLink

extension RAVECompanionPairLink {
    /// The direct pairing listener, between the stream ports and Projects.
    nonisolated static var defaultPort: UInt16 { CompanionDiscovery.namespace.defaultPairPort }

    nonisolated init(macID: String, name: String, port: UInt16 = CompanionPairLink.defaultPort, addresses: [String]) {
        self.init(CompanionDiscovery.namespace, macID: macID, name: name, port: port, addresses: addresses)
    }

    nonisolated init?(url: URL) {
        self.init(CompanionDiscovery.namespace, url: url)
    }
}
#else
/// The watch (watchOS, which RAVESDK doesn't build for) only carries an
/// identity inside the native hello (`MacNativeStreamProtocol`): the same
/// fields and JSON as `RAVECompanionIdentify`, with nothing to make or check one.
nonisolated struct CompanionIdentify: Codable, Sendable, Equatable {
    var deviceID: String?
    var proof: Data
}
#endif
