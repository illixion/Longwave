//  FoveatedHostInfo.swift
//
//  Asks the PC how the immersive space should be opened, before opening it.
//
//  Immersion cannot be decided after the fact. The space is created as the session
//  comes up, and restyling a live one does not work: measured on device, the
//  Digital Crown force-fades to zero and the space arrives in a style that
//  disagrees with what was asked for. Worse, a space that opens `.mixed` against a
//  stream with no alpha channel composites transparency that is not there and the
//  wearer gets a black void. So the PC — which is the side that decides whether an
//  alpha channel is encoded at all — publishes the answer, and the headset reads it
//  before it connects.
//
//  Two routes, because there are two ways to arrive:
//
//  - **Discovered.** The host puts the style in a TXT key on the same
//    `_apple-foveated-streaming._tcp` advertisement the system picker uses. The app
//    has to browse for it itself: `FoveatedStreamingSession.Endpoint.systemDiscovered`
//    is opaque and hands back no name, address or metadata for the host the picker
//    resolved, so there is nothing to read off the session.
//  - **By IP.** No advertisement was involved, so the host also answers a plain
//    HTTP GET on the session port + 1.
//
//  Both are best-effort with a short deadline. Failing to get an answer is not an
//  error worth blocking a session for — it falls back to progressive, which is the
//  half of the choice that degrades gracefully: an opaque stream in a portal looks
//  right, where transparency composited against nothing does not.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import Network
import os

enum FoveatedHostInfo {
    /// TXT keys and the service type, mirroring `ProtocolConstants` on the host.
    private enum Wire {
        static let serviceType = "_apple-foveated-streaming._tcp"
    }

    /// How long to wait for a discovery step. Five seconds, not the two it started as:
    /// a cold Bonjour browse on device is routinely slower than a warm one on a Mac, and
    /// the cost of being impatient here is not a slow connect — it is silently opening in
    /// the wrong immersion, which is far more expensive than waiting.
    private static let deadline: Duration = .seconds(5)

    private static let log = Logger(subsystem: "pro.longwave", category: "FoveatedHostInfo")

    /// Where the PC was last reached, so discovery failing once does not mean starting
    /// from nothing. Bonjour is the fragile step in the chain — a browse that comes back
    /// empty is indistinguishable from having no PC — and the address of a machine that
    /// answered a minute ago is the best guess available.
    private static let lastAddressKey = "pcvr.hostInfo.lastAddress"
    private static let lastPortKey = "pcvr.hostInfo.lastPort"

    private static var lastKnownHost: DiscoveredHost? {
        get {
            let defaults = UserDefaults.standard
            guard let address = defaults.string(forKey: lastAddressKey) else { return nil }
            let port = defaults.integer(forKey: lastPortKey)
            return port > 0 ? DiscoveredHost(address: address, port: port) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.address, forKey: lastAddressKey)
            UserDefaults.standard.set(newValue?.port ?? 0, forKey: lastPortKey)
        }
    }

    /// How the last answer was obtained, for the tab to report. Guessing wrong about
    /// immersion is the failure that keeps recurring, so it is worth being able to see
    /// which route answered rather than inferring it from the result.
    enum Source: String {
        case address = "the address you typed"
        case discovered = "a PC found on the network"
        case remembered = "the PC's last known address"
        case none = "nothing"
    }

    private(set) static var lastSource: Source = .none

    /// The style the PC wants, or nil when nothing answered in time.
    static func immersionStyle(for connection: SavedConnection) async -> FoveatedImmersionStyle? {
        var style: FoveatedImmersionStyle?
        switch connection.foveatedConnectionMode {
        case .local:
            let host = connection.hostname.trimmingCharacters(in: .whitespaces)
            style = host.isEmpty ? nil : await overHTTP(host: host, sessionPort: connection.port)
            if style != nil {
                lastSource = .address
                lastKnownHost = DiscoveredHost(address: host, port: connection.port)
            }
        case .systemDiscovered:
            style = await overBonjour()
            if style != nil { lastSource = .discovered }
        }

        /* Discovery failing is not the same as the PC being gone, and the difference
           matters: an empty browse silently opens progressive against a host serving
           mixed, and — worse — makes a reconnect give up on a PC that is merely
           restarting. So fall back to wherever it answered last. */
        if style == nil, let remembered = lastKnownHost {
            style = await overHTTP(host: remembered.address, sessionPort: remembered.port)
            if style != nil {
                lastSource = .remembered
                log.notice("Discovery found nothing; the PC answered at its last known address.")
            }
        }
        if style == nil { lastSource = .none }

        log.notice("Host immersion: \(style?.rawValue ?? "unknown — falling back", privacy: .public) via \(lastSource.rawValue, privacy: .public)")
        return style
    }

    /// Wait until the PC answers at all, whatever it answers.
    ///
    /// Used to time an automatic reconnect after a drop. The interesting case is the PC
    /// restarting on purpose — to apply a passthrough change, say — which takes long
    /// enough that a fixed pause always guessed wrong. Returns false on timeout, and the
    /// caller reconnects anyway: being wrong about *when* is recoverable, refusing to try
    /// is not.
    static func waitForHost(_ connection: SavedConnection, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if await immersionStyle(for: connection) != nil { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    // MARK: By IP

    private static func overHTTP(host: String, sessionPort: Int) async -> FoveatedImmersionStyle? {
        await fetch(host: host, sessionPort: sessionPort)?.style
    }

    /// Read the host's state. Read-only on purpose: the mode is the PC's to set, and the
    /// headset only ever asks what it is. The endpoint can also take a change request, and
    /// the host currently refuses those — see `AllowClientChanges` there.
    static func fetch(host: String, sessionPort: Int) async -> Payload? {
        // Bracketed for IPv6 literals, which URLComponents will not accept bare.
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(authority):\(sessionPort + 1)/info") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            log.notice("Host info over HTTP failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The host's answer. More fields are decoded than are used, deliberately: they are
    /// the wire contract, and the ones about a pending change are what a future
    /// headset-side toggle would need (the host can already take such a request and
    /// currently refuses it — see `AllowClientChanges` there).
    struct Payload: Decodable {
        /// What the **running** stack is serving, and so the only value safe to open a
        /// session with: it is fixed when the host starts, because that is when the alpha
        /// channel and the blend mode were decided.
        let immersion: String
        let passthrough: Bool?
        /// Asked for but not yet picked up, or nil when they agree. Never connect on this
        /// — until the PC restarts, nothing is serving it.
        let pendingImmersion: String?
        let restartRequired: Bool?
        /// Version of the setting, bumped by whichever side changes it.
        let iteration: Int?
        let name: String?
        let applied: Bool?
        let rejected: String?

        var style: FoveatedImmersionStyle? { FoveatedImmersionStyle(rawValue: immersion) }
    }

    // MARK: Discovered

    /// Browse for hosts, then **ask each one over HTTP**.
    ///
    /// The TXT record carries the same answer and reading it would be one step
    /// shorter, but mDNS records are cached: after the PC restarts PCVR with the
    /// switch flipped, a resolver can still hand back the record from before the
    /// restart, and the headset opens in the style the PC used to want. Observed
    /// exactly that — the host advertising `mixed` while the headset kept choosing
    /// progressive. So discovery is used for the one thing that does not go stale
    /// (where the PC is) and the state itself is always fetched live.
    ///
    /// With more than one PC advertising there is no way to tell which the person
    /// picked — the system picker does not say — so the answer is only used when
    /// every host that answers agrees. Two hosts configured differently means an
    /// honest "don't know" and the safe fallback, rather than a coin flip that
    /// leaves half of those sessions staring at a black void.
    private static func overBonjour() async -> FoveatedImmersionStyle? {
        let hosts = await discoverHosts()
        guard !hosts.isEmpty else { return nil }

        var answers: [FoveatedImmersionStyle] = []
        for host in hosts {
            if let style = await overHTTP(host: host.address, sessionPort: host.port) {
                answers.append(style)
            }
        }
        guard let first = answers.first else { return nil }
        guard answers.allSatisfy({ $0 == first }) else { return nil }
        if hosts.count == 1 { lastKnownHost = hosts.first }
        return first
    }

    private struct DiscoveredHost {
        let address: String
        let port: Int
    }

    /// Browse, then resolve each result to an address by opening a connection to it
    /// and reading back the endpoint the system actually picked. `NWBrowser` hands
    /// out service names, not addresses, and there is no lighter way to turn one
    /// into the other.
    private static func discoverHosts() async -> [DiscoveredHost] {
        let endpoints = await browseEndpoints()
        var hosts: [DiscoveredHost] = []
        for endpoint in endpoints {
            if let resolved = await resolve(endpoint) { hosts.append(resolved) }
        }
        return hosts
    }

    private static func browseEndpoints() async -> [NWEndpoint] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[NWEndpoint], Never>) in
            let browser = NWBrowser(for: .bonjour(type: Wire.serviceType, domain: nil), using: .tcp)
            // `resume` exactly once, whichever of "results arrived" and "time is up"
            // happens first — a continuation resumed twice is a crash, and a browser
            // that never answers would otherwise hang the connect button forever.
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ found: [NWEndpoint]) {
                let alreadyDone = finished.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyDone else { return }
                browser.cancel()
                continuation.resume(returning: found)
            }

            browser.browseResultsChangedHandler = { results, _ in
                let endpoints = results.map(\.endpoint)
                guard !endpoints.isEmpty else { return }
                finish(endpoints)
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish([]) }
            }
            browser.start(queue: .global(qos: .userInitiated))

            Task {
                try? await Task.sleep(for: deadline)
                finish([])
            }
        }
    }

    /// Turn a Bonjour service endpoint into an address, by connecting to it and asking
    /// the path what it resolved to. The connection is cancelled the moment it is
    /// ready — the point is the address, not the socket.
    private static func resolve(_ endpoint: NWEndpoint) async -> DiscoveredHost? {
        await withCheckedContinuation { (continuation: CheckedContinuation<DiscoveredHost?, Never>) in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ host: DiscoveredHost?) {
                let alreadyDone = finished.withLock { done -> Bool in
                    defer { done = true }
                    return done
                }
                guard !alreadyDone else { return }
                connection.cancel()
                continuation.resume(returning: host)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(hostAndPort(of: connection.currentPath?.remoteEndpoint))
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            Task {
                try? await Task.sleep(for: deadline)
                finish(nil)
            }
        }
    }

    private static func hostAndPort(of endpoint: NWEndpoint?) -> DiscoveredHost? {
        guard case .hostPort(let host, let port) = endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        // Network prints scoped addresses as "192.168.1.20%en0"; the zone is meaningless
        // to URLSession and makes the URL unparseable.
        let bare = text.split(separator: "%").first.map(String.init) ?? text
        return DiscoveredHost(address: bare, port: Int(port.rawValue))
    }
}
#endif
