import StreamCrypto
import StreamSim
@testable import StreamTransport
import StreamWire

private let ms: UInt64 = 1_000_000

enum Node: Hashable, Sendable {
    case client, clientRoamed, host, attacker
}

/// A client and a host on virtual time over `SimNetwork`. The host's clock
/// runs from a different epoch, so clock sync has something to find.
final class Harness {
    let psk = StreamPSK(token: "token", identity: "device-1")
    var network = SimNetwork<Node>()
    var now: UInt64 = 1_000 * ms
    let hostEpoch: UInt64 = 7_000_000 * ms
    var clientNode = Node.client
    var connector: ClientConnector
    var client: TransportSession?
    var host: HostEndpoint<Node>
    var clientEvents: [SessionEvent] = []
    var hostEvents: [HostEndpoint<Node>.Event] = []
    var helloAck: [UInt8]?
    var clientFailure: ClientConnector.Failure?
    /// Extra per-tick work and its wake time (media senders, NACK loops).
    var tick: ((Harness) -> Void)?
    var tickWake: ((Harness) -> UInt64?)?
    /// The host's hello-ack for a device's hello, or nil to refuse.
    var answer: (_ deviceID: String, _ hello: [UInt8]) -> [UInt8]? = { _, hello in
        hello == Array("hello".utf8) ? Array("ack".utf8) : nil
    }

    init(up: LinkModel = .lan, down: LinkModel = .lan, seed: UInt64 = 1) {
        connector = ClientConnector(psk: psk, hello: Array("hello".utf8))
        host = HostEndpoint(devices: [.init(psk: psk, deviceID: "device-1")])
        for node in [Node.client, .clientRoamed] {
            network.connect(node, to: .host, model: up, seed: seed &* 31 &+ 1)
            network.connect(.host, to: node, model: down, seed: seed &* 31 &+ 2)
        }
    }

    var hostNow: UInt64 { now + hostEpoch }

    func clientSend(_ datagrams: [[UInt8]]) {
        for datagram in datagrams { network.send(datagram, from: clientNode, to: .host, now: now) }
    }

    func step() {
        while let delivery = network.popDue(now: now) {
            if delivery.to == .host {
                let events = host.receive(delivery.bytes, from: delivery.from, now: hostNow, answer: answer)
                for event in events {
                    if case .send(let bytes, let to) = event {
                        network.send(bytes, from: .host, to: to, now: now)
                    } else {
                        hostEvents.append(event)
                    }
                }
            } else if delivery.to == clientNode {
                if client == nil {
                    if let (session, ack) = connector.receive(delivery.bytes, now: now) {
                        client = session
                        helloAck = ack
                    }
                } else if let events = try? client!.receive(delivery.bytes, now: now) {
                    clientEvents += events
                }
            }
        }
        if client == nil, clientFailure == nil {
            do {
                if let initiation = try connector.poll(now: now) { clientSend([initiation]) }
            } catch {
                clientFailure = error
            }
        }
        if client != nil { clientSend(client!.poll(now: now)) }
        let (datagrams, closed) = host.poll(now: hostNow)
        for datagram in datagrams { network.send(datagram.bytes, from: .host, to: datagram.to, now: now) }
        for (index, closure) in closed { hostEvents.append(.closed(index: index, closure)) }
        tick?(self)
    }

    func run(for duration: UInt64) {
        let end = now + duration
        while now < end {
            step()
            var candidates: [UInt64] = [end]
            if let next = network.nextDeliveryTime { candidates.append(next) }
            if client == nil, clientFailure == nil, let wake = connector.nextWakeTime { candidates.append(wake) }
            if let wake = client?.nextWakeTime(now: now) { candidates.append(wake) }
            if let wake = host.nextWakeTime(now: hostNow) { candidates.append(wake - hostEpoch) }
            if let wake = tickWake?(self) { candidates.append(wake) }
            now = max(candidates.min()!, now + 10_000)
        }
    }

    var hostIndex: UInt32? { host.sessions.keys.first }

    func messages(_ events: [SessionEvent], on channel: ReliableChannelID) -> [Message] {
        events.compactMap { if case .message(channel, let m) = $0 { m } else { nil } }
    }

    var hostReceivedEvents: [SessionEvent] {
        hostEvents.flatMap { (event) -> [SessionEvent] in
            if case .events(_, let events) = event { return events }
            return []
        }
    }
}
