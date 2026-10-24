/// The delay-based half of section 6.2, after Google Congestion Control as
/// libwebrtc implements it today: packet groups, a trendline over their
/// one-way delay gradient with an adaptive threshold, and AIMD on the result.
/// Constants are libwebrtc's unless a comment says otherwise.

/// What the delay gradient says about the bottleneck queue.
public enum BandwidthUsage: Sendable, Equatable {
    case normal
    /// The queue is growing: the send rate is above the link's.
    case overusing
    /// The queue is draining.
    case underusing
}

/// Packets sent within 5 ms of a group's first form one group; the delay
/// gradient is measured between consecutive groups, not packets, so a burst
/// the sender emits at once isn't read as queueing.
///
/// A packet that arrives within 5 ms of its group's last and *earlier* than
/// its send spacing predicts also joins it: that is a burst the network held
/// and released together (a Wi-Fi stall, section 7.5), and measuring across it
/// would read the release as a draining queue.
struct InterArrival: Sendable {
    struct Group: Sendable {
        var firstSend: UInt64
        var lastSend: UInt64
        var firstArrival: UInt64
        var lastArrival: UInt64
        var size: Int
        /// Some packet joined by the burst rule, not by send time.
        var burst = false
    }

    /// Between two completed groups, ns (the arrival delta can be negative).
    struct Delta: Sendable, Equatable {
        var send: Int64
        var arrival: Int64
        /// Arrival time of the newer group, ns on the receiver's clock.
        var arrivalTime: UInt64
        var size: Int
        /// The newer group is a released burst.
        var burst = false
        /// The newer group's last arrival minus its last send: one-way delay
        /// plus the unknown clock offset, so only its changes mean anything.
        var oneWay: Int64 = 0

        var gradient: Int64 { arrival - send }
    }

    static let groupLength: UInt64 = 5_000_000
    static let burstDelta: UInt64 = 5_000_000
    static let maxBurstDuration: UInt64 = 100_000_000
    /// A jump larger than this is the peer's clock or a reset, not queueing.
    static let maxArrivalOffset: Int64 = 3_000_000_000

    private var current: Group?
    private var previous: Group?

    /// `sendTime` on the sender's clock, `arrival` on the receiver's, both ns.
    /// Returns a delta when this packet completes a group.
    mutating func add(sendTime: UInt64, arrival: UInt64, size: Int) -> Delta? {
        guard var group = current else {
            current = Group(firstSend: sendTime, lastSend: sendTime, firstArrival: arrival, lastArrival: arrival, size: size)
            return nil
        }
        // Reordered, or reported late: its group is already measured.
        guard sendTime >= group.firstSend else { return nil }
        let bySendTime = sendTime - group.firstSend <= Self.groupLength
        if bySendTime || belongsToBurst(group, sendTime: sendTime, arrival: arrival) {
            if !bySendTime { group.burst = true }
            group.lastSend = max(group.lastSend, sendTime)
            group.lastArrival = max(group.lastArrival, arrival)
            group.size += size
            current = group
            return nil
        }
        var delta: Delta?
        if let previous {
            let send = Int64(group.lastSend) - Int64(previous.lastSend)
            let arrivalDelta = Int64(group.lastArrival) - Int64(previous.lastArrival)
            if arrivalDelta - send > Self.maxArrivalOffset || arrivalDelta < 0 {
                // Reset rather than feed the trendline a jump.
                self.previous = nil
            } else {
                delta = Delta(send: send, arrival: arrivalDelta, arrivalTime: group.lastArrival, size: group.size,
                              burst: group.burst, oneWay: Int64(bitPattern: group.lastArrival &- group.lastSend))
            }
        }
        previous = group
        current = Group(firstSend: sendTime, lastSend: sendTime, firstArrival: arrival, lastArrival: arrival, size: size)
        return delta
    }

    private func belongsToBurst(_ group: Group, sendTime: UInt64, arrival: UInt64) -> Bool {
        guard arrival >= group.lastArrival else { return false }
        let arrivalDelta = arrival - group.lastArrival
        let propagation = Int64(arrivalDelta) - (Int64(sendTime) - Int64(group.lastSend))
        return arrivalDelta <= Self.burstDelta && propagation < 0
            && arrival - group.firstArrival < Self.maxBurstDuration
    }
}

/// Drops the pair of deltas a held-and-released burst produces: a jump no
/// queue could build in one 5 ms group (it would take sending at 7× the
/// link), then a released burst. Deltas libwebrtc would feed its trendline
/// as heavy overuse followed by draining, and cut the rate on. A jump that
/// isn't followed by a release is real (the link collapsed) and goes through.
struct StallFilter: Sendable {
    static let jump: Int64 = 30_000_000

    private var suspect: InterArrival.Delta?
    private(set) var stallsDropped = 0

    mutating func filter(_ delta: InterArrival.Delta) -> [InterArrival.Delta] {
        var output: [InterArrival.Delta] = []
        if let held = suspect {
            suspect = nil
            if delta.burst || delta.gradient < -Self.jump / 2 {
                stallsDropped += 1
                return []
            }
            output.append(held)
        }
        if delta.gradient > Self.jump {
            suspect = delta
        } else {
            output.append(delta)
        }
        return output
    }
}

/// Section 6.2's relearned baseline: queueing delay is a group's one-way delay
/// above the lowest of the last 10 s (kept in 1 s buckets), so a path whose
/// base delay is 6–15 ms (Tailscale) isn't read as a queue, and a route change
/// that raises it is learned within the window. GCC alone reacts only to the
/// delay's slope, so a sender a percent or two over the link grows the queue
/// without bound below its threshold; the ceiling on this catches that.
struct QueueDelayEstimator: Sendable {
    static let bucket: UInt64 = 1_000_000_000
    static let buckets = 10
    static let smoothing = 0.2

    /// ns, smoothed over groups.
    private(set) var smoothed = 0.0
    private var minima: [(start: UInt64, minimum: Int64)] = []
    private var latest: Int64?

    var baseline: Int64? { minima.map(\.minimum).min() }

    /// Takes the latest one-way delay as the baseline at once, for a path
    /// whose own delay rose (the controller's call: a queue that didn't drain
    /// when the rate was cut). Lower delays later still lower it.
    mutating func rebase() {
        guard let latest, let last = minima.last else { return }
        minima = [(last.start, latest)]
        smoothed = 0
    }

    mutating func add(oneWay: Int64, arrival: UInt64) {
        latest = oneWay
        if let last = minima.last, arrival < last.start + Self.bucket {
            minima[minima.count - 1].minimum = min(last.minimum, oneWay)
        } else {
            minima.append((arrival - arrival % Self.bucket, oneWay))
            if minima.count > Self.buckets { minima.removeFirst() }
        }
        let queue = Double(oneWay - (baseline ?? oneWay))
        smoothed = (1 - Self.smoothing) * smoothed + Self.smoothing * queue
    }
}

/// libwebrtc's `TrendlineEstimator`: a least-squares slope over the last 20
/// smoothed accumulated delays, compared against a threshold that adapts to
/// the trend's own range (so a jittery path doesn't look overused all the time,
/// and a competing flow can't starve the stream by keeping it permanently cautious).
struct TrendlineEstimator: Sendable {
    static let windowSize = 20
    static let smoothing = 0.9
    static let thresholdGain = 4.0
    static let minDeltas = 60.0
    static let overusingTime = 10.0
    static let upGain = 0.0087
    static let downGain = 0.039
    static let maxAdaptOffset = 15.0

    private(set) var state = BandwidthUsage.normal
    /// ms; GCC starts at 12.5.
    private(set) var threshold = 12.5
    private(set) var trend = 0.0

    private var history: [(x: Double, y: Double)] = []
    private var firstArrival: UInt64?
    private var accumulated = 0.0
    private var smoothed = 0.0
    private var deltas = 0
    private var timeOverUsing = -1.0
    private var overuseCount = 0
    private var previousTrend = 0.0
    private var lastThresholdUpdate: Double?

    mutating func update(_ delta: InterArrival.Delta) {
        let gradient = Double(delta.arrival - delta.send) / 1e6
        let sendDelta = Double(delta.send) / 1e6
        deltas = min(deltas + 1, 1_000)
        let first = firstArrival ?? delta.arrivalTime
        firstArrival = first
        accumulated += gradient
        smoothed = Self.smoothing * smoothed + (1 - Self.smoothing) * accumulated
        let x = Double(Int64(bitPattern: delta.arrivalTime &- first)) / 1e6
        history.append((x, smoothed))
        if history.count > Self.windowSize { history.removeFirst() }
        if history.count == Self.windowSize, let slope = Self.slope(history) { trend = slope }
        detect(sendDelta: sendDelta, now: x)
    }

    private mutating func detect(sendDelta: Double, now: Double) {
        guard deltas >= 2 else {
            state = .normal
            return
        }
        let modified = min(Double(deltas), Self.minDeltas) * trend * Self.thresholdGain
        if modified > threshold {
            timeOverUsing = timeOverUsing < 0 ? sendDelta / 2 : timeOverUsing + sendDelta
            overuseCount += 1
            if timeOverUsing > Self.overusingTime, overuseCount > 1, trend >= previousTrend {
                timeOverUsing = 0
                overuseCount = 0
                state = .overusing
            }
        } else if modified < -threshold {
            timeOverUsing = -1
            overuseCount = 0
            state = .underusing
        } else {
            timeOverUsing = -1
            overuseCount = 0
            state = .normal
        }
        previousTrend = trend
        updateThreshold(modified, now: now)
    }

    private mutating func updateThreshold(_ modified: Double, now: Double) {
        let last = lastThresholdUpdate ?? now
        lastThresholdUpdate = now
        // A spike far past the threshold says nothing about its level.
        guard abs(modified) <= threshold + Self.maxAdaptOffset else { return }
        let gain = abs(modified) < threshold ? Self.downGain : Self.upGain
        threshold += gain * (abs(modified) - threshold) * min(now - last, 100)
        threshold = min(max(threshold, 6), 600)
    }

    private static func slope(_ points: [(x: Double, y: Double)]) -> Double? {
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        var numerator = 0.0
        var denominator = 0.0
        for point in points {
            numerator += (point.x - meanX) * (point.y - meanY)
            denominator += (point.x - meanX) * (point.x - meanX)
        }
        return denominator == 0 ? nil : numerator / denominator
    }
}

/// The receive rate at the last overuses: where the link's capacity probably
/// is, and how sure of it the controller is. Near it, increases are additive.
struct LinkCapacityEstimator: Sendable {
    /// kB/s, like libwebrtc's kbps but in bytes.
    private(set) var estimate: Double?
    private var deviation = 0.4

    var upperBound: Double? { estimate.map { $0 + 3 * deviationAbsolute($0) } }
    var lowerBound: Double? { estimate.map { max(0, $0 - 3 * deviationAbsolute($0)) } }

    private func deviationAbsolute(_ estimate: Double) -> Double { (deviation * estimate).squareRoot() }

    mutating func onOveruse(_ rate: UInt64) {
        let sample = Double(rate) / 1_000
        let alpha = 0.05
        guard let current = estimate else {
            estimate = sample
            return
        }
        let updated = (1 - alpha) * current + alpha * sample
        let error = updated - sample
        deviation = (1 - alpha) * deviation + alpha * error * error / max(updated, 1)
        deviation = min(max(deviation, 0.4), 2.5)
        estimate = updated
    }

    mutating func reset() {
        estimate = nil
    }
}

/// libwebrtc's `AimdRateControl`: grow 8 %/s while far from the last overuse
/// rate, about a packet per response time near it, and cut to 0.85 × the
/// measured receive rate on overuse.
struct AimdRateControl: Sendable {
    enum Phase: Sendable, Equatable { case hold, increase, decrease }

    static let beta = 0.85
    static let packetSize = 1_200.0

    let minimum: UInt64
    private(set) var maximum: UInt64
    /// Frames per second the additive step is sized for.
    let frameRate: Double
    /// Bytes per second.
    private(set) var rate: UInt64
    private(set) var phase = Phase.hold
    private(set) var link = LinkCapacityEstimator()
    private var lastChange: UInt64?
    private var lastUpdate: UInt64?

    init(start: UInt64, minimum: UInt64, maximum: UInt64, frameRate: Double = 60) {
        self.minimum = minimum
        self.maximum = maximum
        self.frameRate = frameRate
        rate = min(max(start, minimum), maximum)
    }

    /// Whether an overuse may cut again: one RTT (10–200 ms) after the last
    /// change, or at once if the receive rate has fallen under half.
    func mayReduceFurther(now: UInt64, rtt: UInt64, received: UInt64) -> Bool {
        guard let lastChange else { return true }
        let interval = min(max(rtt, 10_000_000), 200_000_000)
        return now - lastChange >= interval || received < rate / 2
    }

    /// A lower or raised ceiling; the rate comes down to it at once.
    mutating func setMaximum(_ maximum: UInt64) {
        self.maximum = max(maximum, minimum)
        rate = min(rate, self.maximum)
    }

    /// Sets the rate outright (a probe's result).
    mutating func set(_ rate: UInt64, now: UInt64) {
        self.rate = min(max(rate, minimum), maximum)
        lastChange = now
    }

    mutating func update(_ usage: BandwidthUsage, received: UInt64?, now: UInt64, rtt: UInt64) {
        switch usage {
        case .normal: if phase == .hold { phase = .increase }
        case .overusing: if phase != .decrease { phase = .decrease }
        case .underusing: phase = .hold
        }
        let elapsed = lastUpdate.map { now >= $0 ? now - $0 : 0 } ?? 0
        lastUpdate = now
        var next = rate
        switch phase {
        case .hold:
            break
        case .increase:
            if let received, let upper = link.upperBound, Double(received) / 1_000 > upper { link.reset() }
            if link.estimate != nil {
                next = rate + additiveIncrease(elapsed: elapsed, rtt: rtt)
            } else {
                let factor = pow108(seconds: min(Double(elapsed) / 1e9, 1))
                next = UInt64(Double(rate) * factor) + 125
            }
            // Don't grow past what the sender is actually getting through.
            if let received {
                let cap = received * 3 / 2 + 1_250
                if next > rate, next > cap { next = max(rate, cap) }
            }
            lastChange = now
        case .decrease:
            guard let received else { break }
            var decreased = UInt64(Self.beta * Double(received))
            if decreased > rate, let estimate = link.estimate { decreased = UInt64(Self.beta * estimate * 1_000) }
            if decreased < rate { next = decreased }
            if let lower = link.lowerBound, Double(received) / 1_000 < lower { link.reset() }
            link.onOveruse(received)
            phase = .hold
            lastChange = now
        }
        rate = min(max(next, minimum), maximum)
    }

    private func additiveIncrease(elapsed: UInt64, rtt: UInt64) -> UInt64 {
        let frameSize = Double(rate) / frameRate
        let packetsPerFrame = (frameSize / Self.packetSize).rounded(.up)
        let averagePacket = packetsPerFrame > 0 ? frameSize / packetsPerFrame : Self.packetSize
        let responseTime = Double(rtt) / 1e9 + 0.1
        let perSecond = max(500, averagePacket / responseTime)
        return UInt64(perSecond * Double(elapsed) / 1e9)
    }

    private func pow108(seconds: Double) -> Double {
        // 1.08^s without Foundation.
        var result = 1.0
        var term = 1.0
        let log108 = 0.0769610411361284
        for k in 1...8 {
            term *= seconds * log108 / Double(k)
            result += term
        }
        return result
    }
}
