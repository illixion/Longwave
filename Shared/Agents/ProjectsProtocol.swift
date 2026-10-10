import CryptoKit
import Foundation
import Network
import Security

/// The sandbox control plane. No provider credential, owner path or shell command
/// is a field in this protocol. Access comes from pairing: the device's own
/// token, accepted only while the Companion grants it `projects`.
nonisolated enum ProjectsProtocol {
    static let port: UInt16 = 4860
    static let version = 1
    static let maximumFrame = 256 * 1024
    static let maximumTerminalChunk = 16 * 1024

    /// Where and as whom a device reaches a Companion's Projects service: the
    /// paired Companion's address and this device's own pairing token. The
    /// host only accepts it while the device holds the `projects` grant.
    struct Access: Sendable, Equatable {
        /// This device's id towards the Companion (its pairing identity).
        let id: UUID
        var name: String
        var host: String
        var port: UInt16 = ProjectsProtocol.port
        let key: String
    }

    struct Project: Codable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    struct Session: Codable, Identifiable, Sendable {
        let id: String
        let title: String
        let folder: String
    }

    struct Snapshot: Codable, Sendable {
        let account: String
        let available: Bool
        let desktopRunning: Bool
        let projects: [Project]
        let sessions: [Session]
        let configuredAgents: [String]
    }

    enum Operation: String, Codable, Sendable {
        case authenticate, authenticated, list, snapshot, start, started, attach
        case input, resize, output, ready, closed, stop, desktopEnsure, error
    }

    struct Message: Codable, Sendable {
        var operation: Operation
        var requestID: UUID?
        var deviceID: UUID?
        var version: Int?
        var proof: Data?
        var projectID: String?
        var agent: String?
        var session: Session?
        var sessionID: String?
        var cols: Int?
        var rows: Int?
        var bytes: Data?
        var snapshot: Snapshot?
        var error: String?
    }

    struct Failure: LocalizedError, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func frame(_ message: Message) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard !body.isEmpty, body.count <= maximumFrame else { throw Failure("Projects message is too large.") }
        var length = UInt32(body.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(body)
        return data
    }

    static func drain(_ buffer: inout Data) throws -> [Message] {
        var messages: [Message] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= maximumFrame else { throw Failure("Invalid Projects frame length.") }
            guard buffer.count >= length + 4 else { break }
            messages.append(try JSONDecoder().decode(Message.self, from: buffer.subdata(in: 4..<(4 + length))))
            buffer = Data(buffer.dropFirst(length + 4))
        }
        return messages
    }

    static func parameters(keys: [UUID: String]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (id, secret) in keys {
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
                salt: Data("Longwave-Projects-PSK-v1".utf8), info: Data(id.uuidString.utf8), outputByteCount: 32)
            let raw = key.withUnsafeBytes { Data($0) }
            sec_protocol_options_add_pre_shared_key(options, dispatch(raw), dispatch(Data(id.uuidString.utf8)))
        }
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00A8)!)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        return NWParameters(tls: tls, tcp: tcp)
    }

    private static func dispatch(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }

    /// Binds the claimed device to the authenticated TLS connection. Even when
    /// the listener offers several keys, a peer cannot claim another grant.
    static func binding(_ connection: NWConnection) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let label = "EXPORTER-Longwave-Projects-v1"
        guard let secret = label.withCString({ sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, $0, 32) }) else { return nil }
        return Data(secret as DispatchData)
    }

    static func proof(key: String, binding: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: binding, using: SymmetricKey(data: Data(key.utf8))))
    }

    static func validates(_ proof: Data, key: String, binding: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: binding, using: SymmetricKey(data: Data(key.utf8)))
    }
}
