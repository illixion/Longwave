import Network
import XCTest
@testable import Longwave

/// Per-device Companion access (`CompanionDevices.swift`): the address link,
/// the keyring's grants, and — over real TLS — that a listener holding several
/// devices' keys learns which device connected and nobody can claim another.
final class CompanionDevicesTests: XCTestCase {

    // MARK: Address link

    func testPairLinkRoundTripsAndCarriesNoSecret() throws {
        let link = CompanionPairLink(macID: "MAC-1", name: "Studio Mac", addresses: ["192.168.1.5", "100.64.0.3"])
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(CompanionPairLink(url: url), link)
        let query = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        XCTAssertEqual(query, ["mac", "name", "port", "addr"], "the link holds only where the Mac is, never a key")
    }

    func testPairLinkRejectsOtherURLsAndEmptyAddressLists() {
        XCTAssertNil(CompanionPairLink(url: URL(string: "longwave://pair?mac=M")!))
        XCTAssertNil(CompanionPairLink(url: URL(string: "longwave://x-callback-url/setAudioToken?token=t")!))
        XCTAssertNil(CompanionPairLink(url: URL(string: "https://pair?mac=M&addr=1.2.3.4")!))
    }

    // MARK: Keyring

    func testKeyringGrantsAndLegacyEntry() {
        let device = CompanionCredential(token: "device-token", deviceID: "HS-1")
        let legacy = CompanionCredential(token: "shared-token", deviceID: nil)
        let keyring = CompanionKeyring([
            .init(credential: device, grants: [.screen]),
            .init(credential: legacy, grants: CompanionGrant.legacy),
        ])
        XCTAssertTrue(keyring.allows("HS-1", .screen))
        XCTAssertFalse(keyring.allows("HS-1", .projects))
        XCTAssertTrue(keyring.allows(nil, .input), "the shared token keeps what it always unlocked")
        XCTAssertFalse(keyring.allows(nil, .projects))
        XCTAssertFalse(keyring.allows("HS-2", .screen))
        XCTAssertEqual(keyring.entries(with: .audio).map(\.credential), [legacy])
    }

    func testIdentityNamesTheDevice() {
        XCTAssertEqual(CompanionCredential(token: "t", deviceID: "HS").pskIdentity(base: "LongwaveAudio/v5"),
                       Data("LongwaveAudio/v5/HS".utf8))
        XCTAssertEqual(CompanionCredential(token: "t", deviceID: nil).pskIdentity(base: "LongwaveAudio/v5"),
                       Data("LongwaveAudio/v5".utf8), "the shared token keeps the old fixed identity")
    }

    // MARK: Real TLS

    /// A listener holding two devices' keys (and the shared token's) accepts
    /// each, and each connection's identify proof names exactly its device:
    /// replaying it on another connection, or claiming another device, fails.
    func testListenerWithSeveralDeviceKeysIdentifiesEachConnection() async throws {
        let a = CompanionCredential(token: CompanionCredential.generateToken(), deviceID: "HS-A")
        let b = CompanionCredential(token: CompanionCredential.generateToken(), deviceID: "HS-B")
        let legacy = CompanionCredential(token: CompanionCredential.generateToken(), deviceID: nil)
        let keyring = CompanionKeyring([
            .init(credential: a, grants: [.screen]),
            .init(credential: b, grants: [.audio]),
            .init(credential: legacy, grants: CompanionGrant.legacy),
        ])
        let listener = try NWListener(using: MacNativeStreamCrypto.tlsTCPParameters(credentials: keyring.credentials), on: .any)
        var verified: [String?] = []
        var bindings: [Data] = []
        var accepted: [NWConnection] = []
        defer { listener.cancel(); accepted.forEach { $0.cancel() } }
        listener.newConnectionHandler = { connection in
            accepted.append(connection)
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard let data, let identity = CompanionIdentify.decode(data),
                          let binding = CompanionIdentify.binding(connection, channel: .native) else { return }
                    let entry = keyring.verify(identity, binding: binding)
                    DispatchQueue.main.async {
                        bindings.append(binding)
                        verified.append(entry.map { $0.credential.deviceID } ?? "rejected")
                    }
                }
            }
            connection.start(queue: .main)
        }
        listener.start(queue: .main)
        for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let port = try XCTUnwrap(listener.port)

        /// Connects as `credential`, then sends the identify message `make` builds.
        func connect(_ credential: CompanionCredential,
                     make: @escaping (NWConnection) -> CompanionIdentify?) async throws {
            let connection = NWConnection(host: "127.0.0.1", port: port,
                                          using: MacNativeStreamCrypto.tlsTCPParameters(credentials: [credential]))
            let expected = verified.count + 1
            connection.stateUpdateHandler = { state in
                guard case .ready = state, let identity = make(connection) else { return }
                connection.send(content: identity.encoded(), completion: .contentProcessed { _ in })
            }
            connection.start(queue: .main)
            defer { connection.cancel() }
            for _ in 0..<150 where verified.count < expected { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(verified.count, expected)
        }

        try await connect(a) { CompanionIdentify.make(a, channel: .native, connection: $0) }
        try await connect(b) { CompanionIdentify.make(b, channel: .native, connection: $0) }
        try await connect(legacy) { CompanionIdentify.make(legacy, channel: .native, connection: $0) }
        // B's key, claiming to be A: the proof can't be made without A's token.
        try await connect(b) { connection in
            CompanionIdentify.binding(connection, channel: .native).map {
                CompanionIdentify(deviceID: "HS-A", proof: CompanionIdentify.proof(token: b.token, binding: $0))
            }
        }
        // A proof for another channel's exporter label doesn't verify here.
        try await connect(a) { CompanionIdentify.make(a, channel: .audio, connection: $0) }

        XCTAssertEqual(verified, ["HS-A", "HS-B", nil, "rejected", "rejected"])
        guard bindings.count == 5 else { return }
        let replay = CompanionIdentify(deviceID: "HS-A", proof: CompanionIdentify.proof(token: a.token, binding: bindings[0]))
        XCTAssertNil(keyring.verify(replay, binding: bindings[4]), "a proof is bound to its own TLS session")
    }

    func testDeviceKeyNotOnTheListenerFailsTheHandshake() async throws {
        let enrolled = CompanionCredential(token: CompanionCredential.generateToken(), deviceID: "HS-A")
        let revoked = CompanionCredential(token: CompanionCredential.generateToken(), deviceID: "HS-B")
        let listener = try NWListener(using: AudioCrypto.tlsTCPParameters(credentials: [enrolled]), on: .any)
        defer { listener.cancel() }
        listener.newConnectionHandler = { $0.start(queue: .main) }
        listener.start(queue: .main)
        for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port),
                                      using: AudioCrypto.tlsTCPParameters(credentials: [revoked]))
        defer { connection.cancel() }
        let failed = expectation(description: "handshake refused")
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .waiting: failed.fulfill(); connection.stateUpdateHandler = nil
            case .ready: XCTFail("a key the listener doesn't hold must not get in")
            default: break
            }
        }
        connection.start(queue: .main)
        await fulfillment(of: [failed], timeout: 5)
    }
}
