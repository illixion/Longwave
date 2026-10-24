import StreamFEC
import StreamHost
import StreamPlayout
import StreamSim
@testable import StreamTransport
import StreamWire
import XCTest

private let ms: UInt64 = 1_000_000

/// The package's own sender and receiver end to end: an encoder at whatever
/// `VideoStreamSender` allows, gated on `canAcceptFrame`, key frames on
/// request, and `VideoStreamReceiver` on the client asking for NACKs and
/// recovery. Each access unit carries its encoder sequence so the client can
/// check every frame it decodes byte for byte.
private final class StreamPair {
    let harness: Harness
    let index: UInt32
    var sender = VideoStreamSender(configuration: .init(streamID: 1))
    var receiver = VideoStreamReceiver(streamID: 1)
    var encoderSequence: UInt32 = 0
    var nextFrameAt: UInt64
    var forceKeyFrame = true
    /// Frames the gate held back, as the capture does.
    var held = 0
    var keyFrames = 0
    var decoded: [UInt32] = []
    var corrupted = 0
    var recoveries = 0
    /// Encoder sequences in the order they were queued for this viewer.
    var queuedSequences: [UInt32] = []
    var bitrates: [Int] = []
    /// (host time, bytes) per media datagram sent, and the budget then.
    var wire: [(time: UInt64, bytes: Int, budget: UInt64)] = []

    init(harness: Harness, index: UInt32) {
        self.harness = harness
        self.index = index
        nextFrameAt = harness.now
        harness.tick = { [unowned self] h in self.tick(h) }
        harness.tickWake = { [unowned self] h in self.wake(h) }
    }

    static func accessUnit(_ sequence: UInt32, size: Int) -> [UInt8] {
        var bytes = withUnsafeBytes(of: sequence.littleEndian, Array.init)
        bytes += (0..<max(size - 4, 0)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(sequence)) }
        return bytes
    }

    private func tick(_ h: Harness) {
        guard let session = h.host.sessions[index]?.session else { return }
        let udpPayload = session.udpPayload
        let rtt = session.rtt.smoothed
        for event in h.hostReceivedEvents {
            switch event {
            case .feedback(_, let results):
                sender.onFeedback(results, now: h.hostNow, rtt: rtt)
            case .nack(let nack):
                sender.handle(nack)
            case .message(.control, let message) where message.type == .recoveryRequest:
                recoveries += 1
                sender.recoveryRequested()
                forceKeyFrame = true
            default:
                break
            }
        }
        h.hostEvents.removeAll()

        // The encoder: a frame per 1/60 s at the sender's bitrate, a key frame
        // five times that, held back while the sender's queue is full.
        while h.now >= nextFrameAt {
            nextFrameAt += 16_666_667
            guard sender.canAcceptFrame else {
                held += 1
                continue
            }
            let bitrate = sender.encoderBitrate(udpPayload: udpPayload)
            bitrates.append(bitrate)
            let key = forceKeyFrame || sender.awaitingKeyFrame
            let size = max(bitrate / 8 / 60 * (key ? 5 : 1), 500)
            let unit = Self.accessUnit(encoderSequence, size: size)
            if case .queued = try! sender.submit(accessUnit: unit, isKeyFrame: key, captureTime: h.hostNow,
                                                 udpPayload: udpPayload, now: h.hostNow) {
                queuedSequences.append(encoderSequence)
                if key { keyFrames += 1 }
                forceKeyFrame = false
            }
            encoderSequence += 1
        }
        while let output = sender.next(now: h.hostNow) {
            let datagram: [UInt8]? = h.host.withSession(index) { session in
                switch output {
                case .shard(let header, let data): try? session.sealVideo(header, data: data, now: h.hostNow)
                case .padding(let size, let cluster): try? session.sealPadding(size: size, probeCluster: cluster, now: h.hostNow)
                }
            } ?? nil
            if let datagram {
                if case .shard = output { wire.append((h.now, datagram.count, sender.controller.budget.total)) }
                h.network.send(datagram, from: .host, to: .client, now: h.now)
            }
        }

        // The client.
        var outputs: [VideoStreamReceiver.Output] = []
        for event in h.clientEvents {
            guard case .video(let header, let data) = event else { continue }
            outputs += receiver.receive(header, data: data, now: h.now)
        }
        h.clientEvents.removeAll()
        outputs += receiver.poll(now: h.now, rtt: h.client!.rtt.smoothed)
        for output in outputs {
            switch output {
            case .frame(let frame):
                let unit = Array(frame.payload.accessUnit)
                let sequence = unit.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                decoded.append(sequence)
                if unit != Self.accessUnit(sequence, size: unit.count) { corrupted += 1 }
            case .nack(let nack):
                h.client!.send(nack)
            case .recovery(let request):
                try! h.client!.send(.recoveryRequest, body: request.encoded(), on: .control)
            }
        }
    }

    private func wake(_ h: Harness) -> UInt64? {
        var wakes = [nextFrameAt, h.now + 2 * ms]
        if let next = sender.nextWakeTime(now: h.hostNow) { wakes.append(next - h.hostEpoch) }
        if let next = receiver.nextWakeTime(now: h.now) { wakes.append(next) }
        return wakes.min()
    }
}

final class VideoStreamSimulationTests: XCTestCase {
    private func pair(down: LinkModel, seed: UInt64 = 3) throws -> StreamPair {
        let harness = Harness(down: down, seed: seed)
        harness.run(for: 50 * ms)
        return StreamPair(harness: harness, index: try XCTUnwrap(harness.hostIndex))
    }

    /// A 20 Mbit/s link at 0, 2% and 10% loss: every decoded frame is byte for
    /// byte what was encoded, in order, and the rate climbs to the link.
    func testDesktopStreamThroughLoss() throws {
        for loss in [0.0, 0.02, 0.10] {
            var down = LinkModel(propagationDelay: 2 * ms, jitter: 1 * ms, rate: 2_500_000, loss: loss)
            down.queueLimit = 256 * 1024
            let stream = try pair(down: down)
            stream.harness.run(for: 10_000 * ms)

            let label = "\(Int(loss * 100))%"
            let tail = stream.bitrates.suffix(120)
            let meanBitrate = tail.reduce(0, +) / max(tail.count, 1)
            print("video stream \(label): decoded \(stream.decoded.count) of \(stream.queuedSequences.count) queued, "
                  + "held \(stream.held), keys \(stream.keyFrames), recoveries \(stream.recoveries), "
                  + "resent \(stream.sender.statistics.shardsResent), parity dropped \(stream.sender.statistics.parityDropped), "
                  + "bitrate \(meanBitrate / 1_000) kbit/s, fec \(stream.sender.controller.budget.fecRatio)")
            XCTAssertEqual(stream.corrupted, 0, label)
            XCTAssertEqual(stream.decoded, stream.decoded.sorted(), "\(label): decode order")
            XCTAssertEqual(Set(stream.decoded).count, stream.decoded.count, "\(label): each frame once")
            XCTAssertTrue(Set(stream.decoded).isSubset(of: stream.queuedSequences), label)
            let decodedFraction = Double(stream.decoded.count) / Double(stream.queuedSequences.count)
            XCTAssertGreaterThan(decodedFraction, loss < 0.05 ? 0.99 : 0.95, label)
            // Video alone on a 20 Mbit/s link climbs well past the 4 Mbit/s
            // start; 10% loss sits at the loss cut's threshold, and holds it down.
            XCTAssertGreaterThan(meanBitrate, loss < 0.05 ? 12_000_000 : 5_000_000, label)
            XCTAssertLessThanOrEqual(stream.recoveries, loss < 0.05 ? 1 : 10, label)
        }
    }

    /// A 3 Mbit/s link, as in the shaped run of 2026-10-24: what goes on the
    /// wire stays inside the budget. At this rate a 60 fps frame is a handful
    /// of shards, and the two parity shards each frame carries whatever the
    /// FEC ratio were a third again on top of a budget that counted 5 %.
    func testWeakLinkStaysInsideItsBudget() throws {
        var down = LinkModel(propagationDelay: 2 * ms, jitter: 1 * ms, rate: 375_000, loss: 0)
        down.queueLimit = 150_000
        let stream = try pair(down: down)
        stream.harness.run(for: 15_000 * ms)
        let start = stream.harness.now - 7_000 * ms
        let window = stream.wire.filter { $0.time >= start }
        let sent = Double(window.reduce(0) { $0 + $1.bytes }) * 1e9 / Double(7_000 * ms)
        let budget = Double(window.reduce(0) { $0 + $1.budget }) / Double(max(window.count, 1))
        let decodedFraction = Double(stream.decoded.count) / Double(stream.queuedSequences.count)
        print("weak link: sent \(Int(sent / 1_000)) kB/s against a budget of \(Int(budget / 1_000)) kB/s, "
              + "decoded \(stream.decoded.count) of \(stream.queuedSequences.count), held \(stream.held), "
              + "recoveries \(stream.recoveries)")
        XCTAssertLessThan(sent, 1.1 * budget, "parity's floor is in the encoder's bitrate")
        XCTAssertGreaterThan(sent, 0.6 * 375_000, "and the link is still used")
        XCTAssertGreaterThan(decodedFraction, 0.95)
        XCTAssertEqual(stream.corrupted, 0)
    }

    /// The link goes dark for 300 ms: the client asks for recovery, the host
    /// sends a key frame, and decoding resumes from it.
    func testOutageRecoversWithAKeyFrame() throws {
        let stream = try pair(down: LinkModel(propagationDelay: 2 * ms, jitter: 0, rate: 2_500_000, loss: 0))
        stream.harness.run(for: 3_000 * ms)
        let before = stream.decoded.count
        let keysBefore = stream.keyFrames
        stream.harness.network.setModel(LinkModel(propagationDelay: 2 * ms, jitter: 0, rate: 2_500_000, loss: 1),
                                        from: .host, to: .client)
        stream.harness.run(for: 300 * ms)
        stream.harness.network.setModel(LinkModel(propagationDelay: 2 * ms, jitter: 0, rate: 2_500_000, loss: 0),
                                        from: .host, to: .client)
        stream.harness.run(for: 2_000 * ms)
        XCTAssertGreaterThan(stream.recoveries, 0)
        XCTAssertGreaterThan(stream.keyFrames, keysBefore)
        XCTAssertGreaterThan(stream.decoded.count, before + 90, "decoding resumed")
        XCTAssertEqual(stream.corrupted, 0)
        XCTAssertFalse(stream.receiver.awaitingKeyFrame)
    }
}
