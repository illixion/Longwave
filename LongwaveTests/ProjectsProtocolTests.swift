import Network
import XCTest
@testable import Longwave

@MainActor
final class ProjectsProtocolTests: XCTestCase {
    func testFragmentedAndCoalescedFramesRetainTheIncompleteTail() throws {
        let first = try ProjectsProtocol.frame(.init(operation: .list, requestID: UUID()))
        let second = try ProjectsProtocol.frame(.init(operation: .resize, cols: 120, rows: 40))
        var buffer = Data(first.prefix(2))
        XCTAssertTrue(try ProjectsProtocol.drain(&buffer).isEmpty)
        buffer.append(first.dropFirst(2))
        buffer.append(second.prefix(7))
        XCTAssertEqual(try ProjectsProtocol.drain(&buffer).map(\.operation), [.list])
        XCTAssertEqual(buffer, Data(second.prefix(7)))
        buffer.append(second.dropFirst(7))
        let messages = try ProjectsProtocol.drain(&buffer)
        XCTAssertEqual(messages.first?.cols, 120)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testInvalidLengthsAndMalformedJSONFailClosed() {
        for bytes: [UInt8] in [[0, 0, 0, 0], [255, 255, 255, 255], [0, 0, 0, 1, 123]] {
            var buffer = Data(bytes)
            XCTAssertThrowsError(try ProjectsProtocol.drain(&buffer))
        }
    }

    /// Real TLS/Network.framework, with a data-only server. This catches PSK
    /// interoperability and exporter behavior that pure crypto tests cannot.
    func testSeparateDeviceKeysAndReconnectUseDistinctTLSBindings() async throws {
        let a = UUID(), b = UUID()
        let keys = [a: Data(repeating: 0x41, count: 32).base64EncodedString(),
                    b: Data(repeating: 0x42, count: 32).base64EncodedString()]
        let listener = try NWListener(using: ProjectsProtocol.parameters(keys: keys), on: .any)
        var channels: [ProjectsChannel] = []
        var bindings: [Data] = []
        var revoked: Set<UUID> = []
        var latestSize: (Int?, Int?) = (nil, nil)
        defer { listener.cancel(); for channel in channels { channel.close() } }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let channel = ProjectsChannel(connection)
                channels.append(channel)
                channel.onMessage = { message in
                    guard let id = message.deviceID, !revoked.contains(id), let key = keys[id], let proof = message.proof,
                          let binding = ProjectsProtocol.binding(connection),
                          ProjectsProtocol.validates(proof, key: key, binding: binding) else {
                        channel.close("Denied"); return
                    }
                    bindings.append(binding)
                    channel.send(.init(operation: .authenticated, version: ProjectsProtocol.version))
                    channel.onMessage = { request in
                        switch request.operation {
                        case .list:
                            channel.send(.init(operation: .snapshot, requestID: request.requestID,
                                snapshot: .init(account: "test-agent", available: true, desktopRunning: false,
                                    projects: [], sessions: [], configuredAgents: [])))
                        case .attach: channel.send(.init(operation: .ready))
                        case .input: channel.send(.init(operation: .output, bytes: request.bytes))
                        case .resize: latestSize = (request.cols, request.rows)
                        default: break
                        }
                    }
                }
                channel.start()
            }
        }
        listener.start(queue: .main)
        for _ in 0..<100 where (listener.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let port = try XCTUnwrap(listener.port?.rawValue)
        XCTAssertGreaterThan(port, 0)
        for id in [a, b, a] {
            let client = ProjectsClient(access: .init(id: id, name: "test", host: "127.0.0.1", port: port, key: keys[id]!))
            defer { client.disconnect() }
            try await client.connect()
            let snapshot = try await client.snapshot()
            XCTAssertEqual(snapshot.account, "test-agent")
            let output = expectation(description: "Large terminal paste returns intact")
            let paste = [UInt8](repeating: 0x78, count: 50_000)
            var received = Data()
            client.onTerminalEvent = { event in
                switch event {
                case .ready:
                    client.resize(cols: 132, rows: 54)
                    XCTAssertTrue(client.send(paste))
                case .output(let bytes):
                    received.append(contentsOf: bytes)
                    if received.count == paste.count { output.fulfill() }
                default: break
                }
            }
            client.attach(session: "test-session", cols: 80, rows: 24)
            await fulfillment(of: [output], timeout: 5)
            XCTAssertEqual(received, Data(paste))
            XCTAssertEqual(latestSize.0, 132)
            XCTAssertEqual(latestSize.1, 54)
            client.onTerminalEvent = nil
        }
        XCTAssertEqual(bindings.count, 3)
        guard bindings.count == 3 else { return }
        XCTAssertNotEqual(bindings[0], bindings[2])
        let proof = ProjectsProtocol.proof(key: keys[a]!, binding: bindings[0])
        XCTAssertFalse(ProjectsProtocol.validates(proof, key: keys[a]!, binding: bindings[2]), "a proof cannot be replayed on another connection")
        XCTAssertFalse(ProjectsProtocol.validates(proof, key: keys[b]!, binding: bindings[0]), "one device cannot claim another grant")
        revoked.insert(b)
        let revokedClient = ProjectsClient(access: .init(id: b, name: "revoked", host: "127.0.0.1", port: port, key: keys[b]!))
        defer { revokedClient.disconnect() }
        do { try await revokedClient.connect(); XCTFail("A revoked grant must be rejected even with its old key") }
        catch { /* Authentication is denied before any RPC/terminal operation. */ }
    }
}
