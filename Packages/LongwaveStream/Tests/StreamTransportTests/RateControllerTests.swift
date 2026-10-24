@testable import StreamTransport
import StreamWire
import XCTest

private let ms: UInt64 = 1_000_000

final class DelayBasedEstimatorTests: XCTestCase {
    func testPacketsGroupBySendBurst() {
        var groups = InterArrival()
        // Three 5 ms bursts of three packets, each arriving 1 ms after it left.
        var deltas: [InterArrival.Delta] = []
        for burst in UInt64(0)..<4 {
            for packet in UInt64(0)..<3 {
                let send = burst * 10 * ms + packet * ms
                if let delta = groups.add(sendTime: send, arrival: send + ms, size: 1_000) { deltas.append(delta) }
            }
        }
        // Group 2 against 1 completes when group 3 starts; group 3 when 4 does.
        XCTAssertEqual(deltas.count, 2)
        XCTAssertEqual(deltas.first?.send, Int64(10 * ms))
        XCTAssertEqual(deltas.first?.arrival, Int64(10 * ms))
        XCTAssertEqual(deltas.first?.size, 3_000)
    }

    func testAStallReleaseIsOneBurst() {
        var groups = InterArrival()
        var deltas: [InterArrival.Delta] = []
        // Packets every 2 ms, 1 ms in flight; everything due from 20 to 120 ms
        // is held and released at 120 ms.
        for index in UInt64(0)..<80 {
            let natural = index * 2 * ms + ms
            let arrival = (20 * ms..<120 * ms).contains(natural) ? 120 * ms : natural
            if let delta = groups.add(sendTime: index * 2 * ms, arrival: arrival, size: 1_000) { deltas.append(delta) }
        }
        // The held packets join one group (at most 100 ms of them), so the
        // release reads as one negative gradient, not one per 5 ms of packets.
        let gradients = deltas.map { ($0.arrival - $0.send) / Int64(ms) }
        XCTAssertEqual(gradients.filter { $0 < -10 }.count, 1, "\(gradients)")
        XCTAssertLessThan(deltas.count, 15, "\(gradients)")
    }

    private var arrival: UInt64 = 100 * ms

    private func run(_ trendline: inout TrendlineEstimator, groups: Int, gradient: Int64) -> [BandwidthUsage] {
        var states: [BandwidthUsage] = []
        for _ in 0..<groups {
            arrival = UInt64(Int64(arrival) + Int64(5 * ms) + gradient)
            trendline.update(.init(send: Int64(5 * ms), arrival: Int64(5 * ms) + gradient, arrivalTime: arrival, size: 6_000))
            states.append(trendline.state)
        }
        return states
    }

    func testTrendlineSeesAGrowingQueue() {
        var steady = TrendlineEstimator()
        XCTAssertFalse(run(&steady, groups: 200, gradient: 0).contains(.overusing))

        // The queue grows 0.5 ms per 5 ms group: the link takes 10 % less than is sent.
        var growing = TrendlineEstimator()
        let states = run(&growing, groups: 60, gradient: Int64(ms / 2))
        XCTAssertEqual(states.last, .overusing)
        XCTAssertNil(states.prefix(19).firstIndex(of: .overusing), "needs a full window first")

        // Draining after that is underuse.
        XCTAssertEqual(run(&growing, groups: 40, gradient: -Int64(ms / 2)).last, .underusing)
    }

    func testThresholdAdaptsToJitterButNotToSpikes() {
        var trendline = TrendlineEstimator()
        XCTAssertEqual(trendline.threshold, 12.5)
        // Small alternating gradients pull the threshold down to its floor.
        for index in 0..<400 {
            let gradient = index % 2 == 0 ? Int64(ms / 10) : -Int64(ms / 10)
            trendline.update(.init(send: Int64(5 * ms), arrival: Int64(5 * ms) + gradient,
                                   arrivalTime: 100 * ms + UInt64(index) * 5 * ms, size: 6_000))
        }
        XCTAssertEqual(trendline.threshold, 6, accuracy: 0.5)
    }

    func testAIMDGrowsEightPercentASecondAndCutsToThePercentReceived() {
        var aimd = AimdRateControl(start: 1_000_000, minimum: 10_000, maximum: 100_000_000)
        aimd.update(.normal, received: nil, now: 0, rtt: 2 * ms)
        for step in UInt64(1)...50 { aimd.update(.normal, received: nil, now: step * 20 * ms, rtt: 2 * ms) }
        // 8 % over the second, plus libwebrtc's 1 kbit/s floor on each step.
        XCTAssertEqual(Double(aimd.rate), 1_086_400, accuracy: 2_000)

        // Overuse at a 900 kB/s receive rate: 0.85 × that.
        aimd.update(.overusing, received: 900_000, now: 1_100 * ms, rtt: 2 * ms)
        XCTAssertEqual(aimd.rate, 765_000)
        XCTAssertEqual(aimd.phase, .hold)
        XCTAssertFalse(aimd.mayReduceFurther(now: 1_105 * ms, rtt: 2 * ms, received: 700_000))
        XCTAssertTrue(aimd.mayReduceFurther(now: 1_111 * ms, rtt: 2 * ms, received: 700_000))
        XCTAssertTrue(aimd.mayReduceFurther(now: 1_105 * ms, rtt: 2 * ms, received: 300_000), "collapsed: at once")

        // Near the last overuse rate, growth is about a packet per response time.
        aimd.update(.normal, received: 765_000, now: 1_200 * ms, rtt: 2 * ms)
        let before = aimd.rate
        aimd.update(.normal, received: 765_000, now: 2_200 * ms, rtt: 2 * ms)
        XCTAssertEqual(Double(aimd.rate - before), 1_190 / 0.102, accuracy: 500)
    }

    func testAIMDDoesNotGrowPastWhatGetsThrough() {
        var aimd = AimdRateControl(start: 1_000_000, minimum: 10_000, maximum: 100_000_000)
        for step in UInt64(0)...200 { aimd.update(.normal, received: 100_000, now: step * 50 * ms, rtt: 2 * ms) }
        XCTAssertEqual(aimd.rate, 1_000_000, "an application-limited sender holds, it neither grows nor falls")
    }
}

final class GCCRateControllerTests: XCTestCase {
    /// Results for packets of 1,200 bytes every `spacing`, arriving after a
    /// fixed delay, with every `lossEvery`-th lost.
    private func feed(_ controller: inout GCCRateController, from start: UInt64, for duration: UInt64,
                      spacing: UInt64, lossEvery: Int?, number: inout UInt64) -> UInt64 {
        var now = start
        var batch: [SentPacketLog.Result] = []
        var lastReport = start
        while now < start + duration {
            let lost = lossEvery.map { number % UInt64($0) == 0 } ?? false
            let entry = SentPacketLog.Entry(packetNumber: number, sendTime: now, size: 1_200, isMedia: true)
            batch.append(.init(packet: entry, arrival: lost ? nil : (now + 2 * ms) / 1_000, ecn: .notECT))
            number += 1
            now += spacing
            if now - lastReport >= 20 * ms {
                controller.onFeedback(batch, now: now + 4 * ms, rtt: 4 * ms)
                batch.removeAll()
                lastReport = now
            }
        }
        return now
    }

    func testLossRaisesFECAndOnlyHeavyLossCutsTheRate() {
        var configuration = GCCRateController.Configuration()
        configuration.start = 1_000_000
        var light = GCCRateController(configuration: configuration)
        light.startupProbeDone()
        var number: UInt64 = 0
        // 1.2 MB/s with 5 % loss for 3 s.
        _ = feed(&light, from: 0, for: 3_000 * ms, spacing: ms, lossEvery: 20, number: &number)
        XCTAssertEqual(light.smoothedLoss, 0.05, accuracy: 0.01)
        XCTAssertEqual(light.budget.fecRatio, 0.15, accuracy: 0.02)
        XCTAssertEqual(light.budget.total, light.delayBasedRate, "under 10 % loss the rate is the delay-based estimate")

        var heavy = GCCRateController(configuration: configuration)
        heavy.startupProbeDone()
        number = 0
        _ = feed(&heavy, from: 0, for: 3_000 * ms, spacing: ms, lossEvery: 5, number: &number)
        XCTAssertEqual(heavy.smoothedLoss, 0.2, accuracy: 0.02)
        XCTAssertEqual(heavy.budget.fecRatio, 0.45, accuracy: 0.04)
        XCTAssertLessThan(Double(heavy.budget.total), Double(heavy.delayBasedRate) * 0.8)
    }

    func testStartupProbesDoubleUntilTheLinkStopsTakingThem() throws {
        var controller = GCCRateController()
        let first = try XCTUnwrap(controller.nextProbe(now: 0))
        XCTAssertEqual(first.rate, 1_500_000)
        XCTAssertEqual(first.duration, 20 * ms)
        XCTAssertNil(controller.nextProbe(now: ms), "one at a time")

        // The link delivers the burst at the rate it was sent.
        var batch: [SentPacketLog.Result] = []
        let count = UInt64(first.bytes / 1_200)
        let spacing = 1_200 * 1_000_000_000 / first.rate
        for index in 0..<count {
            var entry = SentPacketLog.Entry(packetNumber: index, sendTime: index * spacing, size: 1_200, isMedia: false)
            entry.probeCluster = first.id
            batch.append(.init(packet: entry, arrival: (index * spacing + 2 * ms) / 1_000, ecn: .notECT))
        }
        controller.onFeedback(batch, now: 25 * ms, rtt: 4 * ms)
        controller.onFeedback([], now: 120 * ms, rtt: 4 * ms)
        // Empty feedback doesn't run the controller; a report with anything does.
        let late = SentPacketLog.Entry(packetNumber: count, sendTime: 110 * ms, size: 100, isMedia: false)
        controller.onFeedback([.init(packet: late, arrival: 112_000, ecn: .notECT)], now: 120 * ms, rtt: 4 * ms)
        let result = try XCTUnwrap(controller.lastProbeResult)
        XCTAssertEqual(Double(result), 1_500_000, accuracy: 100_000)
        XCTAssertGreaterThanOrEqual(controller.delayBasedRate, result)
        let second = try XCTUnwrap(controller.nextProbe(now: 130 * ms))
        XCTAssertEqual(Double(second.rate), 2 * Double(result), accuracy: 1)
    }

    func testBudgetSplitsOutAudioAndParity() {
        let budget = SendBudget(total: 2_000_000, fecRatio: 0.25)
        XCTAssertEqual(budget.pacingRate, 3_000_000)
        // 1,900,000 left over, ÷ 1.25 for parity, ÷ 1200/1144 for each shard's datagram overhead.
        XCTAssertEqual(Double(budget.mediaRate(audio: 100_000)), 1_900_000 / 1.25 * 1_144 / 1_200, accuracy: 1)
        XCTAssertEqual(budget.mediaRate(audio: 3_000_000), 0)
    }

    func testLateArrivalTakesBackAReportedLoss() {
        var log = SentPacketLog()
        log.record(packetNumber: 1, sendTime: 0, size: 1_000, isMedia: true)
        let lost = log.apply(Feedback(reportSequence: 0, referenceTime: 0, packets: [.init(packetNumber: 1, arrival: nil)]))
        XCTAssertEqual(lost.first?.packet.reportedLost, false)
        let late = log.apply(Feedback(reportSequence: 1, referenceTime: 5, packets: [.init(packetNumber: 1, arrival: 5)]))
        XCTAssertEqual(late.first?.packet.reportedLost, true)
        XCTAssertTrue(log.apply(Feedback(reportSequence: 2, referenceTime: 5, packets: [.init(packetNumber: 1, arrival: 5)])).isEmpty)
    }
}

extension GCCRateController {
    /// Skips start-up probing, for tests that feed results directly.
    mutating func startupProbeDone() {
        while nextProbe(now: 0) != nil { abandonProbe() }
    }
}
