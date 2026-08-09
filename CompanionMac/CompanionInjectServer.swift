import Foundation
import Network
import os

/// TLS-1.2-PSK TCP server for the text-injection channel (port 4856 by
/// default), independent of the audio server — its own queue, single client
/// (newest wins), and it never touches the audio path's client-count
/// bookkeeping. Loopback connections are rejected: the legitimate client is
/// always the remote Vision Pro, so a localhost peer would be a confused-deputy
/// attempt by another Mac process. Inbound `injectText`/`injectBackspace`
/// frames are surfaced via callbacks; the server replies to `hello` (and
/// availability changes) with the current `Status`.
final class CompanionInjectServer: @unchecked Sendable {

    nonisolated(unsafe) var onInjectText: (@Sendable (String) -> Void)?
    nonisolated(unsafe) var onInjectBackspace: (@Sendable (Int) -> Void)?

    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "pro.longwave.companion.inject", qos: .userInitiated)
    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var client: NWConnection?
    private nonisolated(unsafe) var inbound = Data()
    private nonisolated(unsafe) var availability = CompanionInjectProtocol.Status.disabled.rawValue
    private let log = Logger(subsystem: "pro.longwave.companion", category: "CompanionInjectServer")

    nonisolated init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    nonisolated func start() throws {
        let listener = try NWListener(
            using: CompanionInjectCrypto.tlsTCPParameters(token: token),
            on: NWEndpoint.Port(rawValue: port)!
        )
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        log.info("Inject server listening on \(self.port)")
    }

    nonisolated func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            client?.cancel()
            client = nil
            inbound.removeAll()
        }
    }

    /// Publishes a new availability `Status` (toggle flipped / Accessibility
    /// changed): cached for the next `hello`, and pushed to a live client.
    nonisolated func setAvailability(_ status: UInt8) {
        queue.async { [self] in
            availability = status
            guard let client else { return }
            client.send(content: CompanionInjectProtocol.encodeFrame(.injectStatus, Data([status])),
                        completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private nonisolated func accept(_ connection: NWConnection) {
        guard !isLoopback(connection) else {
            log.error("Rejected loopback inject connection")
            connection.cancel()
            return
        }
        client?.cancel()
        inbound.removeAll()
        client = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("Inject client ready")
                self.client?.send(
                    content: CompanionInjectProtocol.encodeFrame(.helloAck, Data([self.availability])),
                    completion: .contentProcessed { _ in })
            case .failed(let error):
                self.log.error("Inject client failed: \(String(describing: error))")
                self.remove(connection)
            case .cancelled:
                self.remove(connection)
            default:
                break
            }
        }
        receiveLoop(connection)
        connection.start(queue: queue)
    }

    private nonisolated func remove(_ connection: NWConnection) {
        guard client === connection else { return }
        connection.cancel()
        client = nil
        inbound.removeAll()
    }

    private nonisolated func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 12) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbound.append(data)
                self.processInbound(connection)
            }
            if isComplete || error != nil {
                self.remove(connection)
            } else {
                self.receiveLoop(connection)
            }
        }
    }

    private nonisolated func processInbound(_ connection: NWConnection) {
        guard client === connection else { return }
        for frame in CompanionInjectProtocol.drainFrames(&inbound) {
            switch frame.type {
            case CompanionInjectProtocol.FrameType.injectText.rawValue:
                if let text = String(data: frame.payload, encoding: .utf8), !text.isEmpty {
                    onInjectText?(text)
                }
            case CompanionInjectProtocol.FrameType.injectBackspace.rawValue:
                if let count = CompanionInjectProtocol.decodeBackspace(frame.payload), count > 0 {
                    onInjectBackspace?(count)
                }
            case CompanionInjectProtocol.FrameType.hello.rawValue:
                connection.send(
                    content: CompanionInjectProtocol.encodeFrame(.helloAck, Data([availability])),
                    completion: .contentProcessed { _ in })
            default:
                break // keepAlive and unknown types ignored
            }
        }
    }

    /// True when the peer is on the loopback interface (another local process),
    /// which is never the legitimate remote Vision Pro client.
    private nonisolated func isLoopback(_ connection: NWConnection) -> Bool {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }
}
