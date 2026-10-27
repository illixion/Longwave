import Accelerate
import Foundation

/// Sheds a playout backlog without changing pitch.
///
/// After a stall the link delivers the missing audio as a burst, and the
/// queue ends up longer than the target. The receiver used to shed that by
/// resampling the incoming audio 2% fast, which is a pitch rise of a third
/// of a semitone for as long as it lasts — audible on sustained notes, and
/// most of all on a notification or a track starting out of silence, where
/// the burst after the sender's resume lands right on the onset.
///
/// This removes time instead of compressing it, in two ways:
///
/// - **Quiet audio is dropped outright.** A stretch below ~−60 dBFS (the
///   sender's warm-keep silence is exact zeros) can simply be cut; nobody
///   hears a shorter silence. This is tried first and is not rate-limited.
/// - **Audible audio is spliced, WSOLA-style.** At the front of the held
///   audio it finds the shift `d` (4-16 ms) at which the waveform best
///   matches itself — a whole number of pitch periods on tonal content — and
///   crossfades from the current position to `d` frames later, removing `d`
///   frames. Pitch and timbre are untouched; what is lost is a few
///   milliseconds of repetition. Splices are spaced to `ratio` of the audio
///   passing through, so the backlog drains at a steady, gentle pace.
///
/// Splicing needs to see ahead, so while shedding it holds back
/// `lookaheadFrames` (~26 ms at 48 kHz). That is free: it only does so while
/// the queue is already over target by more than that. When shedding ends
/// the held audio is released in order and the stream passes through
/// untouched.
///
/// Mutated only on the receiver's queue.
nonisolated struct AudioBacklogShedder {
    let channels: Int
    let sampleRate: Double
    /// Share of the audio passing through that splices may remove (0.04 sheds
    /// 300 ms in ~7.5 s). Quiet drops are not counted against it.
    let ratio: Double

    /// Crossfade length of an audible splice, and the correlation window.
    let crossfadeFrames: Int
    /// Range of the splice shift — 4-16 ms covers one or more periods of
    /// anything from a low male voice to a bass line's upper harmonics.
    let minShiftFrames: Int
    let maxShiftFrames: Int
    /// Fade used across a quiet cut. Both sides are below the quiet threshold
    /// anyway; this just keeps even that step smooth.
    let quietFadeFrames: Int
    /// Peak below which audio counts as quiet (−60 dBFS).
    static let quietThreshold: Float = 0.001
    /// Below this normalized correlation the best match is still a poor one
    /// (a transient, noise) and splicing would be heard as a smear; wait for
    /// the next stretch instead.
    static let minimumCorrelation: Float = 0.25

    /// Audio held back for splicing, one array per channel.
    private(set) var pending: [[Float]]
    /// Frames splices are currently allowed to remove, earned at `ratio` of
    /// the audio appended.
    private var credit: Double = 0

    /// Audio removed, split by how — for the health log.
    private(set) var quietFramesShed = 0
    private(set) var splicedFramesShed = 0

    init(channels: Int, sampleRate: Double, ratio: Double = 0.04) {
        self.channels = max(1, channels)
        self.sampleRate = sampleRate
        self.ratio = ratio
        let ms = { (milliseconds: Double) in max(1, Int(milliseconds / 1000 * sampleRate)) }
        crossfadeFrames = ms(10)
        minShiftFrames = ms(4)
        maxShiftFrames = ms(16)
        quietFadeFrames = ms(1)
        pending = Array(repeating: [], count: self.channels)
    }

    var pendingFrames: Int { pending[0].count }

    /// How much must be held for an audible splice to have room to search.
    var lookaheadFrames: Int { maxShiftFrames + crossfadeFrames }

    var totalFramesShed: Int { quietFramesShed + splicedFramesShed }

    /// Appends `frames` sample frames, reading each sample from
    /// `sample(frame, channel)`.
    mutating func append(frames: Int, sample: (Int, Int) -> Float) {
        guard frames > 0 else { return }
        for channel in 0..<channels {
            pending[channel].reserveCapacity(pending[channel].count + frames)
            for frame in 0..<frames {
                pending[channel].append(sample(frame, channel))
            }
        }
        credit = min(credit + Double(frames) * ratio, Double(2 * maxShiftFrames))
    }

    /// Removes up to `budget` frames from the held audio — quiet stretches
    /// first, then at most one audible splice. Returns the frames removed.
    @discardableResult
    mutating func shed(budget: Int) -> Int {
        var remaining = budget
        var removed = 0
        while remaining > 0 {
            let quiet = dropQuiet(limit: remaining)
            guard quiet > 0 else { break }
            remaining -= quiet
            removed += quiet
        }
        if remaining > 0 {
            removed += splice(limit: remaining)
        }
        return removed
    }

    /// Frames ready to schedule: everything past the lookahead while
    /// shedding, everything when not.
    func releasable(holdingBack: Bool) -> Int {
        holdingBack ? max(0, pendingFrames - lookaheadFrames) : pendingFrames
    }

    /// Removes and returns the first `count` frames, one array per channel.
    mutating func take(_ count: Int) -> [[Float]] {
        let n = min(count, pendingFrames)
        guard n > 0 else { return Array(repeating: [], count: channels) }
        var out: [[Float]] = []
        out.reserveCapacity(channels)
        for channel in 0..<channels {
            out.append(Array(pending[channel][0..<n]))
            pending[channel].removeFirst(n)
        }
        return out
    }

    /// Discards held audio — for when it is stale (an engine rebuild, a
    /// local unpause), not merely late.
    mutating func reset() {
        for channel in 0..<channels { pending[channel].removeAll(keepingCapacity: true) }
        credit = 0
    }

    // MARK: - Quiet drop

    /// Cuts quiet audio at the front of the held audio, keeping the
    /// crossfade inside the quiet stretch so nothing audible is touched.
    private mutating func dropQuiet(limit: Int) -> Int {
        let fade = quietFadeFrames
        var run = 0
        let count = pendingFrames
        scan: while run < count {
            for channel in 0..<channels where abs(pending[channel][run]) >= Self.quietThreshold {
                break scan
            }
            run += 1
        }
        let shift = min(limit, run - fade)
        guard shift > 0 else { return 0 }
        crossfade(shift: shift, length: fade)
        quietFramesShed += shift
        return shift
    }

    // MARK: - Audible splice

    /// One WSOLA splice at the front of the held audio, if credit, lookahead
    /// and the material all allow it.
    private mutating func splice(limit: Int) -> Int {
        let window = crossfadeFrames
        let maxShift = min(maxShiftFrames, limit)
        guard maxShift >= minShiftFrames,
              credit >= Double(minShiftFrames),
              pendingFrames >= maxShift + window else { return 0 }

        // Match on the channel average; a stereo mix shares its periodicity.
        let span = maxShift + window
        var mono = [Float](repeating: 0, count: span)
        let scale = 1 / Float(channels)
        for channel in 0..<channels {
            let samples = pending[channel]
            for i in 0..<span { mono[i] += samples[i] * scale }
        }

        var referenceEnergy: Float = 0
        for i in 0..<window { referenceEnergy += mono[i] * mono[i] }
        // Running energy of the candidate window, slid one frame per shift.
        var candidateEnergy: Float = 0
        for i in minShiftFrames..<(minShiftFrames + window) { candidateEnergy += mono[i] * mono[i] }

        var bestShift = 0
        var bestScore = Self.minimumCorrelation
        mono.withUnsafeBufferPointer { m in
            for shift in minShiftFrames...maxShift {
                if shift > minShiftFrames {
                    let leaving = m[shift - 1]
                    let entering = m[shift + window - 1]
                    candidateEnergy += entering * entering - leaving * leaving
                }
                var dot: Float = 0
                vDSP_dotpr(m.baseAddress!, 1, m.baseAddress! + shift, 1, &dot, vDSP_Length(window))
                let norm = (referenceEnergy * max(candidateEnergy, 0)).squareRoot()
                guard norm > 1e-9 else { continue }
                let score = dot / norm
                if score > bestScore {
                    bestScore = score
                    bestShift = shift
                }
            }
        }
        guard bestShift > 0 else { return 0 }

        crossfade(shift: bestShift, length: window)
        credit -= Double(bestShift)
        splicedFramesShed += bestShift
        return bestShift
    }

    /// Replaces the front with a raised-cosine crossfade from
    /// `pending[0..<length]` into `pending[shift..<shift+length]`, followed
    /// by everything after it — removing `shift` frames. The first output
    /// sample is the first held sample, so the join with audio already
    /// scheduled stays continuous.
    private mutating func crossfade(shift: Int, length: Int) {
        let length = min(length, pendingFrames - shift)
        guard length >= 0 else { return }
        for channel in 0..<channels {
            pending[channel].withUnsafeMutableBufferPointer { samples in
                for i in 0..<length {
                    let t = length > 1 ? Float(i) / Float(length - 1) : 1
                    let fadeIn = 0.5 - 0.5 * cos(Float.pi * t)
                    samples[i] = samples[i] * (1 - fadeIn) + samples[shift + i] * fadeIn
                }
            }
            // Drop the `shift` frames between the faded region and the
            // continuation that follows the faded-in copy.
            pending[channel].removeSubrange(length..<(length + shift))
        }
    }
}
