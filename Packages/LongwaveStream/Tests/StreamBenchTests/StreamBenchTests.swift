import StreamBench
import StreamHost
import StreamSim
import StreamWire
import XCTest

private let ms: UInt64 = 1_000_000

final class LinkScenarioTests: XCTestCase {
    /// AWDL's holds come every 0.8–2 s and last 20–90 ms, beside the rare long ones.
    func testAWDLHoldsTheLinkEverySecondOrTwo() {
        var link = SimLink(model: LinkScenario.wifiAWDL.down, seed: 7)
        var holds: [UInt64] = []
        var t: UInt64 = 0
        var previous: UInt64 = 0
        // A datagram every millisecond for 30 s; a hold shows as arrivals bunched at its end.
        while t < 30_000 * ms {
            if let arrival = link.transmit(size: 200, now: t) {
                if arrival > previous + 15 * ms, arrival > t + 15 * ms { holds.append(arrival - t) }
                previous = max(previous, arrival)
            }
            t += ms
        }
        XCTAssertGreaterThan(link.stalled, 0)
        // 30 s at one AWDL trip per 0.8-2 s is 15-38 trips, plus a headset stall or two.
        let trips = link.stalled
        XCTAssertGreaterThan(trips, 15 * 15, "each trip holds every datagram sent during it")
        XCTAssertLessThanOrEqual(link.longestHold, 180 * ms + 2 * ms + 2 * ms)
        XCTAssertFalse(holds.isEmpty)
    }

    /// A fade runs the bottleneck slower, so the same load queues more.
    func testFadesSlowTheBottleneck() {
        var plain = LinkModel(propagationDelay: ms, rate: LinkScenario.wifi.down.rate, queueLimit: 50_000_000)
        var faded = plain
        faded.fades = .init(interval: 100 * ms...100 * ms, duration: 900 * ms...900 * ms, factor: 0.25)
        plain.queueLimit = 50_000_000
        var a = SimLink(model: plain, seed: 1), b = SimLink(model: faded, seed: 1)
        var lastA: UInt64 = 0, lastB: UInt64 = 0
        for i in 0..<20_000 {
            let now = UInt64(i) * 50_000 // 1400 B every 50 us: 224 Mbit/s offered
            lastA = max(lastA, a.transmit(size: 1400, now: now) ?? 0)
            lastB = max(lastB, b.transmit(size: 1400, now: now) ?? 0)
        }
        XCTAssertGreaterThan(lastB, lastA + 100 * ms)
    }

    /// Adding the new options leaves a link without them drawing the same numbers.
    func testOldModelsDrawTheSameSequence() {
        let model = LinkModel(propagationDelay: 2 * ms, jitter: 3 * ms, loss: 0.05, stalls: .headset)
        var a = SimLink(model: model, seed: 11), b = SimLink(model: model, seed: 11)
        for i in 0..<5_000 {
            XCTAssertEqual(a.transmit(size: 900, now: UInt64(i) * ms), b.transmit(size: 900, now: UInt64(i) * ms))
        }
    }
}

final class MotionTests: XCTestCase {
    func testRefreshScheduleSteps() throws {
        let schedule = try XCTUnwrap(RefreshSchedule(argument: "120:10,90:5,60"))
        XCTAssertEqual(schedule.hz(at: 0), 120)
        XCTAssertEqual(schedule.hz(at: 9.99), 120)
        XCTAssertEqual(schedule.hz(at: 10), 90)
        XCTAssertEqual(schedule.hz(at: 15), 60)
        XCTAssertEqual(schedule.hz(at: 1_000), 60)
        XCTAssertNil(RefreshSchedule(argument: "fast"))
    }

    /// Holding a point while the head turns right, the eyes turn left in the head.
    func testFixationCounterRotatesTheGaze() {
        var tracker = GazeTracker(model: .fixate(distance: 1.5, maxEccentricity: 0.6, dwell: 10))
        let still = HeadSample.standing
        XCTAssertEqual(tracker.direction(at: 0, head: still), [0, 0, -1])
        let yaw = -0.2 // turned right (negative yaw about +y)
        let turned = HeadSample(position: still.position, orientation: Rotation(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2)))
        let gaze = tracker.direction(at: 0.1, head: turned)
        XCTAssertLessThan(gaze[0], -0.15, "the held point is now to the left")
        XCTAssertEqual(tracker.saccades, 1)
        // Past the eccentricity limit the eyes jump to a new point ahead.
        let far = HeadSample(position: still.position, orientation: Rotation(x: 0, y: sin(-0.4), z: 0, w: cos(-0.4)))
        XCTAssertEqual(tracker.direction(at: 0.2, head: far), [0, 0, -1])
        XCTAssertEqual(tracker.saccades, 2)
    }

    func testTrajectoryInterpolates() {
        let shake = HeadTrajectory.shake(seconds: 4, rest: 1, amplitude: 0.3, hertz: 1)
        XCTAssertEqual(shake.turnRate(at: 0.5), 0, accuracy: 1e-6)
        // Peak yaw rate of A sin(2 pi f t) is 2 pi f A: 1.88 rad/s.
        XCTAssertEqual(shake.turnRate(at: 2.0), 2 * .pi * 0.3, accuracy: 0.1)
    }
}

final class StreamRunTests: XCTestCase {
    private func run(_ scenario: LinkScenario, refresh: String = "90", seconds: Double = 3,
                     encoder: ModelEncoder = ModelEncoder(), halves: Bool = true) throws -> (StreamRunResult, ModelEncoder) {
        var configuration = StreamRunConfiguration(scenario: scenario, refresh: try XCTUnwrap(RefreshSchedule(argument: refresh)),
                                                   seconds: seconds)
        configuration.seed = 5
        configuration.halvesForEncoder = halves
        let result = try StreamRun(configuration: configuration, encoder: encoder).run()
        return (result, encoder)
    }

    func testACleanLinkShowsEveryFrameOnTime() throws {
        let (result, _) = try run(.clean)
        let summary = RunSummary(label: "clean", run: result, quality: [:])
        XCTAssertGreaterThan(result.frames.count, 250)
        XCTAssertLessThanOrEqual(summary.undelivered, 2)
        XCTAssertEqual(summary.recoveries, 0)
        XCTAssertLessThan(summary.repeats, 3, summary.line)
        XCTAssertLessThan(summary.latency[1], 30, summary.line)
    }

    func testAWDLFreezesThePicture() throws {
        let (clean, _) = try run(.wifi, seconds: 6)
        let (awdl, _) = try run(.wifiAWDL, seconds: 6)
        let a = RunSummary(label: "wifi", run: clean, quality: [:]), b = RunSummary(label: "wifi-awdl", run: awdl, quality: [:])
        XCTAssertGreaterThan(b.freezes, a.freezes, "\n\(a.line)\n\(b.line)")
        XCTAssertGreaterThan(b.age[1], a.age[1], "\n\(a.line)\n\(b.line)")
    }

    /// A rebuild on each refresh step costs a key frame; reconfiguring doesn't.
    func testRefreshStepsCostKeyFramesOnlyWhenTheEncoderIsRebuilt() throws {
        let rebuild = ModelEncoder()
        let (a, _) = try run(.clean, refresh: "120:1,90:1,60:1,50", seconds: 4, encoder: rebuild, halves: false)
        let reconfigure = ModelEncoder()
        reconfigure.keyOnRateChange = false
        let (b, _) = try run(.clean, refresh: "120:1,90:1,60:1,50", seconds: 4, encoder: reconfigure, halves: false)
        XCTAssertEqual(rebuild.rebuilds, 3)
        XCTAssertEqual(a.frames.filter(\.isKey).count, b.frames.filter(\.isKey).count + 3)
        // The stream follows the display: 120, 90, 60, then 50 frames a second.
        XCTAssertEqual(Double(b.frames.filter { $0.time >= 2 && $0.time < 3 }.count), 60, accuracy: 2)
    }

    /// An encoder slower than a 120 Hz period runs the stream at 60, as the host's `--refresh auto` does.
    func testASlowEncoderHalvesTheStream() throws {
        final class Slow: BenchEncoder {
            func encode(_ request: FrameRequest) throws -> EncodedFrame {
                EncodedFrame(size: 100_000, isKey: request.forceKey, encodeSeconds: 0.010, qp: 30)
            }
        }
        var configuration = StreamRunConfiguration(scenario: .clean, refresh: RefreshSchedule(constant: 120), seconds: 2)
        configuration.seed = 5
        let result = try StreamRun(configuration: configuration, encoder: Slow()).run()
        XCTAssertEqual(Set(result.frames.map(\.hz)), [60])
        XCTAssertEqual(result.held, 0)
    }
}

final class FovealQPMapTests: XCTestCase {
    /// The CTB under each eye's warp centre gets the fovea's offset, the
    /// picture's far corners the edge's, and nothing lies outside the two.
    func testTheCentreIsSharperThanTheEdges() throws {
        let warp = PCVRProfile.defaultWarp
        let render = PixelSize(width: 5184, height: 4160)
        let wire = try XCTUnwrap(warp.wireSize(forRender: render, alignment: PCVRProfile.wireAlignment))
        let fov = FieldOfView(angleLeft: atan(-1.7666), angleRight: atan(1.02), angleUp: atan(1.02), angleDown: atan(-1.2158))
        let mirrored = FieldOfView(angleLeft: -fov.angleRight, angleRight: -fov.angleLeft, angleUp: fov.angleUp, angleDown: fov.angleDown)
        let centre = NormalizedPoint(x: 0.6, y: 0.45)
        let maps = try XCTUnwrap(StereoCentreEdgeMapping(parameters: FoveationParameters(epoch: 1, warp: .centreEdge(warp)),
                                                         frame: FoveationSideData(parameterEpoch: 1, leftCentre: centre,
                                                                                  rightCentre: NormalizedPoint(x: 0.4, y: 0.45))))
        let qp = FovealQPMap()
        let map = qp.offsets(maps: maps, fieldsOfView: (fov, mirrored), wireEye: wire)
        let size = FovealQPMap.size(width: Int(wire.width) * 2, height: Int(wire.height))
        XCTAssertEqual(map.count, size.width * size.height)
        XCTAssertEqual(size.width, 162)
        XCTAssertEqual(size.height, 65)
        // The left eye's centre in wire pixels.
        let w = try XCTUnwrap(maps.left.wireUV(forRender: centre))
        let cx = Int(w.x * Float(wire.width) / 32), cy = Int(w.y * Float(wire.height) / 32)
        XCTAssertEqual(map[cy * size.width + cx], -10)
        XCTAssertEqual(map[0], 10)
        XCTAssertEqual(map[map.count - 1], 10)
        XCTAssertTrue(map.allSatisfy { (-10...10).contains($0) })
        XCTAssertFalse(FovealQPMap(foveaQP: 0, edgeQP: 0).isEnabled)
    }
}
