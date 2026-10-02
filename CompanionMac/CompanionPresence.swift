import DebugTrace
import Foundation
import Network
import SystemConfiguration
import dnssd

/// The Companion's side of `CompanionDiscovery`: announces this Mac on the
/// local network and watches for headsets knocking to connect or pair.
///
/// The announcement is a bare mDNS registration — nothing listens behind it —
/// so having it up costs no open port. Stream ports open only while a paired
/// headset's knock is present (or connections by address are allowed), which
/// the owner reads from `knockActive`.
@Observable
final class CompanionPresence {
    /// A headset asking to pair, by its id and the name it gave.
    struct PairRequest: Equatable {
        let headsetID: String
        let name: String
    }

    /// A paired headset is knocking now, or stopped less than `knockGrace` ago.
    private(set) var knockActive = false
    /// Names of the paired headsets knocking right now, for the status line.
    private(set) var knockingHeadsets: [String] = []
    /// Set when macOS refuses this app local network access, which blocks
    /// both the announcement and seeing headsets knock.
    private(set) var localNetworkDenied = false
    /// Fired for each new pairing request (main actor).
    var onPairRequest: ((PairRequest) -> Void)?
    /// Fired whenever `knockActive` changes (main actor).
    var onKnockChange: (() -> Void)?

    /// The id headsets remember this Mac by. Stable across launches and
    /// independent of the token, so a regenerated token keeps the identity.
    let macID: String = {
        let key = "companionMacID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    var macName: String { Host.current().localizedName ?? "Mac" }

    private static let knockGrace: Duration = .seconds(30)

    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "CompanionPresence")
    private let queue = DispatchQueue(label: "pro.longwave.companion.presence")
    private var token = ""
    private var registration: DNSServiceRef?
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var open = false
    private var validKnocks: [String: String] = [:]   // headset id → name
    private var seenPairRequests: Set<String> = []
    private var graceTask: Task<Void, Never>?
    /// The latest browse results, re-checked as tags age: a headset whose app
    /// was suspended can leave its record behind with a tag that has expired.
    private var lastResults: Set<NWBrowser.Result> = []
    private var recheckTimer: Timer?

    func start(token: String) {
        self.token = token
        register()
        startBrowsing()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateRecord() }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handle(self.lastResults)
            }
        }
    }

    func updateToken(_ token: String) {
        self.token = token
        validKnocks.removeAll()
        browser?.cancel()
        startBrowsing()
    }

    /// Whether the stream ports are listening, so a knocking headset knows
    /// when to connect.
    func setOpen(_ open: Bool) {
        guard open != self.open else { return }
        self.open = open
        updateRecord()
    }

    // MARK: - Announcement

    private func register() {
        let txt = record()
        var ref: DNSServiceRef?
        let status = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &ref, 0, 0, macName, CompanionDiscovery.macServiceType, nil, nil,
                // No socket behind the record; SRV needs a port, so the
                // discard port stands in.
                UInt16(9).bigEndian,
                UInt16(txt.count), bytes.baseAddress,
                { _, _, errorCode, name, _, _, context in
                    // Asynchronous outcome: success, a rename after a name
                    // conflict, or a failure the call itself couldn't report.
                    let logger = DebugLogger(subsystem: "pro.longwave.companion", category: "CompanionPresence")
                    if errorCode == kDNSServiceErr_NoError {
                        logger.info("Announced as \(name.map { String(cString: $0) } ?? "?")")
                    } else {
                        logger.error("Announcement failed (\(errorCode))")
                    }
                    guard let context else { return }
                    let presence = Unmanaged<CompanionPresence>.fromOpaque(context).takeUnretainedValue()
                    let denied = errorCode == kDNSServiceErr_PolicyDenied
                    let failed = errorCode != kDNSServiceErr_NoError
                    Task { @MainActor in presence.registrationFinished(denied: denied, failed: failed) }
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        guard status == kDNSServiceErr_NoError, let ref else {
            log.error("Could not announce this Mac on the local network (\(status))")
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        registration = ref
        log.info("Announcing this Mac to nearby headsets")
    }

    /// After a failure the reference is dead; drop it, and try again a little
    /// later in case access was just granted.
    private func registrationFinished(denied: Bool, failed: Bool) {
        if denied { localNetworkDenied = true }
        if !failed {
            localNetworkDenied = false
            return
        }
        guard let registration else { return }
        nonisolated(unsafe) let ref = registration
        self.registration = nil
        queue.async { DNSServiceRefDeallocate(ref) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.registration == nil else { return }
            self.register()
        }
    }

    private func updateRecord() {
        guard let registration else { return }
        let txt = record()
        // A DNSServiceRef is not thread-safe: calls on it must come from the
        // queue it is scheduled on, or mDNSResponder drops the connection
        // (seen as kDNSServiceErr_ServiceNotRunning) and the record vanishes.
        nonisolated(unsafe) let ref = registration
        queue.async {
            txt.withUnsafeBytes { bytes in
                _ = DNSServiceUpdateRecord(ref, nil, 0, UInt16(txt.count), bytes.baseAddress, 0)
            }
        }
    }

    private func record() -> Data {
        var entries: [String] = [
            "\(CompanionDiscovery.Key.version)=\(CompanionDiscovery.version)",
            "\(CompanionDiscovery.Key.macID)=\(macID)",
            "\(CompanionDiscovery.Key.open)=\(open ? "1" : "0")",
        ]
        let addresses = Self.lanAddresses()
        if !addresses.isEmpty {
            entries.append("\(CompanionDiscovery.Key.addresses)=\(addresses.joined(separator: ","))")
        }
        var data = Data()
        for entry in entries {
            let bytes = Array(entry.utf8.prefix(255))
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    /// This Mac's IPv4 LAN addresses, wired interfaces first: a headset that
    /// can reach both should use the cable.
    static func lanAddresses() -> [String] {
        var wired: Set<String> = []
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces {
                if let type = SCNetworkInterfaceGetInterfaceType(interface),
                   type == kSCNetworkInterfaceTypeEthernet,
                   let name = SCNetworkInterfaceGetBSDName(interface) {
                    wired.insert(name as String)
                }
            }
        }
        var results: [(address: String, wired: Bool)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            // Real LAN interfaces only: not VPN tunnels, bridges or AWDL.
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254.") else { continue }
            results.append((text, wired.contains(name)))
        }
        return results.sorted { $0.wired && !$1.wired }.map(\.address)
    }

    // MARK: - Knocks

    private func startBrowsing() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: CompanionDiscovery.knockServiceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in self?.handle(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.log.error("Watching for headsets failed: \(error.localizedDescription)")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        lastResults = results
        var knocks: [String: String] = [:]
        var pairRequests: Set<String> = []
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  txt[CompanionDiscovery.Key.macID] == macID,
                  let headsetID = txt[CompanionDiscovery.Key.headsetID] else { continue }
            let name = txt[CompanionDiscovery.Key.name] ?? "Vision Pro"
            if txt[CompanionDiscovery.Key.pairRequest] == "1" {
                pairRequests.insert(headsetID)
                if !seenPairRequests.contains(headsetID) {
                    seenPairRequests.insert(headsetID)
                    log.info("Pairing request from a headset")
                    onPairRequest?(PairRequest(headsetID: headsetID, name: name))
                }
            } else if let tag = txt[CompanionDiscovery.Key.tag], !token.isEmpty,
                      CompanionDiscovery.isValidKnock(tag: tag, token: token, macID: macID, headsetID: headsetID) {
                knocks[headsetID] = name
            }
        }
        // A request is answered once per appearance: withdrawn and made again,
        // it asks again.
        seenPairRequests.formIntersection(pairRequests)
        let arrived = Set(knocks.keys).subtracting(validKnocks.keys)
        if !arrived.isEmpty { log.info("\(arrived.count) paired headset(s) knocking") }
        validKnocks = knocks
        knockingHeadsets = knocks.values.sorted()
        if !knocks.isEmpty {
            graceTask?.cancel()
            graceTask = nil
            setKnockActive(true)
        } else if knockActive, graceTask == nil {
            graceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.knockGrace)
                guard let self, !Task.isCancelled else { return }
                self.graceTask = nil
                if self.validKnocks.isEmpty { self.setKnockActive(false) }
            }
        }
    }

    private func setKnockActive(_ active: Bool) {
        guard active != knockActive else { return }
        knockActive = active
        onKnockChange?()
    }
}
