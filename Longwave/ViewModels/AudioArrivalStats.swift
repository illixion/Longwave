import Foundation

/// Per-window network statistics for the audio stream, computed from the
/// `PCMStamp` on every PCM payload.
///
/// This is the measurement the jitter cushion is sized from, so it has to
/// answer the questions the old metrics could not:
///
/// - **Was audio lost, or only late?** A stamp past the expected index opens a
///   hole. An unflagged hole is audio that never arrived — a Wi-Fi drop, or a
///   buffer the Mac's frame ring shed. A `resumed` flag marks the sender
///   coming back from silence suppression, which costs nothing.
/// - **Was it reordered?** A stamp *behind* the expected index is a datagram
///   that arrived after its successors were already scheduled. Playing it
///   would put audio out of order, so the receiver drops it; `late` counts
///   them, and `late ≈ holes` means reordering rather than loss.
/// - **How late does audio arrive against the media clock?** Each arrival's
///   delay is its receive time minus the capture time its sample index
///   implies. Only the variation means anything (the clocks share no
///   epoch), so the report gives percentiles above the window's minimum:
///   exactly the lead a playout buffer needs to have covered each arrival.
///   Unlike an inter-arrival gap, this does not confuse a stall with the
///   burst that follows it, and silence suppression doesn't disturb it —
///   the index advances through the silence along with the wall clock.
///
/// Mutated only on the receiver's queue.
nonisolated struct AudioArrivalStats {

    enum Disposition: Equatable {
        /// In order, or after a hole: schedule it.
        case play
        /// Behind audio already scheduled: drop it.
        case late
    }

    struct Report: Equatable {
        var payloads = 0
        /// Unflagged gaps in the sample index, and the frames they covered.
        var holes = 0
        var holeFrames = 0
        /// Payloads that arrived behind the expected index (dropped).
        var late = 0
        /// Gaps the sender flagged as the end of silence suppression.
        var resumes = 0
        /// Index jumps too large to be network loss — a restarted tap or a
        /// reset device clock. Delay statistics restart after one.
        var discontinuities = 0
        /// Arrival delay above the window minimum, in milliseconds.
        var delayP50Ms: Double = 0
        var delayP95Ms: Double = 0
        var delayP99Ms: Double = 0
        var delayMaxMs: Double = 0
    }

    let sampleRate: Double

    /// Beyond this, an unflagged index jump is a restarted stream, not loss.
    /// No playout buffer covers a two-second hole anyway, and booking a tap
    /// restart as lost audio would drown every real loss in the report.
    private let discontinuityFrames: UInt64
    /// Delay samples kept per window. ~280 payloads/s over UDP fills this in
    /// ~29 s, which only happens when reports stop being taken (the receiver
    /// is paused); the window then simply stops growing.
    static let maxDelaySamples = 8192

    private var expectedIndex: UInt64?
    private var delaysMicros: [Int64] = []
    private var report = Report()

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        discontinuityFrames = UInt64(max(1, sampleRate * 2))
        delaysMicros.reserveCapacity(Self.maxDelaySamples)
    }

    /// Records one PCM payload of `frames` sample frames, received at
    /// `arrivalNanos` on this device's uptime clock.
    mutating func record(stamp: PCMStamp, frames: Int, arrivalNanos: UInt64) -> Disposition {
        report.payloads += 1
        let start = stamp.sampleIndex
        let end = start &+ UInt64(max(0, frames))

        guard let expected = expectedIndex else {
            expectedIndex = end
            appendDelay(start: start, arrivalNanos: arrivalNanos)
            return .play
        }

        if start >= expected {
            let gap = start - expected
            if gap > 0 {
                if stamp.flags.contains(.resumed) {
                    report.resumes += 1
                } else if gap > discontinuityFrames {
                    restart()
                } else {
                    report.holes += 1
                    report.holeFrames += Int(gap)
                }
            }
            expectedIndex = end
            appendDelay(start: start, arrivalNanos: arrivalNanos)
            return .play
        }

        // Behind the expected index. Far behind is the sender's clock
        // starting over; otherwise it's a straggler whose slot is gone.
        if expected - start > discontinuityFrames {
            restart()
            expectedIndex = end
            appendDelay(start: start, arrivalNanos: arrivalNanos)
            return .play
        }
        report.late += 1
        appendDelay(start: start, arrivalNanos: arrivalNanos)
        return .late
    }

    /// Returns the window's report and starts a new window.
    mutating func takeReport() -> Report {
        var result = report
        if !delaysMicros.isEmpty {
            delaysMicros.sort()
            let sorted = delaysMicros
            let ms = { (q: Double) -> Double in
                let i = Int((Double(sorted.count - 1) * q).rounded(.down))
                return Double(sorted[i] - sorted[0]) / 1000
            }
            result.delayP50Ms = ms(0.50)
            result.delayP95Ms = ms(0.95)
            result.delayP99Ms = ms(0.99)
            result.delayMaxMs = ms(1)
        }
        report = Report()
        delaysMicros.removeAll(keepingCapacity: true)
        return result
    }

    private mutating func restart() {
        report.discontinuities += 1
        delaysMicros.removeAll(keepingCapacity: true)
    }

    private mutating func appendDelay(start: UInt64, arrivalNanos: UInt64) {
        guard delaysMicros.count < Self.maxDelaySamples else { return }
        let captureMicros = Int64(Double(start) * 1_000_000 / sampleRate)
        delaysMicros.append(Int64(arrivalNanos / 1000) - captureMicros)
    }
}
