import DebugTrace
import Foundation
import Network

/// Remote sandbox access is a grant on a paired device (`CompanionGrant.projects`),
/// chosen in the pairing dialog or the Devices tab. The listener holds only the
/// keys of devices holding it; no other channel's connection is accepted here.
/// Secrets and launches stay in Companion.
@Observable
@MainActor
final class CompanionProjectsServer {
    private(set) var listening = false
    var error: String?
    private let sandbox: LocalSandboxController
    private let devices: CompanionDeviceRegistry
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var keys: [UUID: String] = [:]
    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "ProjectsServer")

    init(sandbox: LocalSandboxController, devices: CompanionDeviceRegistry) {
        self.sandbox = sandbox
        self.devices = devices
        devices.observe { [weak self] in self?.restartListener() }
        restartListener()
    }

    /// Devices allowed Projects right now.
    var allowedDevices: [CompanionDevice] { devices.devices.filter { $0.grants.contains(.projects) } }

    private func restartListener() {
        let newKeys = Dictionary(uniqueKeysWithValues: devices.keyring.entries(with: .projects).compactMap { entry in
            entry.credential.deviceID.flatMap(UUID.init(uuidString:)).map { ($0, entry.credential.token) }
        })
        // Another device's change doesn't concern the sessions running here.
        guard newKeys != keys || (listener == nil && !newKeys.isEmpty) else { return }
        listener?.cancel()
        listener = nil
        listening = false
        let oldPeers = Array(peers.values)
        peers.removeAll()
        for peer in oldPeers { peer.channel.close("Projects access changed. Reconnect to continue.") }
        keys = newKeys
        guard !keys.isEmpty else { return }
        do {
            let listener = try NWListener(using: ProjectsProtocol.parameters(keys: keys), on: NWEndpoint.Port(rawValue: ProjectsProtocol.port)!)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready: self.listening = true; self.error = nil
                    case .failed(let error): self.listening = false; self.error = error.localizedDescription
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        } catch { self.error = error.localizedDescription }
    }

    private func accept(_ connection: NWConnection) {
        guard peers.count < 24 else { connection.cancel(); return }
        let peer = Peer(connection)
        peers[peer.id] = peer
        peer.channel.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.receive(message, from: peer)
        }
        peer.channel.onClose = { [weak self, weak peer] _ in
            guard let self, let peer else { return }
            peer.terminal?.close()
            peer.terminal = nil
            self.peers.removeValue(forKey: peer.id)
        }
        peer.channel.start()
        Task { [weak peer] in
            try? await Task.sleep(for: .seconds(25))
            guard let peer, peer.deviceID == nil else { return }
            peer.channel.close("Projects authentication timed out.")
        }
    }

    private func receive(_ message: ProjectsProtocol.Message, from peer: Peer) {
        guard peer.deviceID != nil else {
            guard message.operation == .authenticate, message.version == ProjectsProtocol.version,
                  let id = message.deviceID, let key = keys[id], let proof = message.proof,
                  let binding = ProjectsProtocol.binding(peer.channel.connection),
                  ProjectsProtocol.validates(proof, key: key, binding: binding) else {
                peer.channel.close("Projects authentication failed.")
                return
            }
            peer.deviceID = id
            peer.channel.send(.init(operation: .authenticated, version: ProjectsProtocol.version))
            return
        }
        switch message.operation {
        case .input:
            guard let bytes = message.bytes, bytes.count <= ProjectsProtocol.maximumTerminalChunk,
                  peer.terminal?.send(Array(bytes)) == true else { fail(message, peer, "Terminal isn't ready."); return }
        case .resize:
            guard let cols = message.cols, let rows = message.rows, (1...500).contains(cols), (1...300).contains(rows) else {
                fail(message, peer, "Invalid terminal size."); return
            }
            peer.terminal?.resize(cols: cols, rows: rows)
        case .list, .start, .attach, .stop, .desktopEnsure:
            guard !peer.busy else { fail(message, peer, "A Projects request is already running."); return }
            peer.busy = true
            Task { [weak self, weak peer] in
                guard let self, let peer else { return }
                defer { peer.busy = false }
                do { try await self.handle(message, peer) }
                catch { self.fail(message, peer, error.localizedDescription) }
            }
        default: fail(message, peer, "Unsupported Projects operation.")
        }
    }

    private func handle(_ message: ProjectsProtocol.Message, _ peer: Peer) async throws {
        // Every await can outlive revocation; revalidate the peer before acting.
        guard authorized(peer) else { return }
        log.info("Projects request \(message.operation.rawValue, privacy: .public) from device \(peer.deviceID?.uuidString ?? "", privacy: .private(mask: .hash))")
        await sandbox.refresh()
        guard authorized(peer) else { return }
        switch message.operation {
        case .list:
            peer.channel.send(.init(operation: .snapshot, requestID: message.requestID, snapshot: snapshot()))
        case .start:
            guard sandbox.availability == .ready, let projectID = message.projectID,
                  let project = sandbox.projects.first(where: { $0.id == projectID }),
                  let raw = message.agent, let agent = SSHAgent(rawValue: raw), agent != .custom else {
                throw ProjectsProtocol.Failure("Choose an imported project and a supported agent.")
            }
            guard sandbox.account.hasToken(for: agent) else { throw ProjectsProtocol.Failure("Sign in to \(agent.displayName) in the Companion's Projects window first.") }
            let name = try await sandbox.createSession(project, agent: agent)
            guard authorized(peer) else { return }
            guard let session = sandbox.sessions.first(where: { $0.name == name }) else {
                throw ProjectsProtocol.Failure("The agent ended before its session could be opened.")
            }
            peer.channel.send(.init(operation: .started, requestID: message.requestID, session: wire(session)))
        case .attach:
            guard let name = message.sessionID, sandbox.sessions.contains(where: { $0.name == name }) else {
                throw ProjectsProtocol.Failure("This sandbox session has ended. Refresh the session list.")
            }
            let cols = message.cols ?? 80, rows = message.rows ?? 24
            guard (1...500).contains(cols), (1...300).contains(rows) else { throw ProjectsProtocol.Failure("Invalid terminal size.") }
            peer.terminal?.close()
            let terminal = try sandbox.terminalConnection(session: name, cols: cols, rows: rows)
            peer.terminal = terminal
            terminal.onEvent = { [weak peer, weak terminal] event in
                Task { @MainActor [weak peer, weak terminal] in
                    guard let peer, let terminal, peer.terminal === terminal else { return }
                    switch event {
                    case .ready: peer.channel.send(.init(operation: .ready))
                    case .output(let bytes):
                        for offset in stride(from: 0, to: bytes.count, by: ProjectsProtocol.maximumTerminalChunk) {
                            let end = min(bytes.count, offset + ProjectsProtocol.maximumTerminalChunk)
                            peer.channel.send(.init(operation: .output, bytes: Data(bytes[offset..<end])))
                        }
                    case .closed(let reason): peer.channel.send(.init(operation: .closed, error: reason))
                    case .failed(let reason): peer.channel.send(.init(operation: .closed, error: reason))
                    }
                }
            }
            terminal.start()
        case .stop:
            guard let name = message.sessionID, let session = sandbox.sessions.first(where: { $0.name == name }) else {
                throw ProjectsProtocol.Failure("This sandbox session has already ended.")
            }
            await sandbox.stopSession(session)
            guard authorized(peer) else { return }
            peer.channel.send(.init(operation: .snapshot, requestID: message.requestID, snapshot: snapshot()))
        case .desktopEnsure:
            guard sandbox.busy == nil else { throw ProjectsProtocol.Failure("The sandbox is busy.") }
            guard sandbox.desktop != .loggingIn else { throw ProjectsProtocol.Failure("A sandbox desktop login is already in progress.") }
            await sandbox.ensureDesktopSession(force: true)
            guard authorized(peer) else { return }
            guard sandbox.status?.guiSession == true else { throw ProjectsProtocol.Failure("The sandbox desktop couldn't log in. Check Projects on the Mac.") }
            peer.channel.send(.init(operation: .snapshot, requestID: message.requestID, snapshot: snapshot()))
        default: throw ProjectsProtocol.Failure("Unsupported Projects request.")
        }
    }

    private func authorized(_ peer: Peer) -> Bool {
        peers[peer.id] === peer && peer.deviceID.flatMap { keys[$0] } != nil
    }

    private func fail(_ message: ProjectsProtocol.Message, _ peer: Peer, _ reason: String) {
        peer.channel.send(.init(operation: .error, requestID: message.requestID, error: reason))
    }

    private func wire(_ session: DiscoveredAgentSession) -> ProjectsProtocol.Session {
        .init(id: session.name, title: session.title, folder: session.folder)
    }

    private func snapshot() -> ProjectsProtocol.Snapshot {
        .init(account: sandbox.agentUser, available: sandbox.availability == .ready,
            desktopRunning: sandbox.status?.guiSession == true,
            projects: sandbox.projects.map { .init(id: $0.id, name: $0.displayName) },
            sessions: sandbox.sessions.map(wire),
            configuredAgents: SSHAgent.allCases.filter { sandbox.account.hasToken(for: $0) }.map(\.rawValue))
    }

    private final class Peer {
        let id = UUID()
        let channel: ProjectsChannel
        var deviceID: UUID?
        var terminal: SSHConnection?
        var busy = false
        init(_ connection: NWConnection) { channel = ProjectsChannel(connection) }
    }
}
