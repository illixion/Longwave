import Foundation
import Network

/// Bounded JSON framing shared by the Projects client and Companion. All
/// callbacks/state are main-actor confined; Network receives on the main queue.
@MainActor
final class ProjectsChannel {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((ProjectsProtocol.Message) -> Void)?
    var onClose: ((String?) -> Void)?
    private var inbound = Data()
    private var pendingBytes = 0
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                switch state {
                case .ready: self.onReady?(); self.receive()
                case .failed(let error): self.close(error.localizedDescription)
                case .cancelled: self.close(nil)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        // Bounds an unauthenticated/failed handshake, including an unreachable Mac.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !self.closed, self.connection.state != .ready else { return }
            self.close("Projects connection timed out.")
        }
    }

    @discardableResult
    func send(_ message: ProjectsProtocol.Message) -> Bool {
        guard !closed else { return false }
        do {
            let data = try ProjectsProtocol.frame(message)
            guard pendingBytes + data.count <= 1024 * 1024 else {
                close("Projects connection can't keep up with terminal output.")
                return false
            }
            pendingBytes += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pendingBytes -= data.count
                    if let error { self.close(error.localizedDescription) }
                }
            })
            return true
        } catch { close(error.localizedDescription); return false }
    }

    func close(_ reason: String? = nil) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        inbound.removeAll()
        onClose?(reason)
        onMessage = nil
        onReady = nil
        onClose = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                do {
                    if let data {
                        self.inbound.append(data)
                        for message in try ProjectsProtocol.drain(&self.inbound) {
                            guard !self.closed else { break }
                            self.onMessage?(message)
                        }
                    }
                    if let error { self.close(error.localizedDescription) }
                    else if complete { self.close(nil) }
                    else if !self.closed { self.receive() }
                } catch { self.close("Invalid Projects message.") }
            }
        }
    }
}
