// A headset and a host joined by a real v3 session (handshake, AEAD records,
// feedback, NACKs) over StreamSim's links, on virtual time. The same shape as
// StreamTransportTests' harness, public so the benches can drive it.
import StreamCrypto
import StreamSim
import StreamTransport
import StreamWire

public enum BenchNode: Hashable, Sendable {
    case client, host
}

public final class BenchSession {
    public let psk = StreamPSK(token: "bench", identity: "bench-headset")
    public var network = SimNetwork<BenchNode>()
    /// Virtual time, ns. Host and client share it: the bench reads one clock.
    public private(set) var now: UInt64 = 1_000_000_000
    public private(set) var connector: ClientConnector
    public var client: TransportSession?
    public var host: HostEndpoint<BenchNode>
    /// What arrived at each side since the owner last emptied these.
    public var clientEvents: [SessionEvent] = []
    public var hostEvents: [SessionEvent] = []
    public private(set) var clientFailure: ClientConnector.Failure?

    public init(scenario: LinkScenario, seed: UInt64 = 1) {
        connector = ClientConnector(psk: psk, hello: Array("hello".utf8))
        host = HostEndpoint(devices: [.init(psk: psk, deviceID: "bench-headset")])
        network.connect(.client, to: .host, model: scenario.up, seed: seed &* 31 &+ 1)
        network.connect(.host, to: .client, model: scenario.down, seed: seed &* 31 &+ 2)
    }

    public var hostIndex: UInt32? { host.sessions.keys.first }

    public var downlink: SimLink? { network.link(.host, to: .client) }

    /// Handles everything due by `now`, then polls both ends.
    public func step() {
        while let delivery = network.popDue(now: now) {
            if delivery.to == .host {
                let events = host.receive(delivery.bytes, from: delivery.from, now: now) { _, hello in
                    hello == Array("hello".utf8) ? Array("ack".utf8) : nil
                }
                for event in events {
                    switch event {
                    case .send(let bytes, let to): network.send(bytes, from: .host, to: to, now: now)
                    case .events(_, let events): hostEvents += events
                    default: break
                    }
                }
            } else if client == nil {
                if let (session, _) = connector.receive(delivery.bytes, now: now) { client = session }
            } else if let events = try? client!.receive(delivery.bytes, now: now) {
                clientEvents += events
            }
        }
        if client == nil, clientFailure == nil {
            do {
                if let initiation = try connector.poll(now: now) { network.send(initiation, from: .client, to: .host, now: now) }
            } catch {
                clientFailure = error
            }
        }
        if client != nil {
            for datagram in client!.poll(now: now) { network.send(datagram, from: .client, to: .host, now: now) }
        }
        let (datagrams, _) = host.poll(now: now)
        for datagram in datagrams { network.send(datagram.bytes, from: .host, to: datagram.to, now: now) }
    }

    /// The earliest time anything in the session itself has work.
    public func nextWake() -> UInt64? {
        var candidates: [UInt64] = []
        if let next = network.nextDeliveryTime { candidates.append(next) }
        if client == nil, clientFailure == nil, let wake = connector.nextWakeTime { candidates.append(wake) }
        if let wake = client?.nextWakeTime(now: now) { candidates.append(wake) }
        if let wake = host.nextWakeTime(now: now) { candidates.append(wake) }
        return candidates.min()
    }

    /// Moves the clock forward (never back).
    public func advance(to time: UInt64) {
        now = max(now, time)
    }

    /// Runs the session alone until it is up, or `limit` ns pass.
    public func connect(within limit: UInt64 = 2_000_000_000) -> Bool {
        let end = now + limit
        while now < end {
            step()
            if client != nil, hostIndex != nil, !hostEvents.isEmpty || client!.udpPayload > 0 { break }
            advance(to: min(nextWake() ?? end, end, now + 1_000_000))
        }
        // A few more round trips: the host's session confirms on the client's first record.
        let settle = now + 50_000_000
        while now < settle {
            step()
            advance(to: min(nextWake() ?? settle, settle, now + 1_000_000))
        }
        return client != nil && hostIndex != nil
    }
}
