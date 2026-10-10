import Foundation
import Network
import Observation

/// Pairs this device with a Companion: knocks with a pairing request and finds
/// the listener the Mac opens for it — or, from an address link, dials the
/// Mac's direct pairing port on each address in turn — then runs
/// `PairingExchange`, shows the code for the user to compare, and hands back
/// the device's own token and what the user allowed it, once they approve on
/// the Mac.
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

    private enum Target {
        case nearby(CompanionLocator.NearbyMac)
        case direct(CompanionPairLink)
    }

    private let target: Target
    private let requested: Set<CompanionGrant>
    private let sshPublicKey: String?
    /// The address the exchange ran over, for a direct pairing.
    private(set) var connectedAddress: String?
    private var remainingAddresses: [String] = []
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private let exchange = PairingExchange()
    private var commitment = Data()
    private var agreement: PairingExchange.Agreement?
    private var timeout: Task<Void, Never>?

    private var macID: String {
        switch target {
        case .nearby(let mac): mac.macID
        case .direct(let link): link.macID
        }
    }

    /// - Parameter requested: what to ask the Mac for; its dialog starts from
    ///   these and the user decides.
    /// - Parameter sshPublicKey: this device's SSH key, offered when the user
    ///   wants SSH login as well; the Mac adds it only if allowed.
    init(mac: CompanionLocator.NearbyMac, requested: Set<CompanionGrant> = CompanionGrant.defaults,
         sshPublicKey: String? = nil) {
        self.target = .nearby(mac)
        self.requested = requested
        self.sshPublicKey = sshPublicKey
    }

    init(link: CompanionPairLink, requested: Set<CompanionGrant> = CompanionGrant.defaults,
         sshPublicKey: String? = nil) {
        self.target = .direct(link)
        self.requested = requested
        self.sshPublicKey = sshPublicKey
    }

    func start() {
        guard state == .idle else { return }
        state = .waitingForMac
        commitment = PairingExchange.commitment(publicKey: exchange.publicKey, nonce: exchange.nonce)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.fail("The Mac didn't answer. Check that Longwave Companion is running and allowed on the local network.")
        }
        switch target {
        case .nearby:
            startNearby()
        case .direct(let link):
            remainingAddresses = link.addresses
            dialNext(port: link.port)
        }
    }

    /// Tries the link's addresses one at a time; the first that answers runs
    /// the exchange.
    private func dialNext(port: UInt16) {
        guard !remainingAddresses.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            return fail("None of the Mac's addresses answered. Check that Longwave Companion is running there and that the link is less than ten minutes old.")
        }
        let address = remainingAddresses.removeFirst()
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let connection = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.connectedAddress = address
                    self.sendCommit()
                    self.receive()
                case .failed, .waiting:
                    guard self.agreement == nil else {
                        return self.fail("Lost the Mac while pairing.")
                    }
                    connection.cancel()
                    self.connection = nil
                    self.dialNext(port: port)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func sendCommit() {
        send(.commit(
            headsetID: CompanionLocator.headsetID,
            headsetName: DeviceName.current,
            commitment: commitment,
            requested: requested.sorted { $0.rawValue < $1.rawValue },
            sshPublicKey: sshPublicKey
        ))
    }

    private func startNearby() {
        CompanionLocator.shared.requestPairing(macID: macID)

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: CompanionDiscovery.pairServiceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in self?.found(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
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
            return txt[CompanionDiscovery.Key.macID] == macID
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
                    self.sendCommit()
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
            // A typed address names no host id up front: the first answer is it.
            guard self.macID.isEmpty || macID == self.macID, let agreement = PairingExchange.agree(
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
        if case .nearby = target { CompanionLocator.shared.endKnock(macID: macID) }
    }
}
