// What the bench's viewer does: where the head goes (a recorded trajectory),
// where the eyes look (a gaze model), and how fast the display runs (a
// refresh schedule that steps down the way a warm headset does).
import Foundation

/// A small quaternion, rotation only, xyzw. (StreamWire's carries no maths and
/// `simd` doesn't exist off Apple platforms.)
public struct Rotation: Sendable, Equatable {
    public var x, y, z, w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Rotation(x: 0, y: 0, z: 0, w: 1)

    public var normalized: Rotation {
        let n = (x * x + y * y + z * z + w * w).squareRoot()
        return n > 0 ? Rotation(x: x / n, y: y / n, z: z / n, w: w / n) : .identity
    }

    public var conjugate: Rotation { Rotation(x: -x, y: -y, z: -z, w: w) }

    public static func * (a: Rotation, b: Rotation) -> Rotation {
        Rotation(x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                 y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                 z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                 w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
    }

    public func rotate(_ v: [Double]) -> [Double] {
        // v + 2 q.w (u x v) + 2 u x (u x v)
        let u = [x, y, z]
        let c = cross(u, v)
        let cc = cross(u, c)
        return [v[0] + 2 * (w * c[0] + cc[0]), v[1] + 2 * (w * c[1] + cc[1]), v[2] + 2 * (w * c[2] + cc[2])]
    }

    /// The angle between two rotations, radians.
    public func angle(to other: Rotation) -> Double {
        let d = abs(x * other.x + y * other.y + z * other.z + w * other.w)
        return 2 * acos(min(d, 1))
    }

    public static func slerp(_ a: Rotation, _ b: Rotation, _ t: Double) -> Rotation {
        var b = b
        var d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
        if d < 0 {
            b = Rotation(x: -b.x, y: -b.y, z: -b.z, w: -b.w)
            d = -d
        }
        if d > 0.9995 {
            return Rotation(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                            z: a.z + (b.z - a.z) * t, w: a.w + (b.w - a.w) * t).normalized
        }
        let theta = acos(d)
        let sa = sin((1 - t) * theta) / sin(theta), sb = sin(t * theta) / sin(theta)
        return Rotation(x: a.x * sa + b.x * sb, y: a.y * sa + b.y * sb, z: a.z * sa + b.z * sb, w: a.w * sa + b.w * sb)
    }
}

func cross(_ a: [Double], _ b: [Double]) -> [Double] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

func normalize(_ v: [Double]) -> [Double] {
    let n = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
    return n > 0 ? v.map { $0 / n } : [0, 0, -1]
}

/// A head pose: world from device, metres, y up, -z ahead.
public struct HeadSample: Sendable, Equatable {
    public var position: [Double]
    public var orientation: Rotation

    public init(position: [Double], orientation: Rotation) {
        self.position = position
        self.orientation = orientation
    }

    public static let standing = HeadSample(position: [0, 1.4, 0], orientation: .identity)
}

/// A recorded head trajectory: the headset's own poses, as the overlay's
/// recorder writes them (`{"columns": ["t","x","y","z","qx","qy","qz","qw"], "rows": [...]}`).
public struct HeadTrajectory: Sendable {
    public private(set) var times: [Double] = []
    public private(set) var samples: [HeadSample] = []

    public init(times: [Double], samples: [HeadSample]) {
        precondition(times.count == samples.count && !times.isEmpty)
        let origin = times[0]
        self.times = times.map { $0 - origin }
        self.samples = samples
    }

    public init(contentsOf url: URL) throws {
        struct File: Decodable {
            var columns: [String]
            var rows: [[Double]]
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        func column(_ name: String) throws -> Int {
            guard let index = file.columns.firstIndex(of: name) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "trajectory has no '\(name)' column"])
            }
            return index
        }
        let t = try column("t"), x = try column("x"), y = try column("y"), z = try column("z")
        let qx = try column("qx"), qy = try column("qy"), qz = try column("qz"), qw = try column("qw")
        var times: [Double] = [], samples: [HeadSample] = []
        for row in file.rows where row.count == file.columns.count {
            if let last = times.last, row[t] <= last { continue }
            times.append(row[t])
            samples.append(HeadSample(position: [row[x], row[y], row[z]],
                                      orientation: Rotation(x: row[qx], y: row[qy], z: row[qz], w: row[qw]).normalized))
        }
        guard !times.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "trajectory has no rows"])
        }
        self.init(times: times, samples: samples)
    }

    public var duration: Double { times.last ?? 0 }

    /// The pose at `time` seconds from the start, interpolated; held at the ends.
    public func sample(at time: Double) -> HeadSample {
        guard time > times[0] else { return samples[0] }
        guard time < times[times.count - 1] else { return samples[samples.count - 1] }
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid } else { hi = mid }
        }
        let f = (time - times[lo]) / max(times[hi] - times[lo], 1e-9)
        let a = samples[lo], b = samples[hi]
        return HeadSample(position: zip(a.position, b.position).map { $0 + ($1 - $0) * f },
                          orientation: .slerp(a.orientation, b.orientation, f))
    }

    /// Head turn rate at `time`, radians per second, over a 20 ms window.
    public func turnRate(at time: Double) -> Double {
        let a = sample(at: time - 0.01), b = sample(at: time + 0.01)
        return a.orientation.angle(to: b.orientation) / 0.02
    }

    /// A synthetic shake for when no recording is at hand: still for `rest`
    /// seconds, then yaw back and forth `amplitude` radians at `hertz`.
    public static func shake(seconds: Double, rest: Double = 2, amplitude: Double = 0.35, hertz: Double = 1.2) -> HeadTrajectory {
        var times: [Double] = [], samples: [HeadSample] = []
        var t = 0.0
        while t <= seconds {
            let yaw = t < rest ? 0 : amplitude * sin(2 * .pi * hertz * (t - rest))
            let pitch = t < rest ? 0 : 0.08 * sin(2 * .pi * hertz * 0.7 * (t - rest))
            let qYaw = Rotation(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2))
            let qPitch = Rotation(x: sin(pitch / 2), y: 0, z: 0, w: cos(pitch / 2))
            times.append(t)
            samples.append(HeadSample(position: [0, 1.4, 0], orientation: (qYaw * qPitch).normalized))
            t += 1.0 / 240
        }
        return HeadTrajectory(times: times, samples: samples)
    }
}

/// Where the eyes look, head-relative, at each moment.
public enum GazeModel: Sendable, Equatable {
    /// Straight ahead of the head (what the host does without gaze).
    case ahead
    /// The eyes hold a world point while the head moves (the vestibulo-ocular
    /// reflex), as when reading a panel while turning: a new point `distance`
    /// metres along the head's forward ray is picked when the held one is more
    /// than `maxEccentricity` radians off forward, or after `dwell` seconds.
    case fixate(distance: Double, maxEccentricity: Double, dwell: Double)

    public static let reading = GazeModel.fixate(distance: 1.4, maxEccentricity: 0.45, dwell: 2.0)

    public init?(argument: String) {
        switch argument {
        case "ahead": self = .ahead
        case "fixate", "reading": self = .reading
        default: return nil
        }
    }
}

/// Steps a `GazeModel` along a trajectory. Call with increasing times.
public struct GazeTracker: Sendable {
    public let model: GazeModel
    private var target: [Double]?
    private var since = 0.0
    public private(set) var saccades = 0

    public init(model: GazeModel) {
        self.model = model
    }

    /// The gaze direction in device space (unit, -z ahead) at `time` for `head`.
    public mutating func direction(at time: Double, head: HeadSample) -> [Double] {
        guard case .fixate(let distance, let maxEccentricity, let dwell) = model else { return [0, 0, -1] }
        func local(_ point: [Double]) -> [Double] {
            let offset = zip(point, head.position).map { $0 - $1 }
            return normalize(head.orientation.conjugate.rotate(offset))
        }
        if let target {
            let d = local(target)
            let eccentricity = acos(max(-1, min(1, -d[2])))
            if eccentricity <= maxEccentricity, time - since < dwell { return d }
        }
        let forward = head.orientation.rotate([0, 0, -1])
        target = zip(head.position, forward).map { $0 + $1 * distance }
        since = time
        saccades += 1
        return [0, 0, -1]
    }
}

/// The display's refresh over a run: `120:10,90:10,60:10` is 120 Hz for 10 s,
/// then 90, then 60 to the end.
public struct RefreshSchedule: Sendable, Equatable {
    public var steps: [(hz: Double, seconds: Double)]

    public init(steps: [(hz: Double, seconds: Double)]) {
        precondition(!steps.isEmpty)
        self.steps = steps
    }

    public init(constant hz: Double) {
        steps = [(hz, .infinity)]
    }

    public init?(argument: String) {
        var steps: [(Double, Double)] = []
        for part in argument.split(separator: ",") {
            let fields = part.split(separator: ":")
            guard let hz = Double(fields[0]), hz >= 10, hz <= 240 else { return nil }
            let seconds = fields.count > 1 ? Double(fields[1]) : .infinity
            guard let seconds, seconds > 0 else { return nil }
            steps.append((hz, seconds))
        }
        guard !steps.isEmpty else { return nil }
        self.steps = steps
    }

    /// The rate at `time` seconds into the run.
    public func hz(at time: Double) -> Double {
        var end = 0.0
        for step in steps {
            end += step.seconds
            if time < end { return step.hz }
        }
        return steps[steps.count - 1].hz
    }

    public var description: String {
        steps.map { $0.seconds.isFinite ? "\(Int($0.hz)) Hz for \(Int($0.seconds)) s" : "\(Int($0.hz)) Hz" }
            .joined(separator: ", then ")
    }

    public static func == (a: RefreshSchedule, b: RefreshSchedule) -> Bool {
        a.steps.count == b.steps.count && zip(a.steps, b.steps).allSatisfy { $0.hz == $1.hz && $0.seconds == $1.seconds }
    }
}
