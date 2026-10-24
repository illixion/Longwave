/// Datagram packetization-layer path MTU discovery (RFC 8899, section 3's
/// "Packet size"), as a state machine without I/O. Each side probes its own
/// send direction, since paths can be asymmetric.
///
/// The session sends each probe as a PING padded to the probe size; the PONG
/// for that PING id is its acknowledgement. The search starts from the 1200
/// bytes every path takes:
/// - It probes the ceiling first, since it is usually the answer on a LAN.
/// - Otherwise it bisects towards the largest size that gets through, to
///   within 16 bytes.
/// - Once done, it confirms the size it uses every 10 s. Three lost
///   confirmations are a black hole: it falls back to the base and searches
///   again.
/// - Every 10 minutes it tries again to grow (RFC 8899's PMTU_RAISE_TIMER).
public struct PathMTUSearch: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case searching
        case complete
    }

    /// RFC 8899: MAX_PROBES 3, PROBE_TIMER at least 1 s.
    public static let maxProbes = 3
    public static let probeTimeout: UInt64 = 1_000_000_000
    public static let confirmInterval: UInt64 = 10_000_000_000
    public static let raiseInterval: UInt64 = 600_000_000_000
    /// The search stops when the gap between what got through and what didn't
    /// is this small.
    public static let granularity = 16

    private struct Probe: Sendable, Equatable {
        var size: Int
        var sentAt: UInt64
        var lost: Int
    }

    public let base: Int
    public private(set) var ceiling: Int
    /// The largest size confirmed on this path: what media is sized to.
    public private(set) var current: Int
    public private(set) var phase = Phase.searching
    /// Times a confirmed size stopped getting through.
    public private(set) var blackHoles = 0

    private var outstanding: Probe?
    /// Smallest size known not to get through.
    private var failedAbove: Int
    private var nextActionAt: UInt64?
    /// When a search that stopped under the ceiling looks upwards again.
    private var raiseAt: UInt64?

    public init(base: Int, ceiling: Int, now: UInt64) {
        self.base = base
        self.ceiling = max(ceiling, base)
        current = base
        failedAbove = self.ceiling + 1
        restart(now: now)
    }

    /// The size to probe now, if one is due. The caller sends it at once.
    public mutating func nextProbe(now: UInt64) -> Int? {
        if var probe = outstanding {
            guard now >= probe.sentAt + Self.probeTimeout else { return nil }
            probe.lost += 1
            if probe.lost < Self.maxProbes {
                outstanding = Probe(size: probe.size, sentAt: now, lost: probe.lost)
                return probe.size
            }
            outstanding = nil
            failed(probe.size, now: now)
        }
        if phase == .complete, let raiseAt, now >= raiseAt {
            // Look upwards again, keeping what media uses meanwhile.
            self.raiseAt = nil
            phase = .searching
            failedAbove = ceiling + 1
            nextActionAt = now
        }
        guard let due = nextActionAt, now >= due, let size = candidate() else { return nil }
        outstanding = Probe(size: size, sentAt: now, lost: 0)
        return size
    }

    /// A probe of `size` was acknowledged.
    public mutating func acknowledged(_ size: Int, now: UInt64) {
        guard let probe = outstanding, probe.size == size else { return }
        outstanding = nil
        if phase == .complete {
            nextActionAt = now + Self.confirmInterval // confirmed
            return
        }
        current = max(current, size)
        if current == ceiling || failedAbove - current <= Self.granularity { finish(now: now) } else { nextActionAt = now }
    }

    /// The path changed (the peer roamed, an interface came up): media drops
    /// to the base at once, and the search starts again.
    public mutating func restart(now: UInt64) {
        current = base
        failedAbove = ceiling + 1
        outstanding = nil
        raiseAt = nil
        if ceiling == base {
            phase = .complete
            nextActionAt = nil
        } else {
            phase = .searching
            nextActionAt = now
        }
    }

    /// Sets the ceiling (the hello-ack's agreed maximum) and searches again.
    public mutating func setCeiling(_ value: Int, now: UInt64) {
        ceiling = max(value, base)
        restart(now: now)
    }

    public var nextWakeTime: UInt64? {
        if let probe = outstanding { return probe.sentAt + Self.probeTimeout }
        return [nextActionAt, raiseAt].compactMap { $0 }.min()
    }

    private func candidate() -> Int? {
        switch phase {
        case .complete:
            // Confirm the size media uses; the base needs no confirming.
            return current > base ? current : nil
        case .searching:
            if failedAbove > ceiling { return ceiling }
            let middle = (current + failedAbove) / 2
            return middle > current ? middle : nil
        }
    }

    private mutating func failed(_ size: Int, now: UInt64) {
        if phase == .complete {
            // The size media uses stopped getting through.
            blackHoles += 1
            restart(now: now)
            return
        }
        failedAbove = min(failedAbove, size)
        if failedAbove - current <= Self.granularity { finish(now: now) } else { nextActionAt = now }
    }

    private mutating func finish(now: UInt64) {
        phase = .complete
        nextActionAt = current > base ? now + Self.confirmInterval : nil
        raiseAt = current < ceiling ? now + Self.raiseInterval : nil
    }
}
