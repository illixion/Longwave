//  BridgeControlLink.swift
//
//  The TCP link that carries everything on the bridge except hand tracking: the
//  game library's requests and replies, the perf feed (0x0C), alignment telemetry
//  (0x07), haptic pulses (0x02) and debug tuning (0x08). Poses stay on UDP :9520,
//  where 83 Hz of latest-wins state belongs and a lost packet is replaced 12 ms
//  later.
//
//  This replaces `GameLibraryLink`, which ran the library over UDP :9522 and shared
//  the return path with everything else on :9521. Three things were wrong with that,
//  all of them observed on device rather than reasoned about:
//
//    - **The HUD paused for seconds at a time.** A dropped datagram in a 10 Hz feed
//      is a visible stall, and a frozen HUD cannot be told apart from a dead
//      transport. TCP retransmits.
//    - **The return path could vanish silently.** `NWListener` does not throw for a
//      port already in use, so a lost race against the previous listener's
//      asynchronous `cancel()` killed haptics, telemetry, perf and library replies
//      for a whole session while input kept flowing. A TCP client binds nothing.
//    - **Chunked replies could not tolerate loss.** A cover is ~24 chunks and a gap
//      fails the whole response, so cover art was a coin flip on a busy network.
//
//  It also deletes the endpoint probe. The host announces several addresses because
//  it cannot know which one this headset can reach (LAN, its own hotspot, a
//  tailnet); a TCP connect that completes *is* the answer, so there is no need to
//  send speculative requests and wait to see which one comes back.
//
//  Framing: a 4-byte little-endian length, then that many bytes of sealed (0x0B)
//  frame — `BridgeSeal(token:channel: .stream)`, which is a different key pair from
//  the datagram seal's for the reason spelled out in `BridgeSeal.Channel`.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import Network
import OSLog

/// One TCP connection to the host's control port, with reassembled library
/// responses and raw non-library packets delivered on the main actor.
@MainActor
final class BridgeControlLink {
    /// Every complete library response.
    var onResponse: ((GameLibraryProtocol.Reassembler.Completed) -> Void)?
    /// Every non-library frame, still packed: haptics, telemetry, perf.
    var onPacket: ((Data) -> Void)?
    /// The endpoint that connected. The input stream uses the address, since this is
    /// the only component that finds out which one works.
    var onReady: ((String) -> Void)?

    private(set) var isReady = false
    /// The endpoint currently in use, for the debug HUD.
    private(set) var activeEndpoint: String?

    private let log = Logger(subsystem: "com.illixion.Longwave", category: "BridgeControlLink")
    private let queue = DispatchQueue(label: "com.illixion.Longwave.bridge.control")

    private var rendezvous: ControllerBridgeRendezvous?
    /// Keys for this session's stream. Nil until a rendezvous arrives, and nothing is
    /// sent or accepted without it.
    private var seal: BridgeSeal?
    /// The token `seal` was derived from, so a reconnect keeps its counters and only a
    /// new session re-keys — see `adopt(_:)`.
    private var keyedToken: Data?
    private var connection: NWConnection?
    private var reassembler = GameLibraryProtocol.Reassembler()
    private var candidateIndex = 0
    private var reconnectTask: Task<Void, Never>?
    /// Bytes received and not yet forming a whole frame.
    private var inbox = Data()

    // MARK: Lifecycle

    /// Adopt a rendezvous and connect. The host re-announces the same one every two
    /// seconds while the channel is alive, so this has to be idempotent in two
    /// distinct ways, both of which were bugs first:
    ///
    /// - **Do not re-key.** A `BridgeSeal` is its counters as much as its keys, the
    ///   nonce is the send counter, and the host does not reset its replay window on a
    ///   re-announcement. Re-deriving would restart our counter at 1 behind a window
    ///   already past 400, after which the host refuses everything we send as a stale
    ///   replay. This is exactly what killed sealed *input* for two months of sessions.
    /// - **Do not restart a connect in flight.** Announcements arrive every 2 s and a
    ///   TCP connect is allowed 3 s, so cancelling and restarting on each one could
    ///   keep a perfectly good connection from ever completing.
    ///
    /// A genuinely new session — a different token, or a host announcing different
    /// addresses — does want all of it torn down and rebuilt.
    func adopt(_ new: ControllerBridgeRendezvous) {
        let sameSession = rendezvous?.token == new.token && rendezvous?.endpoints == new.endpoints
        // A connection object exists whenever an attempt is live or established; the
        // retry cycle in `advance()` looks after failures on its own.
        if sameSession, connection != nil { return }
        log.notice("""
            Rendezvous: \(new.endpoints.joined(separator: ", "), privacy: .public) \
            control port \(new.controlPort, privacy: .public)
            """)
        rendezvous = new
        if new.token != keyedToken {
            seal = BridgeSeal(token: new.token, channel: .stream)
            keyedToken = new.token
        }
        candidateIndex = 0
        reassembler.reset()
        inbox.removeAll(keepingCapacity: true)
        isReady = false
        activeEndpoint = nil
        connect()
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        rendezvous = nil
        seal = nil
        keyedToken = nil
        isReady = false
        activeEndpoint = nil
        reassembler.reset()
        inbox.removeAll(keepingCapacity: false)
    }

    // MARK: Sending

    /// Send one library request. False when the link is not up — the caller decides
    /// whether to queue it or report it.
    @discardableResult
    func send(op: GameLibraryProtocol.Op, requestId: UInt32, body: Data = Data()) -> Bool {
        send(GameLibraryProtocol.request(op: op, requestId: requestId, body: body))
    }

    /// Send one already-encoded packet (a debug tune, say).
    @discardableResult
    func send(_ plain: Data) -> Bool {
        guard isReady, let connection, let packet = seal?.seal(plain) else { return false }
        var frame = Data(capacity: 4 + packet.count)
        let length = UInt32(packet.count)
        withUnsafeBytes(of: length.littleEndian) { frame.append(contentsOf: $0) }
        frame.append(packet)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.log.error("Control send failed: \(error.localizedDescription, privacy: .public)")
                // A partial frame leaves the host hunting for a length prefix inside a
                // packet, so the connection cannot be reused after a failed write.
                self?.dropAndReconnect()
            }
        })
        return true
    }

    // MARK: Endpoint selection

    private func connect() {
        guard let rendezvous, !rendezvous.endpoints.isEmpty else {
            log.error("Rendezvous announced no endpoints; the control link has nowhere to go.")
            return
        }
        // The ANNOUNCED port, never the constant: a host whose fixed port was taken
        // binds an ephemeral one, and this packet is how we find out.
        guard let port = NWEndpoint.Port(rawValue: rendezvous.controlPort) else { return }
        let host = rendezvous.endpoints[candidateIndex % rendezvous.endpoints.count]
        connection?.cancel()
        inbox.removeAll(keepingCapacity: true)
        reassembler.reset()

        /* A short connect timeout is what makes walking the candidate list quick: an
           address this headset cannot reach (the PC's hotspot side, say) would otherwise
           sit in .preparing until the system gave up. */
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = 3
        options.noDelay = true
        // Match the host's idle deadline: it drops a connection with no traffic for 5 s,
        // and the tune resend (200 ms) normally keeps this well clear.
        options.enableKeepalive = true
        options.keepaliveIdle = 2
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port,
                                using: NWParameters(tls: nil, tcp: options))
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state: state, host: host) }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func handle(state: NWConnection.State, host: String) {
        switch state {
        case .ready:
            // Unlike UDP, this is a real answer: the host accepted us.
            activeEndpoint = host
            guard !isReady else { return }
            isReady = true
            log.notice("Control link ready via \(host, privacy: .public)")
            onReady?(host)
        case .failed(let error):
            log.notice("Control endpoint \(host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            advance()
        case .waiting(let error):
            // No route, or nothing listening. Another address may work, so move on
            // rather than waiting for this one to become viable.
            log.notice("Control endpoint \(host, privacy: .public) unusable: \(error.localizedDescription, privacy: .public)")
            advance()
        case .cancelled:
            break
        default:
            break
        }
    }

    /// Try the next announced address, and keep cycling — with a pause each time round
    /// — rather than giving up. The host may not be listening yet (the broker starts
    /// after the session connects), and a link that stops trying is a session with no
    /// HUD and no Games tab.
    private func advance() {
        let wasReady = isReady
        isReady = false
        activeEndpoint = nil
        connection?.cancel()
        connection = nil
        guard let count = rendezvous?.endpoints.count, count > 0 else { return }
        candidateIndex += 1
        let wrapped = candidateIndex % count == 0
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            // A connection that had been working deserves an immediate retry: the usual
            // cause is the broker restarting, and the user is sitting in the session.
            try? await Task.sleep(for: .milliseconds(wasReady ? 300 : (wrapped ? 1500 : 0)))
            guard !Task.isCancelled, self?.rendezvous != nil else { return }
            self?.connect()
        }
    }

    private func dropAndReconnect() {
        guard rendezvous != nil else { return }
        advance()
    }

    // MARK: Receiving

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { @MainActor in self?.ingest(data) }
            }
            if isComplete || error != nil {
                Task { @MainActor in
                    guard let self, self.connection === conn else { return }
                    self.log.notice("Control link closed by the host; reconnecting.")
                    self.dropAndReconnect()
                }
                return
            }
            self?.receive(on: conn)
        }
    }

    /// Accumulate and split frames. TCP is a byte stream, so a frame can arrive in
    /// pieces and two frames can arrive in one read — both are normal, and neither is
    /// something the sender can control.
    private func ingest(_ data: Data) {
        inbox.append(data)
        while inbox.count >= 4 {
            let header = [UInt8](inbox.prefix(4))
            let length = UInt32(header[0]) | (UInt32(header[1]) << 8)
                | (UInt32(header[2]) << 16) | (UInt32(header[3]) << 24)
            guard length > 0, length <= 64 * 1024 else {
                // Framing is lost and a byte stream gives no way to resynchronise.
                log.error("Control link framing error (length \(length, privacy: .public)); reconnecting.")
                inbox.removeAll(keepingCapacity: true)
                dropAndReconnect()
                return
            }
            let total = 4 + Int(length)
            guard inbox.count >= total else { return }
            // Offsets from `startIndex`, never absolute: a `Data` that has been sliced
            // does not start at 0, and `subdata(in:)` would read the wrong bytes.
            let base = inbox.startIndex
            let frame = Data(inbox[(base + 4) ..< (base + total)])
            inbox = Data(inbox[(base + total)...])
            // Nothing unsealed is looked at: only the host we paired with holds the key,
            // so failing to open IS the authentication.
            guard let plain = seal?.open(frame) else {
                log.error("Discarding a control frame that did not authenticate.")
                continue
            }
            deliver(plain)
        }
    }

    private func deliver(_ plain: Data) {
        if let chunk = GameLibraryProtocol.Chunk(plain) {
            guard let done = reassembler.accept(chunk) else { return }
            onResponse?(done)
            return
        }
        onPacket?(plain)
    }
}
#endif
