import AppKit
import DebugTrace
import Foundation
import Network

/// Answers one headset's pairing request: a plain TCP listener, advertised as
/// `_longwave-pair._tcp` for that headset only, that runs `PairingExchange`,
/// shows the six-digit code here for the user to compare and approve, and on
/// approval hands over the Companion's token sealed under the agreed key.
///
/// The listener lives only as long as the one exchange, and is gone after two
/// minutes whatever happens.
@MainActor
final class PairingServer {
    struct Context {
        let headsetID: String
        let headsetName: String
        let macID: String
        let macName: String
        let token: String
    }

    /// Fired once, when the exchange is over either way.
    var onFinish: ((_ paired: Bool) -> Void)?

    private let context: Context
    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "Pairing")
    private let queue = DispatchQueue(label: "pro.longwave.companion.pairing")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private let exchange = PairingExchange()
    private var commitment: Data?
    private var finished = false
    private var timeout: Task<Void, Never>?

    init(context: Context) {
        self.context = context
    }

    func start() throws {
        let listener = try NWListener(using: .tcp)
        var txt = NWTXTRecord()
        txt[CompanionDiscovery.Key.macID] = context.macID
        txt[CompanionDiscovery.Key.headsetID] = context.headsetID
        listener.service = NWListener.Service(
            name: "Longwave pairing \(context.headsetID.prefix(8))",
            type: CompanionDiscovery.pairServiceType,
            txtRecord: txt
        )
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    self?.log.error("Pairing listener failed: \(error.localizedDescription)")
                    self?.finish(paired: false)
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.log.info("Pairing timed out")
            self?.finish(paired: false)
        }
    }

    func cancel() {
        finish(paired: false)
    }

    private func accept(_ connection: NWConnection) {
        guard self.connection == nil, !finished else {
            connection.cancel()
            return
        }
        self.connection = connection
        // The record has done its job; nobody else should find it.
        listener?.cancel()
        listener = nil
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.finish(paired: false) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                do {
                    while let message = try PairingMessage.take(from: &self.buffer) {
                        await self.handle(message)
                    }
                } catch {
                    self.log.error("Malformed pairing message")
                    self.finish(paired: false)
                    return
                }
                if isComplete || error != nil {
                    self.finish(paired: false)
                } else if !self.finished {
                    self.receive()
                }
            }
        }
    }

    private func handle(_ message: PairingMessage) async {
        switch message {
        case .commit(let headsetID, _, let commitment):
            guard self.commitment == nil, headsetID == context.headsetID else { return finish(paired: false) }
            self.commitment = commitment
            send(.macHello(macID: context.macID, macName: context.macName,
                           publicKey: exchange.publicKey, nonce: exchange.nonce))
        case .reveal(let publicKey, let nonce):
            guard let commitment, let agreement = PairingExchange.agree(
                mine: exchange, theirPublicKey: publicKey, commitment: commitment,
                headsetPublicKey: publicKey, headsetNonce: nonce,
                macPublicKey: exchange.publicKey, macNonce: exchange.nonce
            ) else {
                log.error("Pairing reveal didn't match its commitment")
                return finish(paired: false)
            }
            guard approve(code: agreement.code) else {
                log.info("Pairing declined")
                send(.deny) { [weak self] in self?.finish(paired: false) }
                return
            }
            let grant = PairingGrant(
                token: context.token, macID: context.macID, macName: context.macName,
                addresses: CompanionPresence.lanAddresses()
            )
            do {
                let sealed = try PairingExchange.seal(grant, with: agreement.key)
                send(.accept(sealedGrant: sealed)) { [weak self] in
                    self?.log.info("Paired a headset")
                    self?.finish(paired: true)
                }
            } catch {
                finish(paired: false)
            }
        case .macHello, .accept, .deny:
            finish(paired: false)
        }
    }

    private func approve(code: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Pair “\(context.headsetName)” with this Mac?"
        alert.informativeText = """
        Check that the headset shows this code:

        \(PairingExchange.display(code))

        Once paired, it can stream this Mac's screen and audio and control it, as you allow in Longwave Companion.
        """
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Don't Pair")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func send(_ message: PairingMessage, then completion: (@MainActor () -> Void)? = nil) {
        guard let connection, let frame = try? message.framed() else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        })
    }

    private func finish(paired: Bool) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        onFinish?(paired)
    }
}
