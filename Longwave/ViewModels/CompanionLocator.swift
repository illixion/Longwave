import DebugTrace
import Foundation
import Network
import Observation

/// The headset's side of `CompanionDiscovery`: finds Companions on the local
/// network and knocks for a paired one's ports.
///
/// A knock is a Bonjour record this device advertises while it wants a Mac —
/// a listener that accepts nothing, there only to carry the record. Callers
/// keep it alive by renewing a lease (`renewKnock`), so it goes away by itself
/// once nothing is streaming from that Mac, and the Mac closes its ports.
@MainActor
@Observable
final class CompanionLocator {
    static let shared = CompanionLocator()

    struct NearbyMac: Identifiable, Equatable {
        var id: String { macID }
        let macID: String
        let name: String
        let addresses: [String]
        let open: Bool
    }

    /// Companions announcing themselves on this network, while browsing.
    private(set) var nearby: [NearbyMac] = []

    /// This device's identity towards Companions. Stable, random, and not
    /// tied to anything else about the device.
    nonisolated static let headsetID: String = {
        let key = "longwaveHeadsetID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private let log = AppLog.companionDiscovery
    private var browser: NWBrowser?
    private var browseClients = 0
    private var knocks: [String: Knock] = [:]
    private var leaseTimer: Timer?

    private final class Knock {
        let listener: NWListener
        let token: String?
        var leaseUntil: Date
        var lastMinute: Int64 = .min
        init(listener: NWListener, token: String?, leaseUntil: Date) {
            self.listener = listener
            self.token = token
            self.leaseUntil = leaseUntil
        }
    }

    private static let lease: TimeInterval = 90

    // MARK: - Browsing

    /// Starts watching for Companions; balanced by `stopBrowsing`.
    func startBrowsing() {
        browseClients += 1
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: CompanionDiscovery.macServiceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    self?.log.log("Browsing for Macs failed: \(error.localizedDescription)")
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browseClients = max(0, browseClients - 1)
        guard browseClients == 0 else { return }
        browser?.cancel()
        browser = nil
        nearby = []
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var macs: [String: NearbyMac] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  let macID = txt[CompanionDiscovery.Key.macID] else { continue }
            var name = "Mac"
            if case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName }
            let addresses = (txt[CompanionDiscovery.Key.addresses] ?? "")
                .split(separator: ",").map(String.init)
            let mac = NearbyMac(
                macID: macID, name: name, addresses: addresses,
                open: txt[CompanionDiscovery.Key.open] == "1"
            )
            // The same record arrives once per interface; keep the fullest.
            if let existing = macs[macID], existing.addresses.count >= addresses.count, existing.open || !mac.open {
                continue
            }
            macs[macID] = mac
        }
        nearby = macs.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Locating a paired Mac

    /// Knocks for a paired Mac and waits for it to open its ports. Returns the
    /// LAN address to connect to, or nil when the Mac isn't on this network
    /// (the caller then uses the address it was saved with).
    ///
    /// Waits up to 1.5 s for the Mac's record to appear — away from home it
    /// never will, and that wait is all connecting by address costs — then up
    /// to 3 s in all for the Mac to say its ports are open.
    func locate(macID: String, token: String) async -> String? {
        renewKnock(macID: macID, token: token)
        startBrowsing()
        defer { stopBrowsing() }
        let start = ContinuousClock.now
        var seen: NearbyMac?
        while true {
            let elapsed = ContinuousClock.now - start
            if let mac = nearby.first(where: { $0.macID == macID }) {
                seen = mac
                if mac.open || elapsed > .seconds(3) { break }
            } else if elapsed > .milliseconds(1500) {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let seen else {
            log.log("Paired Mac not found nearby; using its saved address")
            return nil
        }
        if !seen.open {
            log.log("Paired Mac found but hasn't opened its ports yet")
        }
        return seen.addresses.first
    }

    /// Keeps knocking for `macID` for another `lease` seconds. Callers renew
    /// while they stream; the knock is withdrawn once nobody has for a while.
    func renewKnock(macID: String, token: String) {
        let until = Date().addingTimeInterval(Self.lease)
        if let knock = knocks[macID], knock.token != nil {
            knock.leaseUntil = until
            return
        }
        startKnock(macID: macID, token: token, until: until)
    }

    /// Withdraws the knock for `macID` now.
    func endKnock(macID: String) {
        knocks.removeValue(forKey: macID)?.listener.cancel()
    }

    /// Advertises a pairing request to `macID` until `endKnock`.
    func requestPairing(macID: String) {
        endKnock(macID: macID)
        startKnock(macID: macID, token: nil, until: .distantFuture)
    }

    private func startKnock(macID: String, token: String?, until: Date) {
        endKnock(macID: macID)
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            log.log("Could not knock: \(error.localizedDescription)")
            return
        }
        listener.newConnectionHandler = { $0.cancel() }
        let knock = Knock(listener: listener, token: token, leaseUntil: until)
        knocks[macID] = knock
        refreshRecord(knock, macID: macID)
        listener.start(queue: .main)
        ensureLeaseTimer()
    }

    /// The record names the Mac it is for and carries a tag that expires
    /// within minutes, so it's re-issued as the minute turns.
    private func refreshRecord(_ knock: Knock, macID: String) {
        let minute = CompanionDiscovery.minute(of: Date())
        guard minute != knock.lastMinute else { return }
        knock.lastMinute = minute
        var txt = NWTXTRecord()
        txt[CompanionDiscovery.Key.version] = CompanionDiscovery.version
        txt[CompanionDiscovery.Key.macID] = macID
        txt[CompanionDiscovery.Key.headsetID] = Self.headsetID
        txt[CompanionDiscovery.Key.name] = DeviceName.current
        if let token = knock.token {
            txt[CompanionDiscovery.Key.tag] = CompanionDiscovery.knockTag(
                token: token, macID: macID, headsetID: Self.headsetID, minute: minute
            )
        } else {
            txt[CompanionDiscovery.Key.pairRequest] = "1"
        }
        knock.listener.service = NWListener.Service(
            name: "Longwave \(Self.headsetID.prefix(6)) \(macID.prefix(6))",
            type: CompanionDiscovery.knockServiceType,
            txtRecord: txt
        )
    }

    private func ensureLeaseTimer() {
        guard leaseTimer == nil else { return }
        leaseTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickLeases() }
        }
    }

    private func tickLeases() {
        let now = Date()
        for (macID, knock) in knocks {
            if now > knock.leaseUntil {
                endKnock(macID: macID)
            } else {
                refreshRecord(knock, macID: macID)
            }
        }
        if knocks.isEmpty {
            leaseTimer?.invalidate()
            leaseTimer = nil
        }
    }
}
