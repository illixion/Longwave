@testable import StreamTransport
import StreamWire
import XCTest

private let ms: UInt64 = 1_000_000

final class RTTEstimatorTests: XCTestCase {
    func testSmoothingAndTimeoutFloor() {
        var rtt = RTTEstimator()
        XCTAssertEqual(rtt.retransmissionTimeout, 150 * ms)
        rtt.add(sample: 2 * ms)
        XCTAssertEqual(rtt.smoothed, 2 * ms)
        XCTAssertEqual(rtt.retransmissionTimeout, 6 * ms)
        for _ in 0..<50 { rtt.add(sample: 2 * ms) }
        XCTAssertEqual(rtt.retransmissionTimeout, RTTEstimator.minimumTimeout, "a steady LAN floors at 5 ms")
        rtt.add(sample: 40 * ms)
        XCTAssertGreaterThan(rtt.retransmissionTimeout, 20 * ms)
    }

    func testAckDelayIsRemovedOnlyAboveTheMinimum() {
        var rtt = RTTEstimator()
        rtt.add(sample: 3 * ms)
        rtt.add(sample: 4 * ms, ackDelay: 1 * ms)
        XCTAssertEqual(rtt.latest, 3 * ms)
        rtt.add(sample: 3 * ms, ackDelay: 2 * ms) // would go below the minimum
        XCTAssertEqual(rtt.latest, 3 * ms)
    }
}

final class ReliableChannelTests: XCTestCase {
    private func lan() -> RTTEstimator {
        var rtt = RTTEstimator()
        rtt.add(sample: 2 * ms)
        return rtt
    }

    func testInOrderDeliveryAndAck() throws {
        var sender = ReliableSender(channel: .control)
        var receiver = ReliableReceiver(channel: .control)
        let message = try MessageFraming.encode(.formatDescription, body: [1, 2, 3, 4, 5])
        sender.enqueue(message)
        let chunk = try XCTUnwrap(sender.nextChunk(maxData: 1000, now: 0, rtt: lan()))
        XCTAssertNil(sender.nextChunk(maxData: 1000, now: 0, rtt: lan()))
        XCTAssertEqual(receiver.receive(chunk, now: 1 * ms), message)
        XCTAssertEqual(receiver.ackDeadline, 2 * ms, "in-order data waits up to 1 ms for company")
        let ack = try XCTUnwrap(receiver.makeAck(now: 2 * ms))
        XCTAssertEqual(ack.cumulative, UInt64(message.count))
        XCTAssertEqual(ack.ackDelay, 1000)
        XCTAssertEqual(sender.handle(ack, now: 3 * ms, rtt: lan()), 3 * ms)
        XCTAssertTrue(sender.isIdle)
        XCTAssertNil(receiver.makeAck(now: 3 * ms))
    }

    func testLossIsRepairedAndRangesAreReported() throws {
        var sender = ReliableSender(channel: .input)
        var receiver = ReliableReceiver(channel: .input)
        sender.enqueue([UInt8](0..<30))
        let a = try XCTUnwrap(sender.nextChunk(maxData: 10, now: 0, rtt: lan()))
        let b = try XCTUnwrap(sender.nextChunk(maxData: 10, now: 0, rtt: lan()))
        let c = try XCTUnwrap(sender.nextChunk(maxData: 10, now: 0, rtt: lan()))
        XCTAssertEqual(receiver.receive(a, now: 1 * ms), Array(0..<10))
        // b is lost; c arrives and the gap forces an immediate ACK with a range.
        XCTAssertEqual(receiver.receive(c, now: 1 * ms), [])
        XCTAssertEqual(receiver.ackDeadline, 1 * ms)
        let ack = try XCTUnwrap(receiver.makeAck(now: 1 * ms))
        XCTAssertEqual(ack.cumulative, 10)
        XCTAssertEqual(ack.ranges, [.init(start: 20, end: 30)])
        _ = sender.handle(ack, now: 2 * ms, rtt: lan())
        // b was sent before c and c is acknowledged: lost once the reordering delay passes.
        XCTAssertNil(sender.nextChunk(maxData: 100, now: 2 * ms, rtt: lan()))
        _ = sender.handle(ack, now: 3 * ms, rtt: lan())
        let resend = try XCTUnwrap(sender.nextChunk(maxData: 100, now: 3 * ms, rtt: lan()))
        XCTAssertEqual(resend, b)
        XCTAssertEqual(receiver.receive(resend, now: 4 * ms), Array(10..<30))
        XCTAssertEqual(sender.retransmittedBytes, 10)
    }

    func testTimeoutResendsWithBackoffAndSplitsToFit() throws {
        var sender = ReliableSender(channel: .bulk)
        sender.enqueue([UInt8](repeating: 7, count: 100))
        _ = sender.nextChunk(maxData: 100, now: 0, rtt: lan())
        XCTAssertEqual(sender.nextTimeout(rtt: lan()), 6 * ms)
        XCTAssertNil(sender.nextChunk(maxData: 100, now: 5 * ms, rtt: lan()))
        let head = try XCTUnwrap(sender.nextChunk(maxData: 60, now: 6 * ms, rtt: lan()))
        XCTAssertEqual(head.offset, 0)
        XCTAssertEqual(head.data.count, 60)
        let tail = try XCTUnwrap(sender.nextChunk(maxData: 60, now: 6 * ms, rtt: lan()))
        XCTAssertEqual(tail.offset, 60)
        XCTAssertEqual(tail.data.count, 40)
        // Second transmission: the timeout doubles.
        XCTAssertEqual(sender.nextTimeout(rtt: lan()), 6 * ms + 12 * ms)
    }

    func testWindowLimitsInFlightAndReceiverBuffering() throws {
        var sender = ReliableSender(channel: .bulk, window: 100)
        sender.enqueue([UInt8](repeating: 1, count: 250))
        var sent = 0
        while let chunk = sender.nextChunk(maxData: 30, now: 0, rtt: lan()) { sent += chunk.data.count }
        XCTAssertEqual(sent, 100)
        XCTAssertFalse(sender.hasSendable(now: 1 * ms, rtt: lan()))

        var receiver = ReliableReceiver(channel: .bulk, window: 100)
        _ = receiver.receive(StreamChunk(channel: .bulk, offset: 90, data: [UInt8](repeating: 2, count: 50)), now: 0)
        XCTAssertEqual(receiver.heldBytes, 10, "bytes beyond cumulative + window are dropped")
    }

    func testDuplicatesAndOverlapsAreHandled() throws {
        var receiver = ReliableReceiver(channel: .control)
        let data = [UInt8](0..<40)
        _ = receiver.receive(StreamChunk(channel: .control, offset: 20, data: Array(data[20..<30])), now: 0)
        _ = receiver.receive(StreamChunk(channel: .control, offset: 25, data: Array(data[25..<35])), now: 0)
        XCTAssertEqual(receiver.heldBytes, 15)
        XCTAssertEqual(receiver.receive(StreamChunk(channel: .control, offset: 0, data: Array(data[0..<40])), now: 0), data)
        XCTAssertEqual(receiver.cumulative, 40)
        _ = receiver.makeAck(now: 0)
        XCTAssertEqual(receiver.receive(StreamChunk(channel: .control, offset: 0, data: [0]), now: 1), [])
        XCTAssertEqual(receiver.ackDeadline, 1, "a duplicate means our ACK was lost: ack at once")
    }

    /// A random lossy, reordering link: every byte arrives exactly once, in order.
    func testSoakOverALossyLink() throws {
        var rng = SplitMix64(seed: 42)
        var sender = ReliableSender(channel: .input, window: 4096)
        var receiver = ReliableReceiver(channel: .input, window: 4096)
        var rtt = lan()
        let total = 200_000
        let payload = (0..<total).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        sender.enqueue(payload)
        var delivered: [UInt8] = []
        var toReceiver: [(at: UInt64, chunk: StreamChunk)] = []
        var toSender: [(at: UInt64, ack: ChannelAck)] = []
        var now: UInt64 = 0
        while delivered.count < total {
            now += 250_000
            XCTAssertLessThan(now, 120_000 * ms, "stalled at \(delivered.count) bytes")
            if now > 120_000 * ms { break }
            while let chunk = sender.nextChunk(maxData: 1000, now: now, rtt: rtt) {
                if rng.next() % 100 < 15 { continue } // 15% loss
                toReceiver.append((now + 1 * ms + rng.next() % (3 * ms), chunk))
            }
            toReceiver.sort { $0.at < $1.at }
            while let first = toReceiver.first, first.at <= now {
                toReceiver.removeFirst()
                delivered += receiver.receive(first.chunk, now: now)
            }
            if let deadline = receiver.ackDeadline, deadline <= now, let ack = receiver.makeAck(now: now) {
                if rng.next() % 100 >= 15 { toSender.append((now + 1 * ms, ack)) }
            }
            while let first = toSender.first, first.at <= now {
                toSender.removeFirst()
                if let sample = sender.handle(first.ack, now: now, rtt: rtt) {
                    rtt.add(sample: sample, ackDelay: UInt64(first.ack.ackDelay) * 1000)
                }
            }
        }
        XCTAssertEqual(delivered, payload)
        XCTAssertGreaterThan(sender.retransmittedBytes, 0)
    }

    func testMessageReassembler() throws {
        var stream: [UInt8] = []
        for index in 0..<50 { stream += try MessageFraming.encode(.keyDown, body: [UInt8](repeating: UInt8(index), count: index)) }
        var reassembler = MessageReassembler()
        var messages: [Message] = []
        var rest = stream[...]
        var rng = SplitMix64(seed: 3)
        while !rest.isEmpty {
            let take = min(rest.count, 1 + Int(rng.next() % 17))
            reassembler.append(Array(rest.prefix(take)))
            rest = rest.dropFirst(take)
            while let message = try reassembler.next() { messages.append(message) }
        }
        XCTAssertEqual(messages.count, 50)
        XCTAssertEqual(messages[49].body.count, 49)
        XCTAssertEqual(reassembler.bufferedBytes, 0)
    }
}

final class ClockEstimatorTests: XCTestCase {
    /// A peer clock 3.7 days ahead running 40 ppm fast, with asymmetric Wi-Fi
    /// stalls: the fastest exchange per second recovers both.
    func testOffsetAndDriftUnderStalls() throws {
        var rng = SplitMix64(seed: 9)
        var estimator = ClockEstimator()
        let epochOffset: UInt64 = 320_000_000_000_000
        func remote(_ local: UInt64) -> UInt64 { epochOffset + local + UInt64(Double(local) * 40e-6) }
        var local: UInt64 = 1_000_000_000
        for _ in 0..<80 { // 20 s at 250 ms
            let up = 1 * ms + rng.next() % (rng.next() % 4 == 0 ? 150 * ms : 1 * ms)
            let down = 1 * ms + rng.next() % (rng.next() % 4 == 0 ? 150 * ms : 1 * ms)
            let t2 = remote(local + up)
            estimator.add(ClockSample(localSend: local, remoteReceive: t2, remoteSend: t2 + 50_000,
                                      localReceive: local + up + 50_000 + down))
            local += 250 * ms
        }
        XCTAssertTrue(estimator.isSynchronised)
        // Ten seconds of exchanges with up to 1 ms of path asymmetry pin the
        // drift only to tens of ppm; the mapping below is what playout uses.
        XCTAssertEqual(estimator.driftPPM, 40, accuracy: 20)
        let probe = local - 1_000 * ms
        let estimated = try XCTUnwrap(estimator.remoteTime(atLocal: probe))
        let error = Int64(bitPattern: estimated &- remote(probe))
        XCTAssertLessThan(abs(error), 300_000, "within 0.3 ms")
        let back = try XCTUnwrap(estimator.localTime(atRemote: estimated))
        XCTAssertLessThan(abs(Int64(bitPattern: back &- probe)), 2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(estimator.minimumRoundTrip), 4 * ms)
    }

    func testSingleSampleGivesAnOffsetWithoutDrift() throws {
        var estimator = ClockEstimator()
        estimator.add(ClockSample(localSend: 100, remoteReceive: 1_000_150, remoteSend: 1_000_160, localReceive: 310))
        XCTAssertEqual(estimator.driftPPM, 0)
        XCTAssertEqual(estimator.remoteTime(atLocal: 205), 1_000_155)
        // Contradictory timestamps are ignored.
        estimator.add(ClockSample(localSend: 500, remoteReceive: 10, remoteSend: 5, localReceive: 400))
        XCTAssertEqual(estimator.sampleCount, 1)
    }
}

final class PacerTests: XCTestCase {
    func testRateAndBurst() {
        var pacer = Pacer(rate: 1_000_000) // 1 MB/s; 4 ms burst = 4000 bytes
        XCTAssertEqual(pacer.delay(for: 4000, now: 0), 0)
        pacer.consume(4000, now: 0)
        XCTAssertEqual(pacer.delay(for: 1000, now: 0), 1 * ms)
        XCTAssertEqual(pacer.delay(for: 1000, now: 1 * ms), 0)
        pacer.consume(1000, now: 1 * ms)
        // Bypass traffic goes into debt.
        pacer.consume(2000, now: 1 * ms)
        XCTAssertEqual(pacer.delay(for: 1000, now: 1 * ms), 3 * ms)
        // Idle refills to the burst only.
        XCTAssertEqual(pacer.delay(for: 4000, now: 1_000 * ms), 0)
        XCTAssertEqual(pacer.delay(for: 5000, now: 1_000 * ms), 0, "a datagram bigger than the burst waits for a full bucket only")
    }
}

final class FeedbackGeneratorTests: XCTestCase {
    func testReportsLossesOnceAndLatePacketsAlone() throws {
        var generator = FeedbackGenerator()
        for number: UInt64 in [10, 11, 13, 14] { generator.record(packetNumber: number, arrival: number * ms) }
        XCTAssertEqual(generator.nextReportTime, 10 * ms, "a gap makes the report immediate")
        let first = generator.makeReports(now: 15 * ms)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].packets.map(\.packetNumber), [10, 11, 12, 13, 14])
        XCTAssertNil(first[0].packets[2].arrival)
        XCTAssertEqual(first[0].packets[3].arrival, 13_000)

        generator.record(packetNumber: 12, arrival: 16 * ms) // late
        generator.record(packetNumber: 15, arrival: 16 * ms)
        generator.record(packetNumber: 16, arrival: 17 * ms)
        XCTAssertEqual(generator.nextReportTime, 35 * ms)
        let second = generator.makeReports(now: 36 * ms)
        XCTAssertEqual(second.map { $0.packets.map(\.packetNumber) }, [[12], [15, 16]])
        XCTAssertEqual(second.map(\.reportSequence), [1, 2])
        for report in first + second { XCTAssertEqual(try Feedback(decoding: try report.encoded()), report) }
    }

    func testLargeBurstsSplitUnderTheSizeLimit() throws {
        var generator = FeedbackGenerator(maxReportBytes: 400)
        for number in UInt64(0)..<1000 { generator.record(packetNumber: number, arrival: number * 10_000) }
        let reports = generator.makeReports(now: 20 * ms)
        XCTAssertGreaterThan(reports.count, 1)
        XCTAssertEqual(reports.flatMap(\.packets).map(\.packetNumber), Array(0..<1000))
        for report in reports { XCTAssertLessThanOrEqual(try report.encoded().count, 400) }
    }

    func testSentLogMatchesReports() {
        var log = SentPacketLog(capacity: 3)
        for number in UInt64(0)..<5 { log.record(packetNumber: number, sendTime: number, size: 1000, isMedia: true) }
        XCTAssertEqual(log.count, 3)
        let report = Feedback(reportSequence: 0, referenceTime: 0, packets: [
            .init(packetNumber: 1, arrival: 5), .init(packetNumber: 2, arrival: 6), .init(packetNumber: 3, arrival: nil),
        ])
        let results = log.apply(report)
        XCTAssertEqual(results.map(\.packet.packetNumber), [2, 3], "packet 1 was evicted")
        XCTAssertEqual(log.count, 2, "the lost one is kept for a late report")
    }
}
