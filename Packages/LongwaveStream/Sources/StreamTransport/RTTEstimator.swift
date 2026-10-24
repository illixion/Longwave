// StreamTransport: the v3 session on top of StreamCrypto's records
// (NATIVE_V3_PROTOCOL.md sections 3 to 6). The pieces here are pure state
// machines over nanosecond timestamps, so the deterministic simulator can drive
// them on virtual time; I/O and clocks come in through protocols.

/// Round-trip time, smoothed as RFC 6298 and RFC 9002 do.
///
/// Feeds the reliable channels' retransmission timeout:
/// `smoothed + 4 × variance`, at least 5 ms (section 4.1).
public struct RTTEstimator: Sendable, Equatable {
    /// Assumed before the first sample. The handshake gives one almost at once.
    public static let initialRTT: UInt64 = 50_000_000
    public static let minimumTimeout: UInt64 = 5_000_000
    public static let maximumTimeout: UInt64 = 2_000_000_000

    public private(set) var smoothed: UInt64 = RTTEstimator.initialRTT
    public private(set) var variance: UInt64 = RTTEstimator.initialRTT / 2
    public private(set) var minimum: UInt64?
    public private(set) var latest: UInt64?
    public private(set) var sampleCount = 0

    public init() {}

    /// Adds one sample. `ackDelay` is taken out when that doesn't go below the
    /// minimum seen, as RFC 9002 section 5.3 does, so a delayed ACK doesn't read
    /// as a longer path.
    public mutating func add(sample: UInt64, ackDelay: UInt64 = 0) {
        minimum = min(minimum ?? sample, sample)
        var adjusted = sample
        if let minimum, sample >= minimum + ackDelay { adjusted = sample - ackDelay }
        latest = adjusted
        if sampleCount == 0 {
            smoothed = adjusted
            variance = adjusted / 2
        } else {
            let difference = smoothed > adjusted ? smoothed - adjusted : adjusted - smoothed
            variance = (3 * variance + difference) / 4
            smoothed = (7 * smoothed + adjusted) / 8
        }
        sampleCount += 1
    }

    public var retransmissionTimeout: UInt64 {
        min(max(smoothed + 4 * variance, Self.minimumTimeout), Self.maximumTimeout)
    }

    /// How long after a later packet was acknowledged an earlier one counts as
    /// lost rather than reordered: 9/8 of the RTT, at least 1 ms (RFC 9002 6.1.2).
    public var reorderingDelay: UInt64 {
        max((max(smoothed, latest ?? 0) * 9) / 8, 1_000_000)
    }
}
