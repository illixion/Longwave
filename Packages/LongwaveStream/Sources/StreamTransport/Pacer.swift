/// Token-bucket pacer (section 6.4): media datagrams leave at `rate` with a
/// burst of about `burst` ns worth of data, instead of a whole frame at once.
///
/// Audio, input and control bypass the queue (strict priority) but are
/// charged here too, so they come out of the same budget; that can take the
/// bucket below zero, which simply delays the next media datagram.
public struct Pacer: Sendable, Equatable {
    /// Bytes per second.
    public private(set) var rate: UInt64
    public let burst: UInt64
    /// Positive: bytes that may leave now. Negative: debt from bypass traffic.
    private var tokens: Double
    private var updatedAt: UInt64?

    /// `rate` in bytes per second; `burst` in ns of data at that rate (4 ms).
    public init(rate: UInt64, burst: UInt64 = 4_000_000) {
        self.rate = max(rate, 1)
        self.burst = burst
        tokens = Double(self.rate) * Double(burst) / 1e9
    }

    private var capacity: Double { Double(rate) * Double(burst) / 1e9 }

    public mutating func setRate(_ rate: UInt64, now: UInt64) {
        refill(now: now)
        self.rate = max(rate, 1)
        tokens = min(tokens, capacity)
    }

    /// How long until `bytes` may leave (0 if now).
    public mutating func delay(for bytes: Int, now: UInt64) -> UInt64 {
        refill(now: now)
        let shortfall = min(Double(bytes), capacity) - tokens
        guard shortfall > 0 else { return 0 }
        return UInt64((shortfall / Double(rate) * 1e9).rounded(.up))
    }

    /// Charges `bytes` that left at `now`.
    public mutating func consume(_ bytes: Int, now: UInt64) {
        refill(now: now)
        tokens -= Double(bytes)
    }

    private mutating func refill(now: UInt64) {
        if let updatedAt, now > updatedAt {
            tokens = min(capacity, tokens + Double(now - updatedAt) * Double(rate) / 1e9)
        }
        if updatedAt.map({ now > $0 }) ?? true { updatedAt = now }
    }
}
