#if FOVEATED_ENABLED
import Foundation
import XCTest
@testable import Longwave

extension PCVRWarpBenchTests {
    struct ResidualTiming: Codable {
        var displayHz: Int
        var model: String
        var uniquePairs: Int
        var repeats: Int
        var busyDisplayTicks: Int
        var maxPendingColours: Int
        var meanFrameGenerationAgeMs: Double
        var maxFrameGenerationAgeMs: Double
    }
    private struct ReplayFrame: PCVRTimedPlayoutFrame {
        var streamEpoch: UInt32 = 1
        var spaceEpoch: UInt16 = 0
        var frameNumber: UInt32
        var arrivalTime: TimeInterval
        var displayTime: TimeInterval
        var poseSequence: UInt32 { frameNumber }
    }

    /// Virtual time drives the production timed queue and exact pair selector.
    /// Models delayed/lost depth and GPU-busy ticks without needing a hot AVP.
    func testResidualTimingReplay() throws {
        var report: [ResidualTiming] = []
        for rate in [50, 60, 90, 120] {
            for stressed in [false, true] {
                let period = 1 / Double(rate), sourceRate = 60.0
                let gpuMs = stressed ? 12.0 : 4.0
                let delay = stressed ? 0.075 : 0.045
                var colours: [ReplayFrame] = []
                var depths: [(UInt32, Double)] = []
                for n in 0..<180 {
                    let generated = Double(n) / sourceRate
                    let colourJitter: Double = n % 7 == 0 ? 0.004 : 0
                    colours.append(ReplayFrame(frameNumber: UInt32(n), arrivalTime: generated + delay + colourJitter,
                                               displayTime: generated + 0.080))
                    if n % 11 != 0 {
                        let depthJitter: Double = n % 5 == 0 ? 0.030 : 0
                        depths.append((UInt32(n), generated + delay - 0.003 + depthJitter))
                    }
                }
                colours.sort { $0.arrivalTime < $1.arrivalTime }
                depths.sort { $0.1 < $1.1 }
                var store: [UInt32] = []
                var queue = PCVRPacedFrameQueue<ReplayFrame>()
                var pairs = PCVRPairedFrameQueue<ReplayFrame, UInt32>()
                var busyUntil = 0.0, previous: UInt32?, unique = 0, repeats = 0, busy = 0, peakPending = 0
                var ageSum = 0.0, ageMax = 0.0, presented = 0
                for tick in 0..<(rate * 3) {
                    let now = Double(tick) * period
                    while let first = colours.first, first.arrivalTime <= now {
                        _ = queue.deliver(colours.removeFirst())
                    }
                    while let first = depths.first, first.1 <= now {
                        store.append(depths.removeFirst().0)
                        if store.count > 6 { store.removeFirst() }
                    }
                    guard now >= busyUntil else { busy += 1; continue }
                    let ready = queue.takeForPresentation(spaceEpoch: 0, now: now, until: now + 2.5 * period + period / 2)
                    guard let frame = ready.frame,
                          let pair = pairs.select(frame, exactDepth: { store.contains($0) ? $0 : nil }) else { continue }
                    XCTAssertEqual(pair.depth, pair.frame.frameNumber, "never substitute nearby depth")
                    if let previous {
                        XCTAssertTrue(pair.frame.frameNumber == previous || PCVRSerialNumber.isNewer(pair.frame.frameNumber, than: previous))
                    }
                    if pair.frame.frameNumber == previous { repeats += 1 }
                    else { unique += 1; busyUntil = now + gpuMs / 1000 }
                    previous = pair.frame.frameNumber
                    peakPending = max(peakPending, pairs.pending.count)
                    XCTAssertLessThanOrEqual(pairs.pending.count, 3)
                    let age = (now - Double(pair.frame.frameNumber) / sourceRate) * 1000
                    ageSum += age; ageMax = max(ageMax, age); presented += 1
                }
                XCTAssertGreaterThan(unique, 30)
                report.append(ResidualTiming(displayHz: rate, model: stressed ? "12ms GPU with late/lost depth" : "4ms GPU with late/lost depth",
                    uniquePairs: unique, repeats: repeats, busyDisplayTicks: busy, maxPendingColours: peakPending,
                    meanFrameGenerationAgeMs: ageSum / Double(max(presented, 1)), maxFrameGenerationAgeMs: ageMax))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("timing-report.json"))
    }
}
#endif
