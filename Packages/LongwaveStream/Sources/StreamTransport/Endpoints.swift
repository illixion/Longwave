import StreamCrypto
import StreamWire

/// The client side of connecting (section 3): sends initiations until a
/// response completes one, then hands over the session.
///
/// Each retry is a fresh initiation (new ephemeral key), sent 250 ms after the
/// last and doubling to 1 s, for 5 s in all (the section 4.6 fallback to v2
/// decides on its own, shorter, clock). A late response to an earlier attempt
/// still completes, so the last few attempts are kept.
public struct ClientConnector {
    public struct Configuration: Sendable, Equatable {
        public var firstRetry: UInt64 = 250_000_000
        public var maxRetry: UInt64 = 1_000_000_000
        public var giveUpAfter: UInt64 = 5_000_000_000
        public var ciphers: [RecordCipher] = RecordCipher.allCases
        public var session: TransportSession.Configuration = .init(sendsFeedback: true)

        public init() {}
    }

    public enum Failure: Error, Sendable, Equatable {
        case timedOut
        case crypto(StreamCryptoError)
    }

    public let configuration: Configuration
    public let localIndex: UInt32
    private let psk: StreamPSK
    private let hello: [UInt8]
    private var attempts: [(initiator: StreamInitiator, sentAt: UInt64)] = []
    private var startedAt: UInt64?
    private var nextAttemptAt: UInt64?
    private var retryInterval: UInt64

    public init(psk: StreamPSK, hello: [UInt8], localIndex: UInt32 = StreamHandshake.randomIndex(),
                configuration: Configuration = Configuration()) {
        self.psk = psk
        self.hello = hello
        self.localIndex = localIndex
        self.configuration = configuration
        retryInterval = configuration.firstRetry
    }

    public var attemptCount: Int { attempts.count }

    /// The initiation to send now, if one is due.
    public mutating func poll(now: UInt64) throws(Failure) -> [UInt8]? {
        let started = startedAt ?? now
        startedAt = started
        guard now - started < configuration.giveUpAfter else { throw .timedOut }
        if let nextAttemptAt, now < nextAttemptAt { return nil }
        let initiator: StreamInitiator
        do {
            initiator = try StreamInitiator(psk: psk, localIndex: localIndex, ciphers: configuration.ciphers, payload: hello)
        } catch {
            throw .crypto(error)
        }
        attempts.append((initiator, now))
        if attempts.count > 3 { attempts.removeFirst() }
        if nextAttemptAt != nil { retryInterval = min(retryInterval * 2, configuration.maxRetry) }
        nextAttemptAt = now + retryInterval
        return initiator.initiation
    }

    public var nextWakeTime: UInt64? {
        guard let startedAt else { return nil }
        return min(nextAttemptAt ?? startedAt, startedAt + configuration.giveUpAfter)
    }

    /// Completes on a matching response; nil for anything else.
    public func receive(_ datagram: [UInt8], now: UInt64) -> (session: TransportSession, helloAck: [UInt8])? {
        guard PacketKind.of(datagram) == .response else { return nil }
        for attempt in attempts.reversed() {
            guard let (secure, helloAck) = try? attempt.initiator.complete(response: datagram, now: now) else { continue }
            var session = TransportSession(secure: secure, configuration: configuration.session, now: now)
            session.seedRoundTrip(now - attempt.sentAt)
            return (session, helloAck)
        }
        return nil
    }
}

/// The host side: answers initiations from paired devices, routes transport
/// packets to their sessions by connection ID, follows roaming clients, and
/// replaces a device's session only once the new one has proven itself.
public struct HostEndpoint<Address: Hashable & Sendable> {
    /// A paired device's key, and the ID the host knows it by.
    public struct Device: Sendable, Equatable {
        public var psk: StreamPSK
        public var deviceID: String

        public init(psk: StreamPSK, deviceID: String) {
            self.psk = psk
            self.deviceID = deviceID
        }
    }

    public enum Event: Sendable, Equatable {
        /// Send this datagram (a handshake response).
        case send([UInt8], to: Address)
        /// A handshake completed; the session waits for its first packet.
        case connected(index: UInt32, deviceID: String, hello: [UInt8])
        /// The session's first transport packet authenticated: the client is real.
        case confirmed(index: UInt32)
        case events(index: UInt32, [SessionEvent])
        /// An older session of the same device, ended because a newer one confirmed.
        case superseded(index: UInt32, by: UInt32)
        case closed(index: UInt32, SessionClosure)
    }

    public struct Entry: Sendable {
        public var session: TransportSession
        public var address: Address
        public let deviceID: String
        public var confirmed: Bool
        public let createdAt: UInt64
    }

    static var unprovenPerDevice: Int { 3 }

    public var sessionConfiguration: TransportSession.Configuration
    /// Ciphers the host takes, most preferred first.
    public var preferredCiphers: [RecordCipher]
    public private(set) var sessions: [UInt32: Entry] = [:]
    public private(set) var dropped = 0

    private var devices: [StreamPSK.KeyID: Device] = [:]
    private var replayFilter = InitiationReplayFilter<(response: [UInt8], index: UInt32)>()

    public init(devices: [Device], preferredCiphers: [RecordCipher] = [.aes256GCM, .chaCha20Poly1305],
                sessionConfiguration: TransportSession.Configuration = .init(sendsFeedback: false)) {
        self.preferredCiphers = preferredCiphers
        self.sessionConfiguration = sessionConfiguration
        setDevices(devices)
    }

    /// Replaces the paired set. Sessions of removed devices end; their indices
    /// are returned.
    @discardableResult
    public mutating func setDevices(_ list: [Device]) -> [UInt32] {
        devices = Dictionary(list.map { ($0.psk.keyID, $0) }, uniquingKeysWith: { _, last in last })
        let allowed = Set(list.map(\.deviceID))
        let ended = sessions.filter { !allowed.contains($0.value.deviceID) }.map(\.key)
        for index in ended { sessions[index] = nil }
        return ended
    }

    /// Handles one datagram from `address`. `answer` sees the client's hello
    /// and returns the hello-ack, or nil to refuse.
    public mutating func receive(_ datagram: [UInt8], from address: Address, now: UInt64,
                                 answer: (_ deviceID: String, _ hello: [UInt8]) -> [UInt8]?) -> [Event] {
        switch PacketKind.of(datagram) {
        case .initiation:
            return accept(datagram, from: address, now: now, answer: answer)
        case .transport:
            return route(datagram, from: address, now: now)
        case .response, nil:
            dropped += 1
            return []
        }
    }

    private mutating func accept(_ datagram: [UInt8], from address: Address, now: UInt64,
                                 answer: (String, [UInt8]) -> [UInt8]?) -> [Event] {
        let devices = devices
        guard let responder = try? StreamResponder(initiation: datagram, lookup: { devices[$0]?.psk }),
              let device = devices[responder.keyID] else {
            dropped += 1
            return []
        }
        if let cached = replayFilter.lookup(responder.initiatorEphemeral, now: now) {
            // A repeat of an answered initiation: the same response, no new session.
            return sessions[cached.index] == nil ? [] : [.send(cached.response, to: address)]
        }
        guard let cipher = responder.choose(from: preferredCiphers), let helloAck = answer(device.deviceID, responder.payload)
        else {
            dropped += 1
            return []
        }
        // Each client retry is a fresh initiation, and a late response to any of
        // its last three still completes it, so keep that many unproven
        // sessions per device and no more.
        var output: [Event] = []
        let unproven = sessions.filter { $0.value.deviceID == device.deviceID && !$0.value.confirmed }
            .sorted { $0.value.createdAt < $1.value.createdAt }
        for (stale, _) in unproven.dropLast(Self.unprovenPerDevice - 1) {
            sessions[stale] = nil
            output.append(.closed(index: stale, .timedOut))
        }
        var index = StreamHandshake.randomIndex()
        while sessions[index] != nil { index = StreamHandshake.randomIndex() }
        guard let (secure, response) = try? responder.respond(localIndex: index, cipher: cipher, payload: helloAck, now: now)
        else {
            dropped += 1
            return []
        }
        sessions[index] = Entry(session: TransportSession(secure: secure, configuration: sessionConfiguration, now: now),
                                address: address, deviceID: device.deviceID, confirmed: false, createdAt: now)
        replayFilter.remember(responder.initiatorEphemeral, response: (response, index), now: now)
        return output + [.send(response, to: address),
                         .connected(index: index, deviceID: device.deviceID, hello: responder.payload)]
    }

    private mutating func route(_ datagram: [UInt8], from address: Address, now: UInt64) -> [Event] {
        guard let header = try? RecordHeader(parsing: datagram), var entry = sessions[header.receiverIndex] else {
            dropped += 1
            return []
        }
        let index = header.receiverIndex
        let before = entry.session.statistics.datagramsReceived
        var output: [Event] = []
        do {
            let events = try entry.session.receive(datagram, now: now)
            if entry.session.statistics.datagramsReceived > before {
                // Authenticated: follow the client to its new address (WireGuard's
                // rule). A new path may take a different datagram size.
                if entry.address != address, entry.confirmed { entry.session.pathChanged(now: now) }
                entry.address = address
                if !entry.confirmed {
                    entry.confirmed = true
                    output.append(.confirmed(index: index))
                    for (other, old) in sessions where other != index && old.deviceID == entry.deviceID {
                        sessions[other] = nil
                        output.append(.superseded(index: other, by: index))
                    }
                }
            }
            sessions[index] = entry
            if !events.isEmpty { output.append(.events(index: index, events)) }
        } catch {
            sessions[index] = nil
            output.append(.closed(index: index, error))
        }
        return output
    }

    /// Due datagrams for every session, and sessions that timed out.
    public mutating func poll(now: UInt64) -> (datagrams: [(bytes: [UInt8], to: Address)], closed: [(UInt32, SessionClosure)]) {
        var datagrams: [(bytes: [UInt8], to: Address)] = []
        var closed: [(UInt32, SessionClosure)] = []
        for index in Array(sessions.keys) {
            guard var entry = sessions[index] else { continue }
            for datagram in entry.session.poll(now: now) { datagrams.append((datagram, entry.address)) }
            if let closure = entry.session.closure {
                sessions[index] = nil
                closed.append((index, closure))
            } else {
                sessions[index] = entry
            }
        }
        return (datagrams, closed)
    }

    public func nextWakeTime(now: UInt64) -> UInt64? {
        sessions.values.compactMap { $0.session.nextWakeTime(now: now) }.min()
    }

    /// Runs `body` on one session (to queue messages, seal media).
    public mutating func withSession<T>(_ index: UInt32, _ body: (inout TransportSession) throws -> T) rethrows -> T? {
        guard var entry = sessions[index] else { return nil }
        defer { sessions[index] = entry }
        return try body(&entry.session)
    }
}
