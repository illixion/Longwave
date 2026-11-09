//  PCVRGazeHealth.swift
//
//  Why the PC's sharp spot might not be where the wearer looks, hop by hop, in
//  words. Gaze reaches the picture over a chain, and every link can break
//  without anything else noticing (a dead feed leaves the sharp spot straight
//  ahead and the stream looks fine, only softer in the periphery of whatever
//  you look at):
//
//    1. Eyes      the gaze feed produces new samples
//    2. To PC     the v3 uplink was offered gaze, the host accepted it, and
//                 poses carry it
//    3. PC picture the foveation centres the host echoes with each frame move
//
//  The wrist HUD (FoveatedHUDView) shows the verdict. Only liveness is used:
//  sample counters, never a direction, so nothing here exports the wearer's gaze.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation

/// What a running v3 stream says about the gaze it carries. A stream registers
/// itself with `PCVRGazeUplinkRegistry` while it runs.
nonisolated struct PCVRGazeUplink: Equatable, Sendable {
    /// Gaze was offered in the hello (a gaze source was attached).
    var offered: Bool
    /// The host accepted it.
    var negotiated: Bool
    /// Poses a second that carried a gaze sample.
    var posesPerSecond: Double
    /// The host packs the eyes with the centre/edge warp.
    var foveated: Bool
    /// The last frame's full-density centres: left x, y, right x, y (render UV).
    var centres: [Float]?

    init(offered: Bool, negotiated: Bool, posesPerSecond: Double, foveated: Bool, centres: [Float]?) {
        self.offered = offered
        self.negotiated = negotiated
        self.posesPerSecond = posesPerSecond
        self.foveated = foveated
        self.centres = centres
    }
}

/// Where the HUD reads the running stream's gaze status. Nil when no stream
/// registered one.
@MainActor
enum PCVRGazeUplinkRegistry {
    static var current: (() -> PCVRGazeUplink?)?
}

/// Rates and ages the HUD can't read off one sample: how fast new gaze samples
/// arrive, when the last one did, and when the PC's centres last moved. Fed from
/// a poll (the HUD's 10 Hz clock), so everything is taken from counters.
nonisolated struct PCVRGazeWatch: Sendable {
    /// (time, sequence) over the last couple of seconds.
    private var history: [(time: TimeInterval, sequence: Int)] = []
    private(set) var lastNewSampleAt: TimeInterval?
    private var lastCentres: [Float]?
    private(set) var lastCentreMoveAt: TimeInterval?

    static let window: TimeInterval = 1.5
    /// A move smaller than this in render UV is the warp's pixel snapping or noise.
    static let centreEpsilon: Float = 0.003

    init() {}

    mutating func observe(sequence: Int?, centres: [Float]?, now: TimeInterval) {
        if let sequence {
            if let last = history.last, sequence != last.sequence { lastNewSampleAt = now }
            if history.isEmpty { lastNewSampleAt = lastNewSampleAt ?? now }
            history.append((now, sequence))
            history.removeAll { now - $0.time > Self.window }
        } else {
            history.removeAll()
            lastNewSampleAt = nil
        }
        if let centres {
            if let previous = lastCentres, previous.count == centres.count {
                let moved = zip(previous, centres).contains { abs($0 - $1) > Self.centreEpsilon }
                if moved {
                    lastCentreMoveAt = now
                    lastCentres = centres
                }
            } else {
                lastCentres = centres
                lastCentreMoveAt = lastCentreMoveAt ?? now
            }
        } else {
            lastCentres = nil
            lastCentreMoveAt = nil
        }
    }

    /// New samples a second over the window; 0 until two readings are in.
    func sampleRate() -> Double {
        guard let first = history.first, let last = history.last, last.time - first.time > 0.3,
              last.sequence >= first.sequence else { return 0 }
        return Double(last.sequence - first.sequence) / (last.time - first.time)
    }

    func sinceNewSample(now: TimeInterval) -> TimeInterval? {
        lastNewSampleAt.map { now - $0 }
    }

    func sinceCentreMoved(now: TimeInterval) -> TimeInterval? {
        lastCentreMoveAt.map { now - $0 }
    }
}

nonisolated struct PCVRGazeHealth: Equatable, Sendable {
    enum Level: Int, Comparable, Sendable {
        case idle, ok, warning, broken
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Hop: Equatable, Sendable, Identifiable {
        var name: String
        var detail: String
        var level: Level
        var id: String { name }
    }

    var level: Level
    var verdict: String
    var hops: [Hop]

    /// No new sample for this long means the feed stopped.
    static let feedTimeout: TimeInterval = 1
    /// The PC's centres standing still this long while gaze flows is suspicious.
    static let centreStillTimeout: TimeInterval = 4

    static func evaluate(hasFeed: Bool, sinceNewSample: TimeInterval?, feedRate: Double,
                         uplink: PCVRGazeUplink?, sinceCentreMoved: TimeInterval?) -> PCVRGazeHealth {
        func seconds(_ s: TimeInterval) -> String { String(format: "%.0f s", s) }

        var reasons: [(Level, String)] = []

        // 1. Eyes.
        let eyes: Hop
        if !hasFeed {
            eyes = Hop(name: "Eyes", detail: "no source", level: .broken)
            reasons.append((.broken, "No gaze source is running."))
        } else if let age = sinceNewSample {
            if age > feedTimeout {
                eyes = Hop(name: "Eyes", detail: "silent \(seconds(age))", level: .broken)
                reasons.append((.broken, "Gaze stopped \(seconds(age)) ago."))
            } else {
                eyes = Hop(name: "Eyes", detail: String(format: "%.0f/s", feedRate), level: .ok)
            }
        } else {
            eyes = Hop(name: "Eyes", detail: "no samples", level: .broken)
            reasons.append((.broken, "The gaze feed is up but has produced no samples."))
        }

        // 2. To the PC.
        let sent: Hop
        if let uplink {
            if !uplink.offered {
                sent = Hop(name: "To PC", detail: "not offered", level: .broken)
                reasons.append((.broken, "The PC stream started without gaze."))
            } else if !uplink.negotiated {
                sent = Hop(name: "To PC", detail: "declined", level: .broken)
                reasons.append((.broken, "The PC did not accept gaze (is gaze on in its host?)."))
            } else if uplink.posesPerSecond < 1 {
                sent = Hop(name: "To PC", detail: "0/s", level: .broken)
                reasons.append((.broken, "The PC accepted gaze but no pose carries a sample."))
            } else {
                sent = Hop(name: "To PC", detail: String(format: "%.0f/s", uplink.posesPerSecond), level: .ok)
            }
        } else {
            sent = Hop(name: "To PC", detail: "no stream", level: .idle)
        }

        // 3. What the PC drew.
        let picture: Hop
        if let uplink, sent.level == .ok {
            if !uplink.foveated {
                picture = Hop(name: "PC picture", detail: "not foveated", level: .warning)
                reasons.append((.warning, "The PC is not foveating, so gaze has nothing to steer."))
            } else if let still = sinceCentreMoved, still <= centreStillTimeout {
                picture = Hop(name: "PC picture", detail: "following", level: .ok)
            } else {
                let detail = sinceCentreMoved.map { "still \(seconds($0))" } ?? "no centre"
                picture = Hop(name: "PC picture", detail: detail, level: .warning)
                reasons.append((.warning, "The PC's sharp spot has not moved for \(sinceCentreMoved.map(seconds) ?? "a while"): "
                                + "looking at one point, or it ignores gaze."))
            }
        } else {
            picture = Hop(name: "PC picture", detail: "—", level: .idle)
        }

        let hops = [eyes, sent, picture]
        let level = hops.map(\.level).max() ?? .idle
        let verdict: String
        if let first = reasons.first {
            verdict = first.1
        } else if uplink == nil {
            verdict = "Gaze is live. No PC stream to send it to yet."
        } else {
            verdict = "Gaze is reaching the PC."
        }
        return PCVRGazeHealth(level: level == .idle ? .ok : level, verdict: verdict, hops: hops)
    }
}
#endif
