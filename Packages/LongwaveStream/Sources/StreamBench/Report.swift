// Numbers a run is judged by, and the one-line and long summaries the bench
// prints. Quality is the PC bench's (it has the pictures); timing is the
// loop's.
import Foundation

/// How good one encoded frame is, measured on the PC against the truth.
public struct FrameQuality: Sendable, Equatable, Codable {
    /// What the headset would show at the gaze point (a box of render pixels
    /// round it, both eyes) against the rendered truth: warp and codec together.
    public var gazePSNR: Double
    public var gazeSSIM: Double
    /// The same box through the warp alone (unencoded wire): the warp's share.
    public var gazeWarpPSNR: Double
    /// Detail shown at the gaze, as high-frequency energy against the truth's
    /// (1 = all of it; blur and blocks both lower it).
    public var gazeDetail: Double
    /// The codec alone, in the wire picture: the full-density centre box, the
    /// compressed edges, and block-edge excess in the centre (0 = none).
    public var centrePSNR: Double
    public var centreSSIM: Double
    public var edgePSNR: Double
    public var blockiness: Double
    /// The head's turn rate at capture, degrees per second.
    public var turnRate: Double
    /// Left eye, render UV (top-left origin): where the eyes looked, and where
    /// the warp's full-density centre was.
    public var gazeUV: [Double] = []
    public var centreUV: [Double] = []

    public init(gazePSNR: Double, gazeSSIM: Double, gazeWarpPSNR: Double, gazeDetail: Double, centrePSNR: Double,
                centreSSIM: Double, edgePSNR: Double, blockiness: Double, turnRate: Double) {
        self.gazePSNR = gazePSNR
        self.gazeSSIM = gazeSSIM
        self.gazeWarpPSNR = gazeWarpPSNR
        self.gazeDetail = gazeDetail
        self.centrePSNR = centrePSNR
        self.centreSSIM = centreSSIM
        self.edgePSNR = edgePSNR
        self.blockiness = blockiness
        self.turnRate = turnRate
    }
}

public enum Stats {
    public static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    /// `p` in 0...1, nearest rank.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

/// A run boiled down: the numbers compared between settings.
public struct RunSummary: Sendable, Codable {
    public var label: String
    public var frames: Int
    public var keyFrames: Int
    public var held: Int
    public var undelivered: Int
    public var recoveries: Int
    public var meanMbps: Double
    /// Frames a second the stream ran at, on average (halved while the encoder can't keep up).
    public var streamHz: Double
    /// QP, all frames and moving ones (turn rate over `movingRate`).
    public var qpMean: Double
    public var qpMovingMean: Double
    public var qpMax: Int
    /// Last shard to capture, ms: p50, p95, p99.
    public var latency: [Double]
    /// Capture to the display tick that showed it, ms, p50 and p95.
    public var age: [Double]
    /// Ticks that repeated the last tick's frame while the stream ran at the display's rate, %.
    public var repeats: Double
    /// Runs of 4+ ticks on one frame.
    public var freezes: Int
    /// Tick-weighted quality of what was on screen: all ticks, moving ticks, the worst 5% of moving ticks.
    public var gazePSNR: [Double]
    public var gazeSSIM: [Double]
    public var gazeDetail: [Double]
    public var centrePSNR: [Double]
    public var blockiness: [Double]

    public static let movingRate = 40.0

    public init(label: String, run: StreamRunResult, quality: [Int: FrameQuality]) {
        self.label = label
        let frames = run.frames
        self.frames = frames.count
        keyFrames = frames.filter(\.isKey).count
        held = run.held
        undelivered = frames.filter { !$0.decodable }.count
        recoveries = run.recoveryRequests
        let seconds = max((frames.last?.time ?? 0) - (frames.first?.time ?? 0), 1e-3)
        meanMbps = Double(frames.reduce(0) { $0 + $1.size }) * 8 / seconds / 1e6
        streamHz = Double(max(frames.count - 1, 0)) / seconds
        let moving = frames.filter { (quality[$0.index]?.turnRate ?? 0) > Self.movingRate }
        qpMean = Stats.mean(frames.map { Double($0.qp) })
        qpMovingMean = Stats.mean(moving.map { Double($0.qp) })
        qpMax = frames.map(\.qp).max() ?? 0
        let latencies = frames.compactMap { f in f.completed.map { ($0 - f.time) * 1000 } }
        latency = [0.5, 0.95, 0.99].map { Stats.percentile(latencies, $0) }
        let ages = run.ticks.compactMap { $0.age.map { $0 * 1000 } }
        age = [0.5, 0.95].map { Stats.percentile(ages, $0) }
        var repeated = 0, eligible = 0, freezes = 0, run4 = 0
        for (i, tick) in run.ticks.enumerated() where i > 0 {
            guard let frame = tick.frame else { continue }
            let streamHz = frames[frame].hz
            guard abs(streamHz - tick.hz) < 1 else { continue }
            eligible += 1
            if run.ticks[i - 1].frame == frame {
                repeated += 1
                run4 += 1
                if run4 == 3 { freezes += 1 }
            } else {
                run4 = 0
            }
        }
        repeats = eligible > 0 ? Double(repeated) * 100 / Double(eligible) : 0
        self.freezes = freezes
        // Quality as seen: each tick counts the frame it showed.
        let shown = run.ticks.compactMap { tick in tick.frame.flatMap { quality[$0] } }
        let shownMoving = shown.filter { $0.turnRate > Self.movingRate }
        func three(_ key: (FrameQuality) -> Double, worstIsLow: Bool = true) -> [Double] {
            let all = shown.map(key).filter(\.isFinite), mov = shownMoving.map(key).filter(\.isFinite)
            return [Stats.mean(all), Stats.mean(mov), Stats.percentile(mov, worstIsLow ? 0.05 : 0.95)]
        }
        gazePSNR = three(\.gazePSNR)
        gazeSSIM = three(\.gazeSSIM)
        gazeDetail = three(\.gazeDetail)
        centrePSNR = three(\.centrePSNR)
        blockiness = three(\.blockiness, worstIsLow: false)
    }

    public static let header = "label                           |  fps   Mbps  QP(all/mov/max) | key rec und held | lat p50/p95/p99 ms | age p50/p95 | rep%  frz | gaze dB all/mov/worst | SSIM mov | detail mov | centre dB mov | block mov/worst"

    public var line: String {
        func f(_ v: Double, _ digits: Int = 1) -> String { v.isFinite ? String(format: "%.\(digits)f", v) : "-" }
        let name = label.count > 31 ? String(label.prefix(31)) : label.padding(toLength: 31, withPad: " ", startingAt: 0)
        return "\(name) | \(f(streamHz, 0).leftPad(4)) \(f(meanMbps).leftPad(5)) \(f(qpMean).leftPad(4))/\(f(qpMovingMean).leftPad(4))/\(String(qpMax).leftPad(2)) "
            + "| \(String(keyFrames).leftPad(3)) \(String(recoveries).leftPad(3)) \(String(undelivered).leftPad(3)) \(String(held).leftPad(4)) "
            + "| \(f(latency[0]).leftPad(5)) \(f(latency[1]).leftPad(5)) \(f(latency[2]).leftPad(5)) "
            + "| \(f(age[0]).leftPad(5)) \(f(age[1]).leftPad(5)) | \(f(repeats).leftPad(4)) \(String(freezes).leftPad(4)) "
            + "| \(f(gazePSNR[0]).leftPad(5)) \(f(gazePSNR[1]).leftPad(5)) \(f(gazePSNR[2]).leftPad(5)) "
            + "| \(f(gazeSSIM[1], 3)) | \(f(gazeDetail[1], 2).leftPad(5)) | \(f(centrePSNR[1]).leftPad(5)) "
            + "| \(f(blockiness[1], 2)) \(f(blockiness[2], 2))"
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
