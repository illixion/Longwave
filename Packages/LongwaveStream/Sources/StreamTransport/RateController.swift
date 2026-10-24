import StreamWire

/// Section 6.2 and the allocator's input in 6.3: per viewer, FEEDBACK results
/// in, a total send budget and FEC ratio out. The host feeds every report's
/// results (`SessionEvent.feedback`), paces media at `budget.pacingRate`, and
/// sends the probe bursts `nextProbe` asks for as padding (`sealPadding`).

/// What the encoder side may spend, in bytes per second.
public struct SendBudget: Sendable, Equatable {
    /// Everything: media, parity, audio, control.
    public var total: UInt64
    /// Parity shards per data shard (`ShardingPolicy`'s ratio).
    public var fecRatio: Double

    public init(total: UInt64, fecRatio: Double) {
        self.total = total
        self.fecRatio = fecRatio
    }

    /// Section 6.4: shards leave at 1.5 × the budget.
    public var pacingRate: UInt64 { total * 3 / 2 }

    /// The video encoder's bitrate (bytes/s of bitstream) once `audio`, the
    /// parity it implies and each shard's datagram overhead are taken out.
    public func mediaRate(audio: UInt64 = 0, udpPayload: Int = DatagramLayout.defaultUDPPayload) -> UInt64 {
        guard total > audio else { return 0 }
        let shard = Double(DatagramLayout.videoShardDataCapacity(udpPayload: udpPayload))
        let wirePerByte = (1 + fecRatio) * Double(udpPayload) / shard
        return UInt64(Double(total - audio) / wirePerByte)
    }
}

/// A burst to send as padding: `rate` bytes/s for `duration` ns, each datagram
/// tagged with `id` so its results can be told apart.
public struct ProbeCluster: Sendable, Equatable {
    public var id: UInt32
    public var rate: UInt64
    public var duration: UInt64

    /// Bytes the burst carries.
    public var bytes: Int { Int(Double(rate) * Double(duration) / 1e9) }
}

/// The estimator protocol of section 6.2, so GCC and SCReAMv2 can be compared
/// on the same traces.
public protocol SendRateController: Sendable {
    var budget: SendBudget { get }
    /// One FEEDBACK report's results. `now` and the results' send times are
    /// on the sender's clock; arrivals on the receiver's.
    mutating func onFeedback(_ results: [SentPacketLog.Result], now: UInt64, rtt: UInt64)
    /// A probe burst to send now, if one is due.
    mutating func nextProbe(now: UInt64) -> ProbeCluster?
}

/// The receive rate over the last 250 ms of arrivals.
struct AcknowledgedRate: Sendable {
    static let window: UInt64 = 250_000_000
    static let minimumSpan: UInt64 = 100_000_000

    private var arrivals: [(time: UInt64, size: Int)] = []
    private var start = 0
    private var bytes = 0
    private var firstArrival: UInt64?

    mutating func add(arrival: UInt64, size: Int) {
        firstArrival = firstArrival ?? arrival
        // Reports arrive in packet order, so arrivals are nearly sorted; a
        // late one counts as of the newest so far.
        let time = max(arrival, arrivals.last?.time ?? arrival)
        arrivals.append((time, size))
        bytes += size
        while start < arrivals.count, arrivals[start].time + Self.window <= time {
            bytes -= arrivals[start].size
            start += 1
        }
        if start > 1_024, start * 2 > arrivals.count {
            arrivals.removeFirst(start)
            start = 0
        }
    }

    /// Bytes/s, once 100 ms of arrivals have been seen.
    var rate: UInt64? {
        guard let firstArrival, let last = arrivals.last?.time, last - firstArrival >= Self.minimumSpan else { return nil }
        let span = min(last - firstArrival, Self.window)
        return UInt64(Double(bytes) * 1e9 / Double(span))
    }

    /// Bytes that arrived in `range` (receiver ns), from what the window holds.
    func bytes(arrivedIn range: ClosedRange<UInt64>) -> Int {
        arrivals[start...].reduce(0) { range.contains($1.time) ? $0 + $1.size : $0 }
    }
}

/// Loss over 100 ms windows (at least 20 packets), smoothed. A packet reported
/// lost and later received is taken back.
struct LossTracker: Sendable {
    static let window: UInt64 = 100_000_000
    static let minimumPackets = 20
    static let smoothing = 0.3

    private(set) var smoothed = 0.0
    private var received = 0
    private var lost = 0
    private var windowStart: UInt64?

    mutating func add(_ result: SentPacketLog.Result, now: UInt64) {
        windowStart = windowStart ?? now
        if result.arrival == nil {
            lost += 1
        } else {
            received += 1
            if result.packet.reportedLost { lost = max(0, lost - 1) }
        }
    }

    mutating func close(now: UInt64) {
        guard let windowStart, now - windowStart >= Self.window, received + lost >= Self.minimumPackets else { return }
        let fraction = Double(lost) / Double(received + lost)
        smoothed = (1 - Self.smoothing) * smoothed + Self.smoothing * fraction
        received = 0
        lost = 0
        self.windowStart = now
    }
}

/// Google Congestion Control as section 6.2 adapts it: delay-based AIMD for
/// the rate, loss mostly turned into FEC, and probes so a still desktop
/// doesn't leave the estimate stale.
public struct GCCRateController: SendRateController {
    public struct Configuration: Sendable, Equatable {
        /// Bytes per second. 4 Mbit/s: v2's desktop start.
        public var start: UInt64 = 500_000
        public var minimum: UInt64 = 50_000
        /// 200 Mbit/s: the 4K HEVC 4:2:2 ceiling with room for parity.
        public var maximum: UInt64 = 25_000_000
        public var frameRate: Double = 60
        public var minimumFEC = 0.05
        public var maximumFEC = 0.5
        /// Loss at which the media rate is cut, not just protected.
        public var lossCutThreshold = 0.10
        public var probeDuration: UInt64 = 20_000_000
        /// Section 6.2: probes every few seconds while the encoder is under target.
        public var applicationLimitedProbeInterval: UInt64 = 5_000_000_000
        /// Smoothed queueing delay above the baseline that counts as overuse
        /// even when the delay's slope is under GCC's threshold.
        public var queueDelayCeiling: UInt64 = 20_000_000
        /// The receive rate under this share of the estimate is the encoder
        /// leaving room, so probes may measure it. Above 2/3, because growth
        /// stops at 1.5 × the receive rate: an encoder that undershoots its
        /// target (VideoToolbox on a calm desktop) holds the estimate at
        /// exactly 2/3, and a lower threshold then never probes at all.
        public var applicationLimitedRatio = 0.75
        /// After the estimate falls under a third of its recent peak, probes toward
        /// the peak this often, doubling the wait after each the link refuses
        /// up to `recoveryProbeMaximumInterval`: a Wi-Fi dip that passes is
        /// found again in a few round trips rather than at GCC's 8 %/s.
        public var recoveryProbeInterval: UInt64 = 2_000_000_000
        public var recoveryProbeMaximumInterval: UInt64 = 8_000_000_000
        /// How long a peak is remembered for recovery.
        public var recoveryWindow: UInt64 = 60_000_000_000
        /// A queue above half the ceiling is drained over about this long by
        /// holding the budget under the estimate, rather than by cutting the
        /// estimate itself (which GCC regrows only additively near the link).
        public var queueDrainTime: UInt64 = 250_000_000

        public init() {}
    }

    private struct PendingProbe: Sendable {
        var cluster: ProbeCluster
        var sentAt: UInt64
        var firstSend: UInt64?
        var lastSend: UInt64?
        var firstArrival: UInt64?
        var lastArrival: UInt64?
        var firstSize = 0
        var lastSize = 0
        var received = 0
        var lost = 0
    }

    public let configuration: Configuration
    public private(set) var usage = BandwidthUsage.normal
    /// The last probe's measured rate, for the stats overlay.
    public private(set) var lastProbeResult: UInt64?

    private var interArrival = InterArrival()
    private var trendline = TrendlineEstimator()
    private var stallFilter = StallFilter()
    private var queueDelay = QueueDelayEstimator()
    /// A probe's own burst queues at the bottleneck; overuse until this (sender
    /// clock) is the probe's doing unless the queue is far past the ceiling.
    private var probeGraceUntil: UInt64?
    /// Bytes/s held back to drain a standing queue; recomputed every report.
    private var drainAllowance: UInt64 = 0
    private var aimd: AimdRateControl
    private var acknowledged = AcknowledgedRate()
    private var loss = LossTracker()
    private var lossLimit: UInt64?
    private var lastLossUpdate: UInt64?
    private var pendingProbe: PendingProbe?
    private var nextProbeID: UInt32 = 1
    /// Rate of the next probe in an exponential sequence (start-up, or one an
    /// application-limited probe began), nil when none is due. libwebrtc's
    /// further probing: each probe the link takes most of doubles.
    private var furtherProbe: UInt64?
    /// Where the queue ceiling is in judging a queue above it (`standingQueue`).
    private enum CeilingCheck: Sendable {
        /// Cut at this time, at this receive rate; waiting for the queue to settle.
        case cut(UInt64, received: UInt64)
        /// The queue at this time, to compare with one wait later.
        case measured(UInt64, queue: Double, received: UInt64)
    }
    private var ceilingCheck: CeilingCheck?
    /// The highest estimate of the last `recoveryWindow`, and when it was set.
    private var peak: (rate: UInt64, time: UInt64)?
    private var recoveryWait: UInt64
    private var probeIsRecovery = false
    private var lastProbeAt: UInt64?
    private var underTargetSince: UInt64?
    /// Results sent around a probe, to measure the whole link during it.
    private var recentSends: [(time: UInt64, size: Int)] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        aimd = AimdRateControl(start: configuration.start, minimum: configuration.minimum,
                               maximum: configuration.maximum, frameRate: configuration.frameRate)
        furtherProbe = configuration.start * 3
        recoveryWait = configuration.recoveryProbeInterval
    }

    /// The highest budget, and the highest probe: the configured maximum, or
    /// less once the owner says what its encoder can use (`setCeiling`).
    public var maximum: UInt64 { aimd.maximum }

    /// Caps the estimate at what the sender can ever use, as libwebrtc caps
    /// it at the encoders' maximum bitrate. Without it, a still desktop's
    /// application-limited probes double the estimate every few seconds up to
    /// the configured maximum, and the pacer (1.5 × the budget) stops pacing.
    /// Bytes per second; nil restores the configured maximum.
    public mutating func setCeiling(_ bytesPerSecond: UInt64?) {
        aimd.setMaximum(min(bytesPerSecond ?? configuration.maximum, configuration.maximum))
        if let limit = lossLimit, limit > aimd.maximum { lossLimit = aimd.maximum }
    }

    /// The delay-based estimate alone.
    public var delayBasedRate: UInt64 { aimd.rate }
    public var smoothedLoss: Double { loss.smoothed }
    public var receiveRate: UInt64? { acknowledged.rate }
    /// Smoothed queueing delay above the baseline, ns.
    public var queueingDelay: UInt64 { UInt64(max(queueDelay.smoothed, 0)) }
    /// Held-and-released bursts kept out of the delay signal.
    public var stallsIgnored: Int { stallFilter.stallsDropped }
    /// Times a queue that didn't drain was taken as the path's own delay.
    public private(set) var baselineRebases = 0

    public var budget: SendBudget {
        let limited = min(aimd.rate, lossLimit ?? .max)
        let total = limited > drainAllowance ? limited - drainAllowance : 0
        let fec = min(max(2 * loss.smoothed + configuration.minimumFEC, configuration.minimumFEC), configuration.maximumFEC)
        return SendBudget(total: max(total, configuration.minimum), fecRatio: fec)
    }

    public mutating func onFeedback(_ results: [SentPacketLog.Result], now: UInt64, rtt: UInt64) {
        guard !results.isEmpty else { return }
        for result in results {
            // A lost path MTU probe was too big for the path, not congestion.
            if result.packet.pathProbe, result.arrival == nil { continue }
            loss.add(result, now: now)
            recentSends.append((result.packet.sendTime, result.packet.size))
            if let id = result.packet.probeCluster { recordProbe(id, result) }
            guard let arrival = result.arrival else { continue }
            let arrivalNs = arrival * 1_000
            acknowledged.add(arrival: arrivalNs, size: result.packet.size)
            guard let delta = interArrival.add(sendTime: result.packet.sendTime, arrival: arrivalNs, size: result.packet.size)
            else { continue }
            for kept in stallFilter.filter(delta) {
                trendline.update(kept)
                if !kept.burst { queueDelay.add(oneWay: kept.oneWay, arrival: kept.arrivalTime) }
            }
        }
        if let oldest = recentSends.first?.time, let newest = recentSends.last?.time, newest - oldest > 2_000_000_000 {
            recentSends.removeAll { $0.time + 1_000_000_000 < newest }
        }
        loss.close(now: now)
        usage = trendline.state
        let ceiling = Double(configuration.queueDelayCeiling)
        let probing = probeGraceUntil.map { now < $0 } ?? false
        if probing, queueDelay.smoothed < 2 * ceiling {
            if usage == .overusing { usage = .normal }
        } else if usage == .normal, queueDelay.smoothed > ceiling {
            usage = standingQueue(now: now, rtt: rtt, received: acknowledged.rate)
        }
        if queueDelay.smoothed <= ceiling { ceilingCheck = nil }
        let received = acknowledged.rate
        let excess = queueDelay.smoothed - ceiling / 2
        drainAllowance = excess > 0
            ? UInt64(excess / Double(configuration.queueDrainTime) * Double(received ?? aimd.rate)) : 0

        if usage == .overusing {
            if let received, aimd.mayReduceFurther(now: now, rtt: rtt, received: received) {
                aimd.update(.overusing, received: received, now: now, rtt: rtt)
            }
        } else if let result = finishProbe(now: now, rtt: rtt) {
            lastProbeResult = result
            if result > aimd.rate { aimd.set(result, now: now) }
        } else {
            aimd.update(usage, received: received, now: now, rtt: rtt)
        }
        updateLossLimit(now: now, rtt: rtt)
        trackApplicationLimit(received: received, now: now)
        trackPeak(now: now)
    }

    private mutating func trackPeak(now: UInt64) {
        if let peak, aimd.rate < peak.rate, now - peak.time < configuration.recoveryWindow {
            if aimd.rate * 3 >= peak.rate { recoveryWait = configuration.recoveryProbeInterval }
            return
        }
        peak = (aimd.rate, now)
        recoveryWait = configuration.recoveryProbeInterval
    }

    /// Above the cut threshold, loss lowers the rate by half its fraction once
    /// per 300 ms + RTT (libwebrtc's loss-based v1); under 2 % the limit lifts
    /// by 8 %/s until the delay-based estimate is the lower of the two again.
    private mutating func updateLossLimit(now: UInt64, rtt: UInt64) {
        let interval = 300_000_000 + rtt
        if let last = lastLossUpdate, now - last < interval { return }
        let elapsed = lastLossUpdate.map { now - $0 } ?? interval
        lastLossUpdate = now
        let fraction = loss.smoothed
        if fraction > configuration.lossCutThreshold {
            // libwebrtc compounds this to the minimum while loss lasts; Wi-Fi
            // loss that doesn't respond to the rate would do that every time,
            // so the cut stops at half the delay-based estimate.
            let base = min(lossLimit ?? aimd.rate, aimd.rate)
            lossLimit = max(UInt64(Double(base) * (1 - 0.5 * fraction)), aimd.rate / 2, configuration.minimum)
        } else if fraction < 0.02, let limit = lossLimit {
            let grown = UInt64(Double(limit) * (1 + 0.08 * Double(elapsed) / 1e9))
            lossLimit = grown >= aimd.rate ? nil : grown
        }
    }

    /// The ceiling's verdict on a queue above it: one cut, then the queue's
    /// direction once the cut has taken hold.
    /// - **Shrinking:** a backlog draining under the link; no further cut.
    /// - **Flat, though the receive rate fell:** the path's own delay rose (a
    ///   roam, a route change, the +20 ms of the shaped run of 2026-10-24),
    ///   and becomes the baseline. Cut every RTT instead, each at 0.85 × a
    ///   receive rate the last cut lowered, the rate fell to the floor before
    ///   the 10 s window forgot the old delay.
    /// - **Growing, or flat at the same receive rate:** a standing queue on a
    ///   full link (the cut didn't lower what is sent, as parity's floor on
    ///   small frames can), so cut again.
    /// The direction, not the level at the cut, because the cut comes as the
    /// smoothed queue crosses the ceiling, while it is still rising.
    private mutating func standingQueue(now: UInt64, rtt: UInt64, received: UInt64?) -> BandwidthUsage {
        let wait = 2 * configuration.queueDrainTime + rtt
        let receivedNow = received ?? 0
        switch ceilingCheck {
        case nil:
            ceilingCheck = .cut(now, received: receivedNow)
            return .overusing
        case .cut(let time, let atCut):
            if now - time >= wait { ceilingCheck = .measured(now, queue: queueDelay.smoothed, received: atCut) }
            return .normal
        case .measured(let time, let queue, let atCut):
            guard now - time >= wait else { return .normal }
            let change = queueDelay.smoothed - queue
            if change < -0.1 * queue {
                ceilingCheck = .measured(now, queue: queueDelay.smoothed, received: atCut)
                return .normal
            }
            if change < 0.1 * queue, Double(receivedNow) < 0.92 * Double(atCut) {
                ceilingCheck = nil
                queueDelay.rebase()
                baselineRebases += 1
                return .normal
            }
            // The cut has had its settling time; this one is judged a wait on.
            ceilingCheck = .measured(now, queue: queueDelay.smoothed, received: receivedNow)
            return .overusing
        }
    }

    private mutating func trackApplicationLimit(received: UInt64?, now: UInt64) {
        guard let received else { return }
        if Double(received) < configuration.applicationLimitedRatio * Double(aimd.rate) {
            underTargetSince = underTargetSince ?? now
        } else {
            underTargetSince = nil
        }
    }

    public mutating func nextProbe(now: UInt64) -> ProbeCluster? {
        guard pendingProbe == nil, usage != .overusing else { return nil }
        let rate: UInt64
        if let further = furtherProbe {
            rate = further
        } else if let since = underTargetSince, now - since >= 1_000_000_000,
                  now - (lastProbeAt ?? 0) >= configuration.applicationLimitedProbeInterval {
            rate = aimd.rate * 2
        } else if let peak, aimd.rate * 3 < peak.rate, usage == .normal, now - (lastProbeAt ?? 0) >= recoveryWait {
            rate = min(aimd.rate * 2, peak.rate)
            probeIsRecovery = true
        } else {
            return nil
        }
        let cluster = ProbeCluster(id: nextProbeID, rate: min(rate, maximum), duration: configuration.probeDuration)
        nextProbeID &+= 1
        pendingProbe = PendingProbe(cluster: cluster, sentAt: now)
        probeGraceUntil = now + cluster.duration + 250_000_000
        lastProbeAt = now
        return cluster
    }

    /// The owner couldn't send the last probe: forget it, and the sequence it was in.
    public mutating func abandonProbe() {
        pendingProbe = nil
        furtherProbe = nil
    }

    private mutating func recordProbe(_ id: UInt32, _ result: SentPacketLog.Result) {
        guard var probe = pendingProbe, probe.cluster.id == id else { return }
        let send = result.packet.sendTime
        if probe.firstSend.map({ send < $0 }) ?? true { probe.firstSend = send }
        if probe.lastSend.map({ send > $0 }) ?? true {
            probe.lastSend = send
            probe.lastSize = result.packet.size
        }
        if let arrival = result.arrival.map({ $0 * 1_000 }) {
            probe.received += 1
            if probe.firstArrival.map({ arrival < $0 }) ?? true {
                probe.firstArrival = arrival
                probe.firstSize = result.packet.size
            }
            if probe.lastArrival.map({ arrival > $0 }) ?? true { probe.lastArrival = arrival }
        } else {
            probe.lost += 1
        }
        pendingProbe = probe
    }

    /// libwebrtc's `ProbeBitrateEstimator`, over every packet the link carried
    /// during the burst rather than the probe's own: media interleaved with it
    /// used the same capacity. Due once feedback has had time to cover it.
    private mutating func finishProbe(now: UInt64, rtt: UInt64) -> UInt64? {
        guard let probe = pendingProbe,
              now >= probe.sentAt + probe.cluster.duration + rtt + 2 * FeedbackGenerator.defaultInterval + 20_000_000
        else { return nil }
        pendingProbe = nil
        let expected = max(probe.cluster.bytes / 1_200, 5)
        guard let firstSend = probe.firstSend, let lastSend = probe.lastSend, lastSend > firstSend,
              let firstArrival = probe.firstArrival, let lastArrival = probe.lastArrival, lastArrival > firstArrival,
              probe.received * 5 >= expected * 4
        else {
            furtherProbe = nil
            return nil
        }
        let sent = recentSends.reduce(0) { (firstSend..<lastSend).contains($1.time) ? $0 + $1.size : $0 }
        let arrived = acknowledged.bytes(arrivedIn: firstArrival...lastArrival) - probe.firstSize
        let sendRate = Double(sent) * 1e9 / Double(lastSend - firstSend)
        let receiveRate = Double(max(arrived, 0)) * 1e9 / Double(lastArrival - firstArrival)
        // A receive rate far above the send rate is a measurement artefact.
        guard receiveRate <= 2 * sendRate else {
            furtherProbe = nil
            return nil
        }
        var estimate = min(sendRate, receiveRate)
        if receiveRate < 0.9 * sendRate { estimate = 0.95 * receiveRate }
        let result = UInt64(estimate)
        // Doubling goes on while the link takes most of each probe, so a link
        // that came back is found in a few round trips, not one probe per 5 s.
        let taken = Double(result) > 0.7 * Double(probe.cluster.rate)
        furtherProbe = taken && probe.cluster.rate < maximum ? result * 2 : nil
        if probeIsRecovery, !taken { recoveryWait = min(recoveryWait * 2, configuration.recoveryProbeMaximumInterval) }
        probeIsRecovery = false
        return result
    }
}
