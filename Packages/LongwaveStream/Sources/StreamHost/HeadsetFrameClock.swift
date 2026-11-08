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
// Units: nanoseconds on the host's monotonic clock, for display times and
// arrivals alike.

public struct HeadsetFrameClock: Sendable {
    /// The host's frame period.
    public var streamInterval: Int64
    /// The headset's display period, the median of recent gaps between
    /// consecutive poses' display times; nil until a few are in.
    public private(set) var headsetPeriod: Int64?
    /// Frames whose slot could not be the planned one: the latest pose was for
    /// a later slot (the host woke late, or the headset's horizon stepped up).
    public private(set) var retargets = 0
    /// Frames started before their slot's pose had arrived.
    public private(set) var early = 0
    public private(set) var locked = 0

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
            error = (now - pose.arrival) - period / 2
        } else if ticks < 0 {
            // Behind: the latest pose is already for a later slot. Render it for
            // its own slot and plan from there.
            retargets += 1
            display = pose.display
            next = pose.display
            error = (now - pose.arrival) - period / 2
        } else {
            early += 1
            // One tick early: its pose is due one period after the latest's.
            if ticks == 1 { error = (now - (pose.arrival + period)) - period / 2 }
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
