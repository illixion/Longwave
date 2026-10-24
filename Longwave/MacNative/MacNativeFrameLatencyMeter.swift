import DebugTrace
import Foundation

/// How long desktop frames take to reach the decoder, logged every 5 s so
/// v2 and v3 can be compared on the same link.
///
/// Capture and encode are shared by both protocols (one encode fans out to
/// every viewer), so the protocols differ only in what this measures: from
/// the frame's capture timestamp to the moment it is whole on the headset.
/// - **Above best:** each frame's arrival minus its capture time, less the
///   window's fastest frame. Works on both protocols with no shared clock,
///   since the clocks' offset cancels; it is the delay the transport added
///   over its best case (queueing, pacing, retransmission, a large frame).
/// - **Absolute:** capture to arrival on the host's clock, when the protocol
///   has synchronised clocks (v3's §5 clock estimate). It includes capture
///   and encode time on the Mac.
nonisolated struct MacNativeFrameLatencyMeter {
    private let label: String
    private let log = DebugLogger(subsystem: "pro.longwave", category: "MacNativeLatency")
    private var windowStart: UInt64?
    /// Arrival (local) minus capture (host), wrapping, per frame.
    private var skews: [Int64] = []
    private var absolute: [UInt64] = []
    private var keyFrames = 0

    private static let window: UInt64 = 5_000_000_000

    init(label: String) {
        self.label = label
    }

    /// One frame handed to the decoder. `hostNow` is the host's clock now,
    /// when it is known.
    mutating func record(captureTime: UInt64, isKeyFrame: Bool, now: UInt64, hostNow: UInt64?) {
        windowStart = windowStart ?? now
        skews.append(Int64(bitPattern: now &- captureTime))
        if let hostNow, hostNow >= captureTime { absolute.append(hostNow - captureTime) }
        if isKeyFrame { keyFrames += 1 }
        if let start = windowStart, now - start >= Self.window { flush(now: now) }
    }

    mutating func reset() {
        windowStart = nil
        skews.removeAll()
        absolute.removeAll()
        keyFrames = 0
    }

    private mutating func flush(now: UInt64) {
        defer { reset() }
        guard let best = skews.min(), let start = windowStart else { return }
        let above = skews.map { UInt64($0 - best) }.sorted()
        let fps = Double(skews.count) * 1e9 / Double(now - start)
        var line = "\(label): \(skews.count) frames (\(String(format: "%.0f", fps)) fps, \(keyFrames) key), "
            + "above best p50 \(Self.ms(above, 0.5)) p95 \(Self.ms(above, 0.95)) max \(Self.ms(above, 1))"
        if !absolute.isEmpty {
            let sorted = absolute.sorted()
            line += "; capture to arrival p50 \(Self.ms(sorted, 0.5)) p95 \(Self.ms(sorted, 0.95)) "
                + "max \(Self.ms(sorted, 1)) min \(Self.ms(sorted, 0))"
        }
        log.notice("Frame latency \(line, privacy: .public)")
    }

    private static func ms(_ sorted: [UInt64], _ p: Double) -> String {
        let value = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        return String(format: "%.1f ms", Double(value) / 1e6)
    }
}
