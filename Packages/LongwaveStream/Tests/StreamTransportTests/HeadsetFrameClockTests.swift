import Testing
@testable import StreamHost

/// The host's frame clock against a simulated headset: poses every display
/// tick, each for a slot a whole number of ticks ahead, arriving over an
/// uplink with jitter; the host waking on its own crystal and corrected by
/// the clock's phase error, as `PCVRHost.pacingLoop` does.
@Suite struct HeadsetFrameClockTests {
    struct Run {
        var slots: [Int64] = []
        /// The display time of the latest pose at each frame.
        var poseDisplays: [Int64] = []
        /// Each frame's wake minus the arrival of its slot's pose (nil: that pose had not arrived).
        var wakeAfterArrival: [Int64?] = []
        var clock: HeadsetFrameClock
    }

    /// - Parameters:
    ///   - headsetHz: display rate; poses arrive once per tick.
    ///   - streamHz: the host's frame rate.
    ///   - drift: the host crystal's error (1.001 runs 0.1% fast).
    ///   - jitter: uplink jitter, nanoseconds, deterministic pseudo-random in 0..<jitter.
    static func simulate(headsetHz: Double, streamHz: Double, drift: Double, jitter: Int64, seconds: Double,
                         startPhase: Int64 = 3_000_000, horizonTicks: (Int64) -> Int64 = { _ in 6 },
                         margin: ((HeadsetFrameClock) -> Int64?)? = nil) -> Run {
        let tick = Int64(1e9 / headsetHz)
        let interval = Int64(1e9 / streamHz)
        var clock = HeadsetFrameClock(streamInterval: interval)
        var run = Run(clock: clock)
        run.poseDisplays = []
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
            poses.append((n * tick + 3_000_000 + random(), n * tick + horizonTicks(n * tick) * tick))
            n += 1
        }
        poses.sort { $0.arrival < $1.arrival }
        var arrivals: [Int64: Int64] = [:]
        for pose in poses where arrivals[pose.display] == nil { arrivals[pose.display] = pose.arrival }
        var delivered = 0
        var next = startPhase
        let hostInterval = Int64(Double(interval) / drift)
        while next < end {
            while delivered < poses.count, poses[delivered].arrival <= next {
                clock.pose(displayTime: poses[delivered].display, arrival: poses[delivered].arrival)
                delivered += 1
            }
            if let margin { clock.wakeMargin = margin(clock) }
            if let frame = clock.frame(now: next) {
                run.slots.append(frame.displayTime)
                run.wakeAfterArrival.append(arrivals[frame.displayTime].flatMap { $0 <= next ? next - $0 : nil })
                run.poseDisplays.append(poses[delivered - 1].display)
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

    /// The headset's horizon steps a tick up at 5 s and two ticks down at 10 s:
    /// a frame or two land off the cadence, then every frame is for its pose's
    /// own slot again, never for one the pose wasn't predicted for.
    @Test func horizonStepsCostAFrameOrTwo() {
        let tick = Int64(1e9 / 120)
        let run = Self.simulate(headsetHz: 120, streamHz: 60, drift: 1.0005, jitter: 2_000_000, seconds: 15,
                                horizonTicks: { t in t < 5_000_000_000 ? 6 : t < 10_000_000_000 ? 7 : 5 })
        let counts = Self.spacings(run, tick: tick, skip: 60)
        let offCadence = counts.filter { $0.key != 2 }.values.reduce(0, +)
        #expect(offCadence <= 6, "\(counts)")
        // After each step settles (a quarter second), the slot is the pose's.
        let settled = zip(run.slots, run.poseDisplays).enumerated().filter { index, _ in
            let t = Double(index) / 60
            return t > 1 && !(5...5.25).contains(t) && !(10...10.25).contains(t)
        }
        let mismatched = settled.filter { $0.element.0 != $0.element.1 }.count
        #expect(mismatched <= 3, "\(mismatched) of \(settled.count)")
    }

    /// With a margin from the measured jitter (as the host's `--wake-margin
    /// auto` sets it), the wake comes a couple of milliseconds after its
    /// slot's pose instead of half a tick (4.2 ms at 120 Hz, 8.3 at 60), and
    /// the cadence holds.
    @Test func aMeasuredMarginWakesSoonerAfterThePose() {
        let tick = Int64(1e9 / 60)
        let run = Self.simulate(headsetHz: 60, streamHz: 60, drift: 1.0005, jitter: 1_000_000, seconds: 20,
                                margin: { clock in clock.arrivalSpread.map { $0 + 1_000_000 } })
        #expect(Self.spacings(run, tick: tick, skip: 120).keys.sorted() == [1])
        let settled = run.wakeAfterArrival.dropFirst(600)
        let missed = settled.filter { $0 == nil }.count
        let waits = settled.compactMap { $0 }.map { Double($0) / 1e6 }.sorted()
        #expect(missed <= settled.count / 50, "\(missed) of \(settled.count) woke before their pose")
        let median = waits[waits.count / 2]
        #expect(median > 0.8 && median < 2.5, "median wait \(median) ms after the pose")
        #expect(run.clock.arrivalSpread.map { $0 < 1_100_000 } == true)
    }

    @Test func halfATickAfterThePoseWithoutAMargin() {
        let run = Self.simulate(headsetHz: 60, streamHz: 60, drift: 1.0005, jitter: 1_000_000, seconds: 20)
        let waits = run.wakeAfterArrival.dropFirst(600).compactMap { $0 }.map { Double($0) / 1e6 }.sorted()
        let median = waits[waits.count / 2]
        #expect(median > 7.5 && median < 9, "median wait \(median) ms after the pose")
    }

    @Test func theStreamRateIsTheDisplaysOrHalf() {
        // 9.7 ms encodes: 60 on 60, half on 90 and 120.
        #expect(StreamRate.choose(display: 60, encodeMilliseconds: 9.7, current: nil) == 60)
        #expect(StreamRate.choose(display: 90, encodeMilliseconds: 9.7, current: 90) == 45)
        #expect(StreamRate.choose(display: 120, encodeMilliseconds: 9.7, current: 60) == 60)
        // Hysteresis: 6 ms holds 120 once there (under 85% of 8.3 ms) but
        // does not step up to it (over 70%).
        #expect(StreamRate.choose(display: 120, encodeMilliseconds: 6.5, current: 120) == 120)
        #expect(StreamRate.choose(display: 120, encodeMilliseconds: 6.5, current: 60) == 60)
        #expect(StreamRate.choose(display: 120, encodeMilliseconds: 5.5, current: 60) == 120)
        // No measure yet: half, unless already at the display's rate.
        #expect(StreamRate.choose(display: 90, encodeMilliseconds: nil, current: nil) == 45)
        #expect(StreamRate.choose(display: 90, encodeMilliseconds: nil, current: 90) == 90)
        // A ceiling below the display's rate: half.
        #expect(StreamRate.choose(display: 120, encodeMilliseconds: 3, current: 120, ceiling: 100) == 60)
    }

    @Test func noPeriodYetUsesTheLatestPose() {
        var clock = HeadsetFrameClock(streamInterval: 16_666_667)
        #expect(clock.frame(now: 0) == nil)
        clock.pose(displayTime: 50_000_000, arrival: 1_000_000)
        #expect(clock.frame(now: 2_000_000) == .init(displayTime: 50_000_000, phaseError: nil))
    }
}
