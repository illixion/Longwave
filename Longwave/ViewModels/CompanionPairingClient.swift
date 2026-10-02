import Foundation
import Network
import Observation

/// Pairs this device with a Companion nearby: knocks with a pairing request,
/// finds the listener the Mac opens for it, runs `PairingExchange`, shows the
/// code for the user to compare, and hands back the Mac's grant once the user
/// approves on the Mac.
@MainActor
@Observable
final class CompanionPairingClient {
    enum State: Equatable {
        case idle
        case waitingForMac
        /// The six digits to compare with the Mac's screen.
        case confirming(code: String)
        case paired(PairingGrant)
        case failed(String)
    }

    private(set) var state: State = .idle

    private let mac: CompanionLocator.NearbyMac
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private let exchange = PairingExchange()
    private var commitment = Data()
    private var agreement: PairingExchange.Agreement?
    private var timeout: Task<Void, Never>?

    init(mac: CompanionLocator.NearbyMac) {
        self.mac = mac
    }

    func start() {
        guard state == .idle else { return }
        state = .waitingForMac
        commitment = PairingExchange.commitment(publicKey: exchange.publicKey, nonce: exchange.nonce)
        CompanionLocator.shared.requestPairing(macID: mac.macID)

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: CompanionDiscovery.pairServiceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in self?.found(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.fail("The Mac didn't answer. Check that Longwave Companion is running and allowed on the local network.")
        }
    }

    func cancel() {
        finish()
        if case .paired = state { return }
        state = .idle
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        guard connection == nil else { return }
        let match = results.first { result in
            guard case .bonjour(let txt) = result.metadata else { return false }
            return txt[CompanionDiscovery.Key.macID] == mac.macID
                && txt[CompanionDiscovery.Key.headsetID] == CompanionLocator.headsetID
        }
        guard let match else { return }
        browser?.cancel()
        browser = nil
        let connection = NWConnection(to: match.endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(.commit(
                        headsetID: CompanionLocator.headsetID,
                        headsetName: DeviceName.current,
                        commitment: self.commitment
                    ))
                    self.receive()
                case .failed(let error):
                    self.fail("Lost the Mac while pairing: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                do {
                    while let message = try PairingMessage.take(from: &self.buffer) {
                        self.handle(message)
                    }
                } catch {
                    return self.fail("The Mac sent something unexpected.")
                }
                if isComplete || error != nil {
                    if case .paired = self.state { return }
                    self.fail("The Mac closed the connection.")
                } else if self.connection != nil {
                    self.receive()
                }
            }
        }
    }

    private func handle(_ message: PairingMessage) {
        switch message {
        case .macHello(let macID, _, let publicKey, let nonce):
            guard macID == mac.macID, let agreement = PairingExchange.agree(
                mine: exchange, theirPublicKey: publicKey, commitment: commitment,
                headsetPublicKey: exchange.publicKey, headsetNonce: exchange.nonce,
                macPublicKey: publicKey, macNonce: nonce
            ) else {
                return fail("The Mac's reply didn't check out.")
            }
            self.agreement = agreement
            send(.reveal(publicKey: exchange.publicKey, nonce: exchange.nonce))
            state = .confirming(code: agreement.code)
        case .accept(let sealed):
            guard let agreement, let grant = try? PairingExchange.open(sealed, with: agreement.key) else {
                return fail("The Mac's answer couldn't be opened.")
            }
            state = .paired(grant)
            finish()
        case .deny:
            fail("Pairing was declined on the Mac.")
        case .commit, .reveal:
            fail("The Mac sent something unexpected.")
        }
    }

    private func send(_ message: PairingMessage) {
        guard let connection, let frame = try? message.framed() else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func fail(_ reason: String) {
        guard state != .idle else { return }
        if case .paired = state { return }
        finish()
        state = .failed(reason)
    }

    private func finish() {
        timeout?.cancel()
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        CompanionLocator.shared.endKnock(macID: mac.macID)
    }
}
