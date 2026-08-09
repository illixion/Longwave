import Foundation
import Network
import os

/// Client for the companion text-injection channel. Connects to the macOS
/// companion over TLS-1.2-PSK (`CompanionInjectCrypto`) and sends only literal
/// text and backspace counts — the modifier-safe primitive that lets the VNC
/// keyboard route typing through the Mac without exposing key-code/modifier
/// injection. Off-main worker modeled on the audio/SSH connections; surfaces
/// availability and close through `onEvent`, which the owning
/// `VNCConnectionManager` marshals to the main actor.
final class CompanionInjectClient: @unchecked Sendable {

    struct Config: Sendable {
        let host: String
        let port: UInt16
        let token: String
    }

    enum Event: Sendable {
        /// Companion reported whether it will actually inject right now.
        case available(Bool)
        case closed
    }

    nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?

    private let config: Config
    private let queue = DispatchQueue(label: "pro.longwave.inject.client")
    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var inbound = Data()
    private nonisolated(unsafe) var closed = false
    private let log = Logger(subsystem: "pro.longwave", category: "CompanionInject")

    init(config: Config) {
        self.config = config
    }

    func start() {
        guard !config.token.isEmpty, let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: port,
            using: CompanionInjectCrypto.tlsTCPParameters(token: config.token)
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(CompanionInjectProtocol.encodeFrame(.hello))
                self.receiveLoop()
            case .failed(let error):
                self.log.error("Inject channel failed: \(String(describing: error))")
                self.emitClosed()
            case .cancelled:
                self.emitClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        send(CompanionInjectProtocol.encodeFrame(.injectText, Data(text.utf8)))
    }

    func sendBackspace(_ count: Int) {
        guard count > 0 else { return }
        send(CompanionInjectProtocol.encodeFrame(.injectBackspace, CompanionInjectProtocol.encodeBackspace(count)))
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Private

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 12) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbound.append(data)
                self.processInbound()
            }
            if isComplete || error != nil {
                self.emitClosed()
            } else {
                self.receiveLoop()
            }
        }
    }

    private func processInbound() {
        for frame in CompanionInjectProtocol.drainFrames(&inbound) {
            switch frame.type {
            case CompanionInjectProtocol.FrameType.helloAck.rawValue,
                 CompanionInjectProtocol.FrameType.injectStatus.rawValue:
                let raw = frame.payload.first ?? CompanionInjectProtocol.Status.disabled.rawValue
                onEvent?(.available(raw == CompanionInjectProtocol.Status.available.rawValue))
            default:
                break
            }
        }
    }

    private func emitClosed() {
        if closed { return }
        closed = true
        onEvent?(.closed)
    }
}
