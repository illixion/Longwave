import Testing
@testable import StreamHost

/// The host's frame clock against a simulated headset: poses every display
/// tick, each for a slot a whole number of ticks ahead, arriving over an
/// uplink with jitter; the host waking on its own crystal and corrected by
/// the clock's phase error, as `PCVRHost.pacingLoop` does.
@Suite struct HeadsetFrameClockTests {
    struct Run {
        var slots: [Int64] = []
        var clock: HeadsetFrameClock
    }

    /// - Parameters:
    ///   - headsetHz: display rate; poses arrive once per tick.
    ///   - streamHz: the host's frame rate.
    ///   - drift: the host crystal's error (1.001 runs 0.1% fast).
    ///   - jitter: uplink jitter, nanoseconds, deterministic pseudo-random in 0..<jitter.
    static func simulate(headsetHz: Double, streamHz: Double, drift: Double, jitter: Int64, seconds: Double,
                         startPhase: Int64 = 3_000_000) -> Run {
        let tick = Int64(1e9 / headsetHz)
        let interval = Int64(1e9 / streamHz)
        var clock = HeadsetFrameClock(streamInterval: interval)
        var run = Run(clock: clock)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func random() -> Int64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return jitter > 0 ? Int64(seed % UInt64(jitter)) : 0
        }
        // Poses: tick n is sampled at n*tick, predicted 6 ticks ahead, arrives 3 ms + jitter later.
        var poses: [(arrival: Int64, display: Int64)] = []
        let end = Int64(seconds * 1e9)
        var n: Int64 = 0
        while n * tick < end + tick {
            poses.append((n * tick + 3_000_000 + random(), n * tick + 6 * tick))
            n += 1
        }
        poses.sort { $0.arrival < $1.arrival }
        var delivered = 0
        var next = startPhase
        let hostInterval = Int64(Double(interval) / drift)
        while next < end {
            while delivered < poses.count, poses[delivered].arrival <= next {
                clock.pose(displayTime: poses[delivered].display, arrival: poses[delivered].arrival)
                delivered += 1
            }
            if let frame = clock.frame(now: next) {
                run.slots.append(frame.displayTime)
                let correction = frame.phaseError.map { max(min($0 / 10, interval / 8), -interval / 8) } ?? 0
                next += hostInterval - correction
            } else {
                next += hostInterval
            }
        }
        run.clock = clock
        return run
    }

    /// How many ticks apart consecutive frames' slots are, counted, after the first second.
    static func spacings(_ run: Run, tick: Int64, skip: Int) -> [Int64: Int] {
        var counts: [Int64: Int] = [:]
        for (a, b) in zip(run.slots.dropFirst(skip), run.slots.dropFirst(skip + 1)) {
            counts[HeadsetFrameClock.rounded(b - a, tick), default: 0] += 1
        }
        return counts
    }

    @Test func sixtyOnAHundredAndTwentyHoldsEveryFrameTwoTicks() {
        let tick = Int64(1e9 / 120)
        let run = Self.simulate(headsetHz: 120, streamHz: 60, drift: 1.001, jitter: 3_000_000, seconds: 20)
        let counts = Self.spacings(run, tick: tick, skip: 60)
        #expect(counts.keys.sorted() == [2], "\(counts)")
        #expect(run.clock.headsetPeriod.map { abs($0 - tick) < 50_000 } == true)
    }

    /// The same crystal, free-running as the host did: frames land 1, 2 and 3 ticks apart.
    @Test func freeRunningOnTheLatestPoseDoesNot() {
        let tick = Int64(1e9 / 120)
        let interval = Int64(1e9 / 60)
        var slots: [Int64] = []
        var next: Int64 = 3_000_000
        var latest: Int64 = 0
        var n: Int64 = 0
        var seed: UInt64 = 0x2545F4914F6CDD1D
        while next < 20_000_000_000 {
            while n * tick + 3_000_000 + {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                return Int64(seed % 3_000_000)
            }() <= next {
                latest = n * tick + 6 * tick
                n += 1
            }
            slots.append(latest)
            next += Int64(Double(interval) / 1.001)
        }
        var counts: [Int64: Int] = [:]
        for (a, b) in zip(slots.dropFirst(60), slots.dropFirst(61)) { counts[HeadsetFrameClock.rounded(b - a, tick), default: 0] += 1 }
        #expect(counts.count > 1, "\(counts)")
    }

    @Test func sixtyOnNinetyAlternatesOneAndTwoTicks() {
        let tick = Int64(1e9 / 90)
        let run = Self.simulate(headsetHz: 90, streamHz: 60, drift: 0.9995, jitter: 2_000_000, seconds: 20)
        let counts = Self.spacings(run, tick: tick, skip: 60)
        #expect(Set(counts.keys) == [1, 2], "\(counts)")
        // 3:2 alternates exactly: as many of each.
        #expect(abs((counts[1] ?? 0) - (counts[2] ?? 0)) <= 2, "\(counts)")
    }

    @Test func aHostAtTheHeadsetsRateTakesEveryTick() {
        let tick = Int64(1e9 / 90)
        let run = Self.simulate(headsetHz: 90, streamHz: 90, drift: 1.0008, jitter: 2_000_000, seconds: 20)
        #expect(Self.spacings(run, tick: tick, skip: 90).keys.sorted() == [1])
    }

    @Test func noPeriodYetUsesTheLatestPose() {
        var clock = HeadsetFrameClock(streamInterval: 16_666_667)
        #expect(clock.frame(now: 0) == nil)
        clock.pose(displayTime: 50_000_000, arrival: 1_000_000)
        #expect(clock.frame(now: 2_000_000) == .init(displayTime: 50_000_000, phaseError: nil))
    }
}
