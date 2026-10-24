import StreamCrypto
import StreamFEC
import StreamPlayout
import StreamSim
@testable import StreamTransport
import StreamWire
import XCTest

private let ms: UInt64 = 1_000_000

private enum Node: Hashable, Sendable {
    case client, clientRoamed, host, attacker
}

/// A client and a host on virtual time over `SimNetwork`. The host's clock
/// runs from a different epoch, so clock sync has something to find.
private final class Harness {
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
                let events = host.receive(delivery.bytes, from: delivery.from, now: hostNow, answer: { _, hello in
                    hello == Array("hello".utf8) ? Array("ack".utf8) : nil
                })
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

final class SimulatedSessionTests: XCTestCase {
    func testHandshakeMessagesAndClockSyncOnALAN() throws {
        let harness = Harness()
        harness.run(for: 50 * ms)
        let client = try XCTUnwrap(harness.client)
        XCTAssertEqual(harness.helloAck, Array("ack".utf8))
        XCTAssertEqual(harness.connector.attemptCount, 1)
        XCTAssertTrue(harness.hostEvents.contains { if case .connected(_, "device-1", _) = $0 { true } else { false } })
        XCTAssertEqual(client.secure.cipher, .aes256GCM)

        try harness.client!.send(.keyDown, body: [1], on: .input)
        try harness.client!.send(.formatDescription, body: [2, 2], on: .control)
        let index = try XCTUnwrap(harness.hostIndex)
        try harness.host.withSession(index) { try $0.send(MessageType(rawValue: 0x21), body: [UInt8](repeating: 9, count: 5000), on: .bulk) }
        harness.run(for: 3_000 * ms)

        XCTAssertTrue(harness.hostEvents.contains(.confirmed(index: index)))
        XCTAssertEqual(harness.messages(harness.hostReceivedEvents, on: .input).map(\.type), [.keyDown])
        XCTAssertEqual(harness.messages(harness.hostReceivedEvents, on: .control).map(\.body), [[2, 2][...]])
        XCTAssertEqual(harness.messages(harness.clientEvents, on: .bulk).first?.body.count, 5000)

        // Clock sync: the client knows the host's clock to well under a millisecond.
        let estimate = try XCTUnwrap(harness.client!.clock.remoteTime(atLocal: harness.now))
        XCTAssertLessThan(abs(Int64(bitPattern: estimate &- harness.hostNow)), 400_000)
        let rtt = harness.client!.rtt.smoothed
        XCTAssertGreaterThan(rtt, 1 * ms)
        XCTAssertLessThan(rtt, 4 * ms)
        // Pings every 250 ms keep both sides alive and nothing is left over.
        XCTAssertTrue(harness.client!.reliableChannelsIdle)
        XCTAssertGreaterThan(harness.client!.statistics.pingsAnswered, 5)
    }

    func testHandshakeSurvivesHeavyLoss() throws {
        // 25% loss each way: an attempt gets through about half the time, and
        // seven attempts fit the 5 s budget.
        var lossy = LinkModel.lan
        lossy.loss = 0.25
        for seed in UInt64(1)...10 {
            let harness = Harness(up: lossy, down: lossy, seed: seed)
            harness.run(for: 5_000 * ms)
            XCTAssertNotNil(harness.client, "seed \(seed): \(String(describing: harness.clientFailure))")
            harness.run(for: 1_000 * ms)
            XCTAssertEqual(harness.host.sessions.count, 1,
                           "seed \(seed): retries' sessions end once the real one confirms")
        }
    }

    func testHandshakeGivesUpWithoutAHost() {
        let harness = Harness()
        harness.network = SimNetwork()
        harness.run(for: 6_000 * ms)
        XCTAssertEqual(harness.clientFailure, .timedOut)
        XCTAssertGreaterThan(harness.connector.attemptCount, 2)
    }

    /// Input events over loss, reordering and the headset's Wi-Fi stalls: every
    /// one arrives, once, in order.
    func testReliableInputThroughLossJitterAndStalls() throws {
        var link = LinkModel(propagationDelay: 2 * ms, jitter: 3 * ms, loss: 0.1)
        link.stalls = .init(interval: 2_000 * ms...4_000 * ms, duration: 60 * ms...180 * ms)
        let harness = Harness(up: link, down: link, seed: 7)
        harness.run(for: 2_000 * ms)
        XCTAssertNotNil(harness.client)
        var sent = 0
        harness.tick = { h in
            guard h.client != nil else { return }
            while sent < 2_000, UInt64(sent) * 5 * ms <= h.now - 2_000 * ms {
                try? h.client!.send(.keyDown, body: withUnsafeBytes(of: UInt32(sent).littleEndian, Array.init), on: .input)
                sent += 1
            }
        }
        harness.tickWake = { h in sent < 2_000 ? 2_000 * ms + UInt64(sent) * 5 * ms : nil }
        harness.run(for: 14_000 * ms)
        let received = harness.messages(harness.hostReceivedEvents, on: .input)
            .map { $0.body.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        XCTAssertEqual(received, (0..<2_000).map(UInt32.init))
        XCTAssertTrue(harness.client!.reliableChannelsIdle)
    }

    /// 60 fps video with FEC and NACK: the host shards and paces frames, the
    /// client assembles them and asks again for what FEC can't rebuild.
    func testVideoWithFECAndNACK() throws {
        for (loss, label) in [(0.02, "2%"), (0.10, "10%")] {
            var down = LinkModel(propagationDelay: 1 * ms, jitter: 1 * ms, rate: 12_000_000, loss: loss)
            down.queueLimit = 256 * 1024
            let harness = Harness(down: down, seed: 11)
            harness.run(for: 100 * ms)
            let index = try XCTUnwrap(harness.hostIndex, label)

            var assembler = VideoFrameAssembler(streamID: 1)
            var delivered: [UInt32] = []
            var lost = 0
            var frames: [UInt32: ShardedVideoFrame] = [:]
            var queue: [(header: VideoShardHeader, data: ArraySlice<UInt8>)] = []
            var pacer = Pacer(rate: 4_000_000)
            var nextFrame: UInt32 = 0
            let start = harness.now
            var lastNack: [String: UInt64] = [:]
            var resentShards = 0
            var corrupted = 0
            let shardSize = DatagramLayout.videoShardDataCapacity(udpPayload: DatagramLayout.defaultUDPPayload)

            harness.tick = { h in
                // Host: a new 40 KB frame every 16 ms, its shards queued for the pacer.
                while nextFrame < 300, start + UInt64(nextFrame) * 16 * ms <= h.now {
                    let payload = try! FramePayload.encode(sideData: SideData(),
                                                           accessUnit: (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &+ Int(nextFrame)) })
                    let info = VideoFrameInfo(streamID: 1, frameNumber: nextFrame, captureTime: h.hostNow,
                                              flags: nextFrame == 0 ? .key : [], referenceDistance: nextFrame == 0 ? 0 : 1)
                    let frame = try! ShardedVideoFrame(payload: payload, info: info, shardSize: shardSize, policy: .initial)
                    frames[nextFrame] = frame
                    frames[nextFrame &- 30] = nil
                    queue += (0..<frame.count).map(frame.shard)
                    nextFrame += 1
                }
                // Host: answer NACKs with data shards first, parity if those run short.
                for event in h.hostReceivedEvents {
                    guard case .nack(let nack) = event, let frame = frames[nack.frameNumber] else { continue }
                    let all = (0..<frame.count).map(frame.shard)
                    switch nack.scope {
                    case .wholeFrame:
                        queue.insert(contentsOf: all.filter { !$0.header.isParity }, at: 0)
                    case .wholeBlock(let block):
                        queue.insert(contentsOf: all.filter { $0.header.block == block && !$0.header.isParity }, at: 0)
                    case .shards(let block, let needed, let indices):
                        var picks = all.filter { $0.header.block == block && indices.contains($0.header.shardIndex) }
                        picks += all.filter { $0.header.block == block && $0.header.isParity }
                        queue.insert(contentsOf: picks.prefix(Int(needed)), at: 0)
                        resentShards += min(picks.count, Int(needed))
                    }
                }
                h.hostEvents.removeAll { if case .events = $0 { true } else { false } }
                while let (header, data) = queue.first {
                    let size = data.count + 60
                    guard pacer.delay(for: size, now: h.now) == 0 else { break }
                    queue.removeFirst()
                    pacer.consume(size, now: h.now)
                    if let datagram = try? h.host.withSession(index, { try $0.sealVideo(header, data: data, now: h.hostNow) }) {
                        h.network.send(datagram, from: .host, to: .client, now: h.now)
                    }
                }
                // Client: assemble, then NACK what's missing once per few RTTs.
                for event in h.clientEvents {
                    guard case .video(let header, let data) = event else { continue }
                    for result in assembler.receive(header, data: data, now: h.now) {
                        if case .frame(let frame) = result {
                            delivered.append(frame.frameNumber)
                            let expected = (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &+ Int(frame.frameNumber)) }
                            if Array(frame.payload.accessUnit) != expected { corrupted += 1 }
                        }
                        if case .lost(_, let count, _) = result { lost += Int(count) }
                    }
                }
                h.clientEvents.removeAll()
                for result in assembler.poll(now: h.now) {
                    if case .frame(let frame) = result { delivered.append(frame.frameNumber) }
                    if case .lost(_, let count, _) = result { lost += Int(count) }
                }
                for missing in assembler.missingShards(now: h.now) {
                    let scope: ShardNack.Scope
                    let key: String
                    switch missing.scope {
                    case .wholeFrame:
                        scope = .wholeFrame
                        key = "\(missing.frameNumber)"
                    case .wholeBlock(let block):
                        scope = .wholeBlock(block)
                        key = "\(missing.frameNumber)/\(block)"
                    case .shards(let block, let needed, let indices):
                        scope = .shards(block: block, needed: UInt8(min(needed, 255)), dataIndices: indices)
                        key = "\(missing.frameNumber)/\(block)"
                    }
                    if let last = lastNack[key], h.now - last < 8 * ms { continue }
                    lastNack[key] = h.now
                    h.client!.send(ShardNack(streamID: 1, frameNumber: missing.frameNumber, scope: scope))
                }
            }
            harness.tickWake = { h in
                var wakes: [UInt64] = [h.now + 1 * ms]
                if nextFrame < 300 { wakes.append(start + UInt64(nextFrame) * 16 * ms) }
                return wakes.min()
            }
            harness.run(for: 300 * 16 * ms + 500 * ms)

            XCTAssertEqual(delivered, Array(delivered.sorted()), "\(label): decode order")
            XCTAssertEqual(Set(delivered).count, delivered.count, "\(label): each frame once")
            let deliveredFraction = Double(delivered.count) / 300
            print("video \(label): delivered \(delivered.count)/300, lost \(lost), resent \(resentShards) shards, "
                  + "rtt \(harness.client!.rtt.smoothed / 1_000) µs")
            XCTAssertGreaterThanOrEqual(deliveredFraction, loss < 0.05 ? 1.0 : 0.99, label)
            XCTAssertEqual(corrupted, 0, "\(label): every delivered frame byte for byte")
            // NACK repairs the tail FEC can't, without resending wholesale.
            XCTAssertLessThan(resentShards, 300 * 39 / 10, label)
        }
    }

    func testFeedbackReachesTheHost() throws {
        var down = LinkModel.lan
        down.loss = 0.05
        let harness = Harness(down: down, seed: 5)
        harness.run(for: 100 * ms)
        let index = try XCTUnwrap(harness.hostIndex)
        var sent = 0
        harness.tick = { h in
            while sent < 500, UInt64(sent) * ms <= h.now - 100 * ms - 1_000 * ms {
                let header = VideoShardHeader(streamID: 1, frameNumber: UInt32(sent), captureTime: 0, flags: [.key, .lastBlock],
                                              block: 0, blockCount: 1, shardIndex: 0, dataShards: 1, parityShards: 0,
                                              referenceDistance: 0)
                if let datagram = try? h.host.withSession(index, { try $0.sealVideo(header, data: [1, 2, 3], now: h.hostNow) }) {
                    h.network.send(datagram, from: .host, to: .client, now: h.now)
                }
                sent += 1
            }
        }
        harness.tickWake = { _ in sent < 500 ? 1_100 * ms + UInt64(sent) * ms : nil }
        harness.run(for: 1_000 * ms)
        var received = 0
        var lost = 0
        for event in harness.hostReceivedEvents {
            guard case .feedback(_, let results) = event else { continue }
            for result in results where result.packet.isMedia {
                if result.arrival == nil { lost += 1 } else { received += 1 }
            }
        }
        XCTAssertEqual(received + lost, 500, "every media packet reported once")
        XCTAssertEqual(Double(lost) / 500, 0.05, accuracy: 0.03)
    }

    func testRoamingAndSupersedingSessions() throws {
        let harness = Harness()
        harness.run(for: 50 * ms)
        let first = try XCTUnwrap(harness.hostIndex)

        // The client's address changes (Wi-Fi to Ethernet); the host follows it.
        harness.clientNode = .clientRoamed
        try harness.client!.send(.keyDown, body: [5], on: .input)
        harness.run(for: 50 * ms)
        XCTAssertEqual(harness.host.sessions[first]?.address, .clientRoamed)
        try harness.host.withSession(first) { try $0.send(MessageType(rawValue: 0x22), body: [6], on: .control) }
        harness.run(for: 50 * ms)
        XCTAssertEqual(harness.messages(harness.clientEvents, on: .control).last?.body, [6][...])

        // The same device reconnects: the old session lives until the new one
        // proves itself, then goes.
        harness.client = nil
        harness.connector = ClientConnector(psk: harness.psk, hello: Array("hello".utf8))
        harness.hostEvents.removeAll()
        harness.run(for: 100 * ms)
        let second = try XCTUnwrap(harness.host.sessions.keys.first { $0 != first } ?? harness.host.sessions.keys.first)
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(harness.hostEvents.contains(.superseded(index: first, by: second)))
        XCTAssertEqual(Array(harness.host.sessions.keys), [second])
    }

    func testReplayedInitiationGetsTheCachedResponseOnly() throws {
        let harness = Harness()
        // Capture the first initiation as an attacker would.
        let initiation = try XCTUnwrap(try harness.connector.poll(now: harness.now))
        harness.clientSend([initiation])
        harness.run(for: 50 * ms)
        XCTAssertNotNil(harness.client)
        XCTAssertEqual(harness.host.sessions.count, 1)
        let events = harness.host.receive(initiation, from: .attacker, now: harness.hostNow) { _, _ in [] }
        XCTAssertEqual(events.count, 1, "the cached response, nothing else")
        XCTAssertEqual(harness.host.sessions.count, 1)
        // And garbage from anyone else is ignored silently.
        let dropped = harness.host.dropped
        XCTAssertTrue(harness.host.receive([0x01, 3] + [UInt8](repeating: 0, count: 80), from: .attacker,
                                           now: harness.hostNow) { _, _ in [] }.isEmpty)
        XCTAssertEqual(harness.host.dropped, dropped + 1)
    }

    func testIdleTimeoutAndUnpairing() throws {
        let harness = Harness()
        harness.run(for: 50 * ms)
        let index = try XCTUnwrap(harness.hostIndex)
        // The client goes silent: the host's session times out after 10 s.
        harness.network.setModel(LinkModel(loss: 1), from: .client, to: .host)
        harness.run(for: 10_500 * ms)
        XCTAssertTrue(harness.hostEvents.contains(.closed(index: index, .timedOut)))
        // The client still hears the host's pings until the host gives up, then
        // times out itself ten seconds later.
        XCTAssertNil(harness.client?.closure)
        harness.run(for: 10_500 * ms)
        XCTAssertEqual(harness.client?.closure, .timedOut)

        // Unpairing ends a device's sessions at once.
        let other = Harness()
        other.run(for: 50 * ms)
        let indices = Array(other.host.sessions.keys)
        XCTAssertEqual(indices.count, 1)
        XCTAssertEqual(other.host.setDevices([]), indices)
        XCTAssertTrue(other.host.sessions.isEmpty)
    }
}
