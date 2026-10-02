import AppKit
import DebugTrace
import Foundation
import Network
import os

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

    enum Outcome {
        case paired
        /// The user chose Don't Pair.
        case declined
        /// The user chose to stop being asked for a while.
        case silenced
        /// Timed out, abandoned or malformed — no answer from the user.
        case abandoned
    }

    /// Fired once, when the exchange is over either way.
    var onFinish: ((Outcome) -> Void)?

    private let context: Context
    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "Pairing")
    private let queue = DispatchQueue(label: "pro.longwave.companion.pairing")
    private var listener: NWListener?
    private var connection: NWConnection?
    private let exchange = PairingExchange()
    private var commitment: Data?
    private var finished = false
    private var timeout: Task<Void, Never>?
    private var alertShowing = false
    /// Set from the network queue the moment the peer goes away — readable
    /// while the prompt's modal loop has the main actor tied up.
    private nonisolated let lost = OSAllocatedUnfairLock(initialState: false)
    /// Bytes received, filled on the network queue, drained on the main actor.
    private nonisolated let inbox = OSAllocatedUnfairLock(initialState: Data())
    private var draining = false
    private let startedAt = ContinuousClock.now

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
                    self?.finish(.abandoned)
                }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.log.info("Pairing timed out")
            self?.finish(.abandoned)
        }
    }

    func cancel() {
        finish(.abandoned)
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
        let lost = self.lost
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                lost.withLock { $0 = true }
                Task { @MainActor [weak self] in self?.finish(.abandoned) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        guard let connection else { return }
        Self.receiveLoop(connection, inbox: inbox, lost: lost) { [weak self] in
            Task { @MainActor [weak self] in await self?.drain() }
        }
    }

    /// Keeps reading on the network queue whatever the main actor is doing,
    /// so a peer that hangs up during the prompt is noticed during the prompt.
    private nonisolated static func receiveLoop(
        _ connection: NWConnection,
        inbox: OSAllocatedUnfairLock<Data>,
        lost: OSAllocatedUnfairLock<Bool>,
        onData: @escaping @Sendable () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            if let data { inbox.withLock { $0.append(data) } }
            let ended = isComplete || error != nil
            if ended { lost.withLock { $0 = true } }
            onData()
            if !ended { receiveLoop(connection, inbox: inbox, lost: lost, onData: onData) }
        }
    }

    private func drain() async {
        guard !draining, !finished else { return }
        draining = true
        defer { draining = false }
        while !finished {
            let message: PairingMessage?
            do {
                message = try inbox.withLock { try PairingMessage.take(from: &$0) }
            } catch {
                log.error("Malformed pairing message")
                return finish(.abandoned)
            }
            guard let message else { break }
            await handle(message)
        }
        if lost.withLock({ $0 }) { finish(.abandoned) }
    }

    private func handle(_ message: PairingMessage) async {
        switch message {
        case .commit(let headsetID, _, let commitment):
            guard self.commitment == nil, headsetID == context.headsetID else { return finish(.abandoned) }
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
                return finish(.abandoned)
            }
            let answer = approve(code: agreement.code)
            guard answer == .paired else {
                log.info("Pairing not approved")
                send(.deny) { [weak self] in self?.finish(answer) }
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
                    self?.finish(.paired)
                }
            } catch {
                finish(.abandoned)
            }
        case .macHello, .accept, .deny:
            finish(.abandoned)
        }
    }

    /// Asks the user. The prompt closes itself (as abandoned) if the
    /// requesting device goes away while it's up, so nothing that merely
    /// started a pairing can leave a dialog behind.
    private func approve(code: String) -> Outcome {
        let alert = NSAlert()
        alert.messageText = "Pair “\(context.headsetName)” with this Mac?"
        alert.informativeText = """
        Check that the headset shows this code:

        \(PairingExchange.display(code))

        Once paired, it can stream this Mac's screen and audio and control it, as you allow in Longwave Companion.
        """
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Don't Pair")
        alert.addButton(withTitle: "Stop Asking for an Hour")
        NSApp.activate(ignoringOtherApps: true)
        alertShowing = true
        // The modal loop runs only modal-panel run loop work, so this timer is
        // what notices a vanished peer or the overall timeout meanwhile.
        let lost = self.lost
        let deadline = startedAt + .seconds(120)
        let watchdog = Timer(timeInterval: 0.25, repeats: true) { _ in
            if lost.withLock({ $0 }) || ContinuousClock.now > deadline {
                NSApp.abortModal()
            }
        }
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        defer {
            watchdog.invalidate()
            alertShowing = false
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return lost.withLock({ $0 }) ? .abandoned : .paired
        case .alertSecondButtonReturn: return .declined
        case .alertThirdButtonReturn: return .silenced
        default: return .abandoned
        }
    }

    private func send(_ message: PairingMessage, then completion: (@MainActor () -> Void)? = nil) {
        guard let connection, let frame = try? message.framed() else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        })
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        if alertShowing { NSApp.abortModal() }
        timeout?.cancel()
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        onFinish?(outcome)
    }
}
