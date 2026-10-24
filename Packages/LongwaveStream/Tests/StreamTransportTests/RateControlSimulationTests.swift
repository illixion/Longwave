import StreamSim
@testable import StreamTransport
import StreamWire
import XCTest

private let ms: UInt64 = 1_000_000

/// A host that encodes at whatever the controller allows: one frame every
/// 16.7 ms sized to `mediaRate / 60`, parity at the FEC ratio, shards paced at
/// 1.5 × the budget, probes sent as padding. The client side records each
/// shard's queueing delay.
private final class ControlledSender {
    let harness: Harness
    let index: UInt32
    let propagation: UInt64
    var controller: GCCRateController
    /// Caps the encoder below the budget (a still desktop), bytes/s.
    var encoderLimit: UInt64?

    private var pacer: Pacer
    private var queue: [(frame: UInt32, size: Int)] = []
    private var nextFrameAt: UInt64
    private var frameNumber: UInt32 = 0
    private var probe: (cluster: ProbeCluster, next: UInt64, remaining: Int)?

    /// (client time, queueing delay) per media shard.
    private(set) var delays: [(time: UInt64, delay: UInt64)] = []
    /// (client time, bytes) per datagram the client got.
    private(set) var arrivals: [(time: UInt64, bytes: Int)] = []
    /// (host time, budget) after every report.
    private(set) var budgets: [(time: UInt64, budget: SendBudget)] = []
    private(set) var framesDropped = 0
    private(set) var probesSent = 0

    init(harness: Harness, index: UInt32, propagation: UInt64, configuration: GCCRateController.Configuration = .init()) {
        self.harness = harness
        self.index = index
        self.propagation = propagation
        controller = GCCRateController(configuration: configuration)
        pacer = Pacer(rate: controller.budget.pacingRate)
        nextFrameAt = harness.now
        harness.tick = { [unowned self] h in self.tick(h) }
        harness.tickWake = { [unowned self] h in self.wake(h) }
    }

    private static let shardData = DatagramLayout.videoShardDataCapacity(udpPayload: DatagramLayout.defaultUDPPayload)

    private func tick(_ h: Harness) {
        // Host: reports into the controller.
        for event in h.hostEvents {
            guard case .events(_, let events) = event else { continue }
            for case .feedback(_, let results) in events {
                let rtt = h.host.sessions[index]?.session.rtt.smoothed ?? 2 * ms
                controller.onFeedback(results, now: h.hostNow, rtt: rtt)
                budgets.append((h.hostNow, controller.budget))
            }
        }
        h.hostEvents.removeAll()
        let budget = controller.budget
        pacer.setRate(budget.pacingRate, now: h.now)

        // Encoder: a frame per 1/60 s. A frame still queued when the third
        // after it is ready is dropped (the encoder is outrunning the link).
        while h.now >= nextFrameAt {
            let rate = min(budget.mediaRate(), encoderLimit ?? .max)
            let data = max(Int(rate / 60), 1_000)
            let shards = (data + Self.shardData - 1) / Self.shardData
            let parity = Int((Double(shards) * budget.fecRatio).rounded(.up))
            queue += Array(repeating: (frameNumber, Self.shardData + 56), count: shards + parity)
            if let oldest = queue.first?.frame, frameNumber - oldest >= 3 {
                queue.removeAll { $0.frame == oldest }
                framesDropped += 1
            }
            frameNumber += 1
            nextFrameAt += 16_666_667
        }

        // Probes: padding at the probe's rate, outside the pacer.
        if probe == nil, let cluster = controller.nextProbe(now: h.hostNow) {
            probe = (cluster, h.now, max(cluster.bytes / 1_200, 5))
            probesSent += 1
        }
        while var current = probe, current.next <= h.now {
            if let datagram = try? h.host.withSession(index, {
                try $0.sealPadding(size: 1_200, probeCluster: current.cluster.id, now: h.hostNow)
            }) {
                h.network.send(datagram, from: .host, to: .client, now: h.now)
            }
            current.remaining -= 1
            current.next += 1_200 * 1_000_000_000 / current.cluster.rate
            probe = current.remaining > 0 ? current : nil
        }

        // Media through the pacer.
        while let shard = queue.first, pacer.delay(for: shard.size, now: h.now) == 0 {
            queue.removeFirst()
            pacer.consume(shard.size, now: h.now)
            let header = VideoShardHeader(streamID: 1, frameNumber: shard.frame, captureTime: h.hostNow, flags: [.lastBlock],
                                          block: 0, blockCount: 1, shardIndex: 0, dataShards: 1, parityShards: 0,
                                          referenceDistance: 1)
            if let datagram = try? h.host.withSession(index, {
                try $0.sealVideo(header, data: [UInt8](repeating: 0, count: Self.shardData), now: h.hostNow)
            }) {
                h.network.send(datagram, from: .host, to: .client, now: h.now)
            }
        }

        // Client: queueing delay is what the trip took beyond propagation.
        for event in h.clientEvents {
            guard case .video(let header, let data) = event else { continue }
            let trip = h.hostNow - header.captureTime
            delays.append((h.now, trip > propagation ? trip - propagation : 0))
            arrivals.append((h.now, data.count + 56))
        }
        h.clientEvents.removeAll()
    }

    private func wake(_ h: Harness) -> UInt64? {
        var wakes = [nextFrameAt, h.now + 5 * ms]
        if let probe { wakes.append(probe.next) }
        if let shard = queue.first { wakes.append(h.now + max(pacer.delay(for: shard.size, now: h.now), 10_000)) }
        return wakes.min()
    }

    // MARK: Measurements over host-relative windows

    func goodput(_ window: Range<UInt64>) -> Double {
        let bytes = arrivals.filter { window.contains($0.time) }.reduce(0) { $0 + $1.bytes }
        return Double(bytes) * 1e9 / Double(window.upperBound - window.lowerBound)
    }

    func delayPercentile(_ p: Double, _ window: Range<UInt64>) -> UInt64 {
        let sorted = delays.filter { window.contains($0.time) }.map(\.delay).sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    func meanBudget(_ window: Range<UInt64>) -> Double {
        let epoch = harness.hostEpoch
        let inWindow = budgets.filter { window.contains($0.time - epoch) }
        guard !inWindow.isEmpty else { return 0 }
        return Double(inWindow.reduce(0) { $0 + $1.budget.total }) / Double(inWindow.count)
    }

    /// Per 500 ms: budget, goodput and worst queueing delay, for tuning.
    func dumpSeries(_ label: String, from start: UInt64, to end: UInt64) {
        var t = start
        while t < end {
            let w = t..<t + 500 * ms
            print("series \(label) \((t - start) / ms) ms: budget \(Int(meanBudget(w) / 1_000)) kB/s goodput \(Int(goodput(w) / 1_000)) "
                  + "maxq \(delayPercentile(1.0, w) / 1_000) µs")
            t += 500 * ms
        }
    }

    func report(_ label: String, _ window: Range<UInt64>, capacity: Double) {
        print("rate \(label): budget \(Int(meanBudget(window) / capacity * 100))% of capacity, "
              + "goodput \(Int(goodput(window) / capacity * 100))%, queue p50 \(delayPercentile(0.5, window) / 1_000) µs "
              + "p95 \(delayPercentile(0.95, window) / 1_000) µs, fec \(controller.budget.fecRatio), "
              + "loss \(controller.smoothedLoss), stalls ignored \(controller.stallsIgnored), dropped \(framesDropped) frames, probes \(probesSent)")
    }
}

final class RateControlSimulationTests: XCTestCase {
    private let capacity: UInt64 = 2_500_000 // 20 Mbit/s

    private func connect(down: LinkModel, seed: UInt64 = 3) throws -> (Harness, UInt32) {
        let harness = Harness(down: down, seed: seed)
        harness.run(for: 50 * ms)
        return (harness, try XCTUnwrap(harness.hostIndex))
    }

    private func bottleneck(propagation: UInt64, jitter: UInt64, loss: Double = 0) -> LinkModel {
        LinkModel(propagationDelay: propagation, jitter: jitter, rate: capacity, queueLimit: 256 * 1024, loss: loss)
    }

    /// From a 4 Mbit/s start, probing finds a 20 Mbit/s bottleneck within a
    /// couple of seconds, and the delay-based loop then holds it with little
    /// queue: on a LAN and on a Tailscale-like path whose base delay and jitter
    /// must not read as queueing.
    func testFindsAndHoldsABottleneck() throws {
        for (label, propagation, jitter) in [("lan", 1 * ms, 300_000 as UInt64), ("tailscale", 10 * ms, 3 * ms)] {
            let (harness, index) = try connect(down: bottleneck(propagation: propagation, jitter: jitter))
            let sender = ControlledSender(harness: harness, index: index, propagation: propagation)
            let start = harness.now
            harness.run(for: 30_000 * ms)
            let early = start + 1_000 * ms..<start + 3_000 * ms
            let steady = start + 10_000 * ms..<start + 30_000 * ms
            sender.report("\(label) start", early, capacity: Double(capacity))
            sender.report("\(label) steady", steady, capacity: Double(capacity))
            XCTAssertGreaterThan(sender.goodput(early), 0.75 * Double(capacity), "\(label): probing finds the rate")
            XCTAssertGreaterThan(sender.goodput(steady), 0.85 * Double(capacity), label)
            XCTAssertLessThan(sender.meanBudget(steady), 1.05 * Double(capacity), label)
            XCTAssertLessThan(sender.delayPercentile(0.95, steady), 20 * ms, "\(label): queueing stays short")
        }
    }

    /// The link halves mid-stream: the estimate follows within a second, and
    /// the queue that built while it noticed drains within half a second more
    /// (GCC alone takes about two).
    func testFollowsACapacityDrop() throws {
        let link = bottleneck(propagation: 1 * ms, jitter: 300_000)
        let (harness, index) = try connect(down: link)
        let sender = ControlledSender(harness: harness, index: index, propagation: 1 * ms)
        let start = harness.now
        harness.run(for: 15_000 * ms)
        var halved = link
        halved.rate = capacity / 2
        harness.network.setModel(halved, from: .host, to: .client)
        harness.run(for: 15_000 * ms)
        let after = start + 16_000 * ms..<start + 30_000 * ms
        sender.report("halved", after, capacity: Double(capacity / 2))
        XCTAssertLessThan(sender.meanBudget(start + 16_000 * ms..<start + 17_000 * ms), 1.15 * Double(capacity / 2))
        XCTAssertGreaterThan(sender.goodput(after), 0.8 * Double(capacity / 2))
        XCTAssertLessThan(sender.delayPercentile(1.0, start + 16_500 * ms..<start + 30_000 * ms), 25 * ms, "drained")
        XCTAssertLessThan(sender.delayPercentile(0.95, after), 15 * ms)
    }

    /// Wi-Fi loss that isn't congestion: 5 % random loss raises the FEC ratio
    /// and leaves the rate alone; 15 % cuts the media rate too.
    func testRandomLossBuysFECBeforeItCutsTheRate() throws {
        for loss in [0.05, 0.15] {
            let (harness, index) = try connect(down: bottleneck(propagation: 1 * ms, jitter: 300_000, loss: loss))
            let sender = ControlledSender(harness: harness, index: index, propagation: 1 * ms)
            let start = harness.now
            harness.run(for: 20_000 * ms)
            let steady = start + 10_000 * ms..<start + 20_000 * ms
            sender.report("loss \(loss)", steady, capacity: Double(capacity))
            XCTAssertEqual(sender.controller.smoothedLoss, loss, accuracy: 0.03)
            XCTAssertEqual(sender.controller.budget.fecRatio, 2 * loss + 0.05, accuracy: 0.07)
            if loss < 0.1 {
                XCTAssertGreaterThan(sender.meanBudget(steady), 0.8 * Double(capacity), "5 %: not a congestion signal")
            } else {
                // Cut, but not compounded to nothing: half the delay-based estimate.
                XCTAssertLessThan(Double(sender.controller.budget.total), 0.9 * Double(sender.controller.delayBasedRate))
                XCTAssertGreaterThan(sender.meanBudget(steady), 0.4 * Double(capacity))
            }
        }
    }

    /// The headset's Wi-Fi stalls (here every 2–4 s, ten times the measured
    /// rate) hold delivery for up to 180 ms and release it at once; they must
    /// not read as a collapsing link.
    func testHeadsetStallsDoNotCollapseTheRate() throws {
        var link = bottleneck(propagation: 1 * ms, jitter: 300_000)
        link.stalls = .init(interval: 2_000 * ms...4_000 * ms, duration: 60 * ms...180 * ms)
        let (harness, index) = try connect(down: link)
        let sender = ControlledSender(harness: harness, index: index, propagation: 1 * ms)
        let start = harness.now
        harness.run(for: 30_000 * ms)
        let steady = start + 10_000 * ms..<start + 30_000 * ms
        sender.report("stalls", steady, capacity: Double(capacity))
        XCTAssertGreaterThan(sender.meanBudget(steady), 0.8 * Double(capacity))
        XCTAssertGreaterThan(sender.goodput(steady), 0.8 * Double(capacity))
        XCTAssertGreaterThan(sender.controller.stallsIgnored, 4)
    }

    /// A still desktop sends far under the estimate. The estimate neither
    /// climbs past the link on nothing nor goes stale: periodic probes keep it,
    /// so the first motion gets an accurate rate.
    func testStillDesktopProbesInsteadOfDrifting() throws {
        let (harness, index) = try connect(down: bottleneck(propagation: 1 * ms, jitter: 300_000))
        let sender = ControlledSender(harness: harness, index: index, propagation: 1 * ms)
        sender.encoderLimit = 60_000
        let start = harness.now
        harness.run(for: 20_000 * ms)
        let still = start + 5_000 * ms..<start + 20_000 * ms
        sender.report("still", still, capacity: Double(capacity))
        XCTAssertLessThan(sender.meanBudget(still), 1.2 * Double(capacity))
        XCTAssertGreaterThan(Double(sender.controller.budget.total), 0.6 * Double(capacity))
        XCTAssertGreaterThan(sender.probesSent, 3, "start-up plus periodic probes")
        // Motion: the encoder takes the whole budget at once and the queue stays short.
        sender.encoderLimit = nil
        harness.run(for: 3_000 * ms)
        let motion = start + 20_500 * ms..<start + 23_000 * ms
        sender.report("motion", motion, capacity: Double(capacity))
        XCTAssertGreaterThan(sender.goodput(motion), 0.8 * Double(capacity))
        XCTAssertLessThan(sender.delayPercentile(0.95, motion), 20 * ms)
    }
}
