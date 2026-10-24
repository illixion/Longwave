import StreamWire

/// One PING/PONG exchange: the four NTP timestamps (section 5). `localSend` and
/// `localReceive` are in this side's clock, `remoteReceive` and `remoteSend` in
/// the peer's, all monotonic ns.
public struct ClockSample: Sendable, Equatable {
    public var localSend: UInt64
    public var remoteReceive: UInt64
    public var remoteSend: UInt64
    public var localReceive: UInt64

    public init(localSend: UInt64, remoteReceive: UInt64, remoteSend: UInt64, localReceive: UInt64) {
        self.localSend = localSend
        self.remoteReceive = remoteReceive
        self.remoteSend = remoteSend
        self.localReceive = localReceive
    }

    public init(pong: Pong, receivedAt: UInt64) {
        self.init(localSend: pong.pingSendTime, remoteReceive: pong.receiveTime, remoteSend: pong.sendTime,
                  localReceive: receivedAt)
    }

    /// The network round trip, without the peer's turnaround; nil when the
    /// timestamps contradict each other.
    public var roundTrip: UInt64? {
        guard localReceive >= localSend, remoteSend >= remoteReceive else { return nil }
        let total = localReceive - localSend
        let turnaround = remoteSend - remoteReceive
        return total >= turnaround ? total - turnaround : nil
    }

    var localMidpoint: UInt64 { localSend + (localReceive - localSend) / 2 }
    var remoteMidpoint: UInt64 { remoteReceive + (remoteSend - remoteReceive) / 2 }
    /// remote − local at the midpoint, as a wrapping difference (the two clocks
    /// have unrelated epochs).
    var offset: Int64 { Int64(bitPattern: remoteMidpoint &- localMidpoint) }
}

/// Maps this side's clock to the peer's (section 5): `remote ≈ local + a + b·t`.
///
/// Wi-Fi stalls inflate the round trip for whole stretches, and only the
/// fastest exchanges are close to symmetric. So the estimator splits the last
/// `window` into one-second buckets and keeps each bucket's fastest exchange,
/// dropping any more than half again (plus 1 ms) slower than the window's
/// fastest. It fits offset and drift by least squares on those. With fewer
/// than three, or spanning less than `minimumSpan`, it uses the single fastest
/// offset and no drift.
public struct ClockEstimator: Sendable {
    public let window: UInt64
    public let bucket: UInt64
    public let minimumSpan: UInt64
    /// How much slower than the fastest exchange a bucket's best may be and
    /// still count: half the fastest round trip plus this.
    static let roundTripSlack: UInt64 = 1_000_000

    private var samples: [ClockSample] = []
    private var fit: (base: UInt64, offset: Double, slope: Double, baseOffset: Int64)?

    public init(window: UInt64 = 10_000_000_000, bucket: UInt64 = 1_000_000_000, minimumSpan: UInt64 = 2_000_000_000) {
        self.window = window
        self.bucket = bucket
        self.minimumSpan = minimumSpan
    }

    /// The fastest round trip in the window.
    public private(set) var minimumRoundTrip: UInt64?

    public var sampleCount: Int { samples.count }
    public var isSynchronised: Bool { fit != nil }

    /// Drift of the peer's clock against ours, parts per million.
    public var driftPPM: Double { (fit?.slope ?? 0) * 1e6 }

    public mutating func add(_ sample: ClockSample) {
        guard sample.roundTrip != nil else { return }
        samples.append(sample)
        let newest = samples.map(\.localReceive).max() ?? sample.localReceive
        samples.removeAll { newest - $0.localReceive > window }
        refit()
    }

    /// The peer's clock reading at local time `local`.
    public func remoteTime(atLocal local: UInt64) -> UInt64? {
        guard let fit else { return nil }
        let elapsed = Double(Int64(bitPattern: local &- fit.base))
        let correction = fit.offset + fit.slope * elapsed
        return local &+ UInt64(bitPattern: fit.baseOffset &+ Int64(correction.rounded()))
    }

    /// Our clock reading when the peer's clock reads `remote`.
    public func localTime(atRemote remote: UInt64) -> UInt64? {
        guard let fit else { return nil }
        // remote = local + baseOffset + offset + slope·(local − base); solve for local.
        let shifted = Double(Int64(bitPattern: remote &- fit.base &- UInt64(bitPattern: fit.baseOffset)))
        let elapsed = (shifted - fit.offset) / (1 + fit.slope)
        return fit.base &+ UInt64(bitPattern: Int64(elapsed.rounded()))
    }

    private mutating func refit() {
        var best: [UInt64: ClockSample] = [:]
        for sample in samples {
            let key = sample.localReceive / bucket
            if let current = best[key], current.roundTrip! <= sample.roundTrip! { continue }
            best[key] = sample
        }
        minimumRoundTrip = best.values.compactMap(\.roundTrip).min()
        guard let minimumRoundTrip, let fastest = best.values.min(by: { $0.roundTrip! < $1.roundTrip! }) else {
            fit = nil
            return
        }
        // A bucket whose every exchange hit a stall is no better than its
        // neighbours' noise: only near-fastest exchanges go into the fit.
        let tolerance = minimumRoundTrip / 2 + Self.roundTripSlack
        let chosen = best.values.filter { $0.roundTrip! <= minimumRoundTrip + tolerance }
            .sorted { $0.localMidpoint < $1.localMidpoint }
        // Residual offsets are small against the base, so Double keeps ns precision.
        let baseOffset = fastest.offset
        let base = fastest.localMidpoint
        let span = chosen.last!.localMidpoint - chosen.first!.localMidpoint
        guard chosen.count >= 3, span >= minimumSpan else {
            fit = (base, 0, 0, baseOffset)
            return
        }
        let xs = chosen.map { Double(Int64(bitPattern: $0.localMidpoint &- base)) }
        let ys = chosen.map { Double($0.offset &- baseOffset) }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        var covariance = 0.0
        var varianceX = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
        }
        let slope = varianceX > 0 ? covariance / varianceX : 0
        fit = (base, meanY - slope * meanX, slope, baseOffset)
    }
}
