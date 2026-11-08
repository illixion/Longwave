// HeadsetFrameClock.swift
//
// Locks the host's frame clock to the headset's display, as its head poses
// show it. Every pose names the display slot it was predicted for (the
// headset sends one per display tick, its horizon a whole number of periods),
// so the poses' display times lie on the headset's display grid. The host
// renders at its own rate (`streamInterval`, often every second tick) and,
// without this, on its own crystal: it took whichever pose had arrived last,
// so consecutive frames were for slots one, two or three ticks apart and the
// headset held them 1, 2, 3 or 4 slots (60 fps on a 120 Hz display,
// 2026-11-08: 209 of 402 frames held the 2 slots they should have, 42 shown a
// second). Here each frame's slot is one stream interval after the last's,
// snapped to the grid, and the phase error says how far the host's wake is
// from halfway between the arrival of that slot's pose and the next tick's,
// where the uplink's jitter is least likely to cross it.
//
// Where in that gap: half a tick after the pose, by default, or `wakeMargin`
// after it arrives as the uplink usually delivers it (`arrivalSpread` says how
// much later than that it can be). Half a tick is 8 ms at 60 Hz, and grows as
// the display slows; the uplink's jitter, measured, was under 2 ms
// (2026-11-08). Every millisecond the wake comes sooner is one off the time
// from pose to photon, and a whole tick of it can come off the headset's
// prediction horizon.
//
// Units: nanoseconds on the host's monotonic clock, for display times and
// arrivals alike.

public struct HeadsetFrameClock: Sendable {
    /// The host's frame period.
    public var streamInterval: Int64
    /// The headset's display period, the median of recent gaps between
    /// consecutive poses' display times; nil until a few are in.
    public private(set) var headsetPeriod: Int64?
    /// Frames whose slot could not be the planned one: the latest pose was for
    /// a later slot (the host woke late, or the headset's horizon stepped up),
    /// or for one at least two ticks earlier (the horizon stepped down).
    public private(set) var retargets = 0
    /// Frames started one tick before their slot's pose arrived.
    public private(set) var early = 0
    public private(set) var locked = 0
    /// How long after its slot's pose usually arrives the host aims to wake;
    /// nil, or until arrivals are measured: half a period after the pose.
    /// Kept under three quarters of a period.
    public var wakeMargin: Int64?
    /// How much later than usual (the 5th percentile of recent arrivals,
    /// against their display times) a pose arrives at the 95th percentile;
    /// nil until 16 are in since the horizon last changed.
    public private(set) var arrivalSpread: Int64?
    private var latencies: [Int64] = []
    /// The usual arrival, as a pose's arrival minus its display time.
    private var baseLatency: Int64?

    private var lastPose: (display: Int64, arrival: Int64)?
    private var gaps: [Int64] = []
    /// The last frame's display time before snapping (3:2 cadences need the
    /// unsnapped value to come back to the grid).
    private var ideal: Int64?

    public init(streamInterval: Int64) {
        self.streamInterval = streamInterval
    }

    public struct Frame: Sendable, Equatable {
        /// The display slot this frame is for.
        public var displayTime: Int64
        /// How late the wake was against the ideal phase (negative: early),
        /// when it could be measured. Pull the next wake earlier by a fraction of it.
        public var phaseError: Int64?
    }

    /// A pose arrived at `arrival`, predicted for `displayTime`.
    public mutating func pose(displayTime: Int64, arrival: Int64) {
        if let last = lastPose {
            let gap = displayTime - last.display
            // One tick between consecutive poses; anything else (a lost pose, a
            // horizon step, a stall) says nothing about the period.
            if gap > 2_000_000, gap < 40_000_000 {
                gaps.append(gap)
                if gaps.count > 31 { gaps.removeFirst(gaps.count - 31) }
                if gaps.count >= 5 { headsetPeriod = gaps.sorted()[gaps.count / 2] }
            }
        }
        lastPose = (displayTime, arrival)
        // Arrival against display time: constant but for the uplink's jitter,
        // until the horizon steps (a whole period), which starts it over.
        let latency = arrival - displayTime
        if let last = latencies.last, abs(latency - last) > (headsetPeriod ?? 8_000_000) / 2 {
            latencies.removeAll()
            baseLatency = nil
            arrivalSpread = nil
        }
        latencies.append(latency)
        if latencies.count > 64 { latencies.removeFirst(latencies.count - 64) }
        if latencies.count >= 16 {
            let sorted = latencies.sorted()
            let base = sorted[sorted.count / 20]
            baseLatency = base
            arrivalSpread = sorted[(sorted.count - 1) * 95 / 100] - base
        }
    }

    /// How late `now` is for a wake aimed at `wakeMargin` after the usual
    /// arrival of the pose for `display`; nil without a margin or a measure.
    private func marginError(now: Int64, display: Int64, period: Int64) -> Int64? {
        guard let margin = wakeMargin, let base = baseLatency else { return nil }
        return now - (display + base) - min(max(margin, 0), period * 3 / 4)
    }

    /// The frame the host starts at `now`; nil without a pose yet.
    public mutating func frame(now: Int64) -> Frame? {
        guard let pose = lastPose else { return nil }
        guard let period = headsetPeriod, period > 0 else {
            ideal = pose.display
            return Frame(displayTime: pose.display, phaseError: nil)
        }
        let planned = (ideal ?? pose.display - streamInterval) + streamInterval
        let ticks = Self.rounded(planned - pose.display, period)
        var display = pose.display + ticks * period
        var error: Int64?
        var next = planned
        if ticks == 0 {
            locked += 1
            error = marginError(now: now, display: pose.display, period: period) ?? (now - pose.arrival) - period / 2
        } else if ticks < 0 {
            // Behind: the latest pose is already for a later slot. Render it for
            // its own slot and plan from there.
            retargets += 1
            display = pose.display
            next = pose.display
            error = marginError(now: now, display: pose.display, period: period) ?? (now - pose.arrival) - period / 2
        } else if ticks == 1 {
            // One tick early: its pose is due one period after the latest's.
            early += 1
            error = marginError(now: now, display: display, period: period)
                ?? (now - (pose.arrival + period)) - period / 2
        } else {
            // Two or more ticks ahead of every pose: the headset's horizon
            // stepped down (or the uplink is stalled). Waiting it out would
            // render every frame for a pose that old; take the latest for its
            // own slot instead.
            retargets += 1
            display = pose.display
            next = pose.display
        }
        // Back to the grid if the plan wandered more than a tick from it.
        if abs(next - display) > period { next = display }
        ideal = next
        return Frame(displayTime: display, phaseError: error)
    }

    /// `value / unit` to the nearest whole number.
    static func rounded(_ value: Int64, _ unit: Int64) -> Int64 {
        value >= 0 ? (value + unit / 2) / unit : -((-value + unit / 2) / unit)
    }
}

/// The rate the host renders at for a headset display rate: the display's
/// own, when the encoder has the headroom for it, else half of it, so every
/// frame is held a whole number of display slots (a third rate, 60 on 90, is
/// a 3:2 cadence and judders by construction). The headset re-places the
/// picture by head pose every display slot either way, so only the scene's
/// own animation runs at the lower rate.
public enum StreamRate {
    /// The encoder's 95th-percentile time per frame may fill this much of a
    /// period at the display's own rate, stepping down past `stepDown` and
    /// back up only under `stepUp`.
    public static let stepDown = 0.85
    public static let stepUp = 0.7

    /// - Parameters:
    ///   - display: the headset's display rate, Hz.
    ///   - encodeMilliseconds: the encoder's 95th percentile per frame, recently; nil if unknown.
    ///   - current: the rate now.
    ///   - ceiling: the most the host may run at (the headset's decoder, a setting).
    public static func choose(display: Double, encodeMilliseconds: Double?, current: Double?,
                              ceiling: Double = .infinity) -> Double {
        let full = display, half = display / 2
        guard full <= ceiling else { return half }
        guard let encode = encodeMilliseconds else { return current.map { $0 == full ? full : half } ?? half }
        let period = 1000 / full
        if current == full { return encode <= period * stepDown ? full : half }
        return encode <= period * stepUp ? full : half
    }
}
