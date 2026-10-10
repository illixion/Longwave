import Foundation
import Network

/// A device carries only its Projects capability. Provider credentials never
/// travel on this connection; the Companion creates and attaches the session.
@MainActor
final class ProjectsClient {
    let access: ProjectsProtocol.Access
    var onTerminalEvent: ((SSHConnection.Event) -> Void)?
    private var channel: ProjectsChannel?
    private var authentication: CheckedContinuation<Void, Error>?
    private var requests: [UUID: CheckedContinuation<ProjectsProtocol.Message, Error>] = [:]
    private var authenticated = false
    private var terminalReady = false

    init(access: ProjectsProtocol.Access) { self.access = access }

    func connect() async throws {
        if channel != nil { disconnect() }
        let connection = NWConnection(host: NWEndpoint.Host(access.host),
            port: NWEndpoint.Port(rawValue: access.port)!,
            using: ProjectsProtocol.parameters(keys: [access.id: access.key]))
        let channel = ProjectsChannel(connection)
        self.channel = channel
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel, self.channel === channel,
                  let binding = ProjectsProtocol.binding(connection) else {
                channel?.close("Projects TLS authentication is unavailable."); return
            }
            channel.send(.init(operation: .authenticate, deviceID: self.access.id,
                version: ProjectsProtocol.version,
                proof: ProjectsProtocol.proof(key: self.access.key, binding: binding)))
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel, self.channel === channel else { return }
            self.receive(message)
        }
        channel.onClose = { [weak self, weak channel] reason in
            guard let self, let channel, self.channel === channel else { return }
            self.failAll(reason ?? "Projects connection closed. Reconnect to continue.")
        }
        try await withCheckedThrowingContinuation { continuation in
            authentication = continuation
            channel.start()
            Task { [weak self, weak channel] in
                try? await Task.sleep(for: .seconds(25))
                guard let self, let channel, self.channel === channel, !self.authenticated else { return }
                channel.close("Projects authentication timed out.")
            }
        }
    }

    func disconnect() {
        let old = channel
        channel = nil
        old?.close()
        failAll("Projects disconnected.")
    }

    func snapshot() async throws -> ProjectsProtocol.Snapshot {
        let response = try await request(.init(operation: .list))
        guard let snapshot = response.snapshot else { throw ProjectsProtocol.Failure("The Companion returned no sandbox status.") }
        return snapshot
    }

    func start(project: String, agent: String) async throws -> ProjectsProtocol.Session {
        let response = try await request(.init(operation: .start, projectID: project, agent: agent))
        guard let session = response.session else { throw ProjectsProtocol.Failure("The Companion returned no session.") }
        return session
    }

    func stop(session: String) async throws {
        _ = try await request(.init(operation: .stop, sessionID: session))
    }

    func ensureDesktop() async throws { _ = try await request(.init(operation: .desktopEnsure), timeout: 210) }

    func attach(session: String, cols: Int, rows: Int) {
        channel?.send(.init(operation: .attach, sessionID: session,
            cols: min(500, max(1, cols)), rows: min(300, max(1, rows))))
    }

    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        guard terminalReady, let channel else { return false }
        for offset in stride(from: 0, to: bytes.count, by: ProjectsProtocol.maximumTerminalChunk) {
            let end = min(bytes.count, offset + ProjectsProtocol.maximumTerminalChunk)
            guard channel.send(.init(operation: .input, bytes: Data(bytes[offset..<end]))) else { return false }
        }
        return true
    }

    func resize(cols: Int, rows: Int) {
        channel?.send(.init(operation: .resize, cols: min(500, max(1, cols)), rows: min(300, max(1, rows))))
    }

    private func request(_ message: ProjectsProtocol.Message, timeout: Double = 60) async throws -> ProjectsProtocol.Message {
        guard authenticated, let channel else { throw ProjectsProtocol.Failure("Connect to the Companion first.") }
        var message = message
        let id = UUID()
        message.requestID = id
        return try await withCheckedThrowingContinuation { continuation in
            requests[id] = continuation
            guard channel.send(message) else {
                requests.removeValue(forKey: id)?.resume(throwing: ProjectsProtocol.Failure("Projects request couldn't be sent."))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.requests.removeValue(forKey: id)?.resume(throwing: ProjectsProtocol.Failure("Projects request timed out. Refresh before trying again."))
            }
        }
    }

    private func receive(_ message: ProjectsProtocol.Message) {
        if message.operation == .authenticated, message.version == ProjectsProtocol.version {
            authenticated = true
            authentication?.resume()
            authentication = nil
            return
        }
        guard authenticated else { channel?.close("Unexpected Projects authentication reply."); return }
        if let id = message.requestID, let request = requests.removeValue(forKey: id) {
            if message.operation == .error { request.resume(throwing: ProjectsProtocol.Failure(message.error ?? "Projects request failed.")) }
            else { request.resume(returning: message) }
            return
        }
        switch message.operation {
        case .ready: terminalReady = true; onTerminalEvent?(.ready)
        case .output:
            if let bytes = message.bytes, bytes.count <= ProjectsProtocol.maximumTerminalChunk { onTerminalEvent?(.output(Array(bytes))) }
        case .closed: terminalReady = false; onTerminalEvent?(.closed(message.error))
        case .error: terminalReady = false; onTerminalEvent?(.failed(message.error ?? "Projects request failed."))
        default: break
        }
    }

    private func failAll(_ reason: String) {
        authenticated = false
        terminalReady = false
        let failure = ProjectsProtocol.Failure(reason)
        authentication?.resume(throwing: failure)
        authentication = nil
        let pending = requests.values
        requests.removeAll()
        for request in pending { request.resume(throwing: failure) }
        onTerminalEvent?(.closed(reason))
    }
}
