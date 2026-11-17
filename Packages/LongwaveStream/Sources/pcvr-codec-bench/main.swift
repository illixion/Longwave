// pcvr-codec-bench: the PCVR picture as the headset would get it, without a
// headset. The test scene is ray-cast along a recorded head trajectory, warped
// round where the eyes look, encoded by NVENC with the host's settings, and
// sent through StreamBench's model of a network (rate control, FEC, NACKs,
// recovery, playout at the display's refresh); every frame's reconstruction
// is scored against the truth at the gaze point. One process runs several
// variants over the same motion, so settings compare like for like.
//
//   pcvr-codec-bench --trajectory shake.json --start 9 --seconds 8 \
//       --scenario wifi,wifi-awdl,stockholm --refresh 120:3,90:3,60 \
//       --variant "host: " --variant "vbv8: --vbv-frames 8" --crops C:\lwvr\crops --crop-at 2,4
//
// Modes: `link` (the default) runs the closed loop over each `--scenario`;
// `encode` encodes every frame at a fixed `--bitrate` with no network, to
// compare encoder settings alone.
import CStreamWin
import Foundation
import StreamBench
import StreamHostWindows
import StreamSim
import StreamWire

struct Config {
    var mode = "link"
    var scenarios = ["wifi"]
    var refresh = RefreshSchedule(constant: 90)
    var seconds = 8.0
    var bitrates = [100]
    var maxMbps = 120
    var startMbps = 100
    var depthReserve = 40
    var minMbps = 0
    var depthLoad = 4.0
    var trajectoryPath: String?
    var start = 0.0
    var gaze = GazeModel.reading
    var followGaze = true
    var gazeLag = 0.03
    var box = 384
    var sideOffset = (dx: -1000, dy: 0)
    var crops: String?
    var cropAt: [Double] = []
    var out: String?
    var seed: UInt64 = 1
    var encoder = EncoderSettings()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pcvr-codec-bench: \(message)\n".utf8))
    exit(2)
}

func apply(_ arguments: [String], to config: inout Config) {
    var i = 0
    func value() -> String {
        i += 1
        guard i < arguments.count else { fail("\(arguments[i - 1]) needs a value") }
        return arguments[i]
    }
    func int(_ range: ClosedRange<Int>) -> Int {
        let name = arguments[i]
        guard let v = Int(value()), range.contains(v) else { fail("\(name) takes \(range.lowerBound)...\(range.upperBound)") }
        return v
    }
    func double() -> Double {
        let name = arguments[i]
        guard let v = Double(value()) else { fail("\(name) takes a number") }
        return v
    }
    func flag() -> Bool {
        let name = arguments[i]
        switch value() {
        case "on", "true", "1": return true
        case "off", "false", "0": return false
        default: fail("\(name) takes on or off")
        }
    }
    while i < arguments.count {
        let argument = arguments[i]
        switch argument {
        case "--mode":
            config.mode = value()
            guard ["link", "encode", "motion"].contains(config.mode) else { fail("--mode takes link, encode or motion") }
        case "--scenario":
            config.scenarios = value().split(separator: ",").map(String.init)
            for name in config.scenarios where LinkScenario.named(name) == nil {
                fail("no scenario '\(name)'; there are \(LinkScenario.all.map(\.name).joined(separator: ", "))")
            }
        case "--refresh":
            guard let schedule = RefreshSchedule(argument: value()) else { fail("--refresh takes Hz or Hz:seconds,Hz:seconds,...") }
            config.refresh = schedule
        case "--seconds": config.seconds = double()
        case "--bitrate":
            config.bitrates = value().split(separator: ",").compactMap { Int($0) }
            guard !config.bitrates.isEmpty else { fail("--bitrate takes Mbit/s, or a list") }
        case "--max-mbps": config.maxMbps = int(1...1000)
        case "--start-mbps": config.startMbps = int(1...1000)
        case "--depth-mbps": config.depthReserve = int(0...200)
        case "--min-mbps": config.minMbps = int(0...1000)
        case "--depth-load": config.depthLoad = double()
        case "--trajectory": config.trajectoryPath = value()
        case "--start": config.start = double()
        case "--gaze":
            guard let model = GazeModel(argument: value()) else { fail("--gaze takes ahead or fixate") }
            config.gaze = model
        case "--follow-gaze": config.followGaze = flag()
        case "--gaze-lag": config.gazeLag = double() / 1000
        case "--box": config.box = int(32...1024) / 16 * 16
        case "--side":
            let parts = value().split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2 else { fail("--side takes dx,dy in render pixels (-1000,0)") }
            config.sideOffset = (parts[0], parts[1])
        case "--crops": config.crops = value()
        case "--crop-at": config.cropAt = value().split(separator: ",").compactMap { Double($0) }.sorted()
        case "--out": config.out = value()
        case "--seed": config.seed = UInt64(int(0...1_000_000))
        case "--preset": config.encoder.preset = int(1...7)
        case "--vbv-frames": config.encoder.vbvFrames = int(1...16)
        case "--multipass":
            switch value() {
            case "off": config.encoder.multiPass = 0
            case "quarter": config.encoder.multiPass = 1
            case "full": config.encoder.multiPass = 2
            default: fail("--multipass takes off, quarter or full")
            }
        case "--aq": config.encoder.spatialAQ = int(0...15)
        case "--taq": config.encoder.temporalAQ = flag()
        case "--max-qp": config.encoder.maxQP = int(0...51)
        case "--min-qp": config.encoder.minQP = int(0...51)
        case "--key-scale": config.encoder.keyFrameScale = int(0...255)
        case "--tuning":
            switch value() {
            case "ull": config.encoder.lowLatencyTuning = false
            case "ll": config.encoder.lowLatencyTuning = true
            default: fail("--tuning takes ull or ll")
            }
        case "--rate-change":
            switch value() {
            case "rebuild": config.encoder.reconfigureOnRateChange = false
            case "reconfigure": config.encoder.reconfigureOnRateChange = true
            default: fail("--rate-change takes rebuild or reconfigure")
            }
        case "--fovea-qp": config.encoder.foveaQP = int(-20...20)
        case "--edge-qp": config.encoder.edgeQP = int(-20...20)
        case "--fovea-radius": config.encoder.foveaRadius = double()
        case "--edge-radius": config.encoder.edgeRadius = double()
        case "--align-centre": config.encoder.alignCentre = flag()
        case "--warp":
            let parts = value().split(separator: ",").compactMap { Float($0) }
            guard parts.count == 2, parts[0] > 0, parts[0] <= 1, parts[1] >= 1 else { fail("--warp takes centre,ratio (0.3,3.5)") }
            config.encoder.warp = CentreEdgeWarp(centreSizeX: parts[0], centreSizeY: parts[0], edgeRatioX: parts[1], edgeRatioY: parts[1])
        default:
            fail("unknown option \(argument)")
        }
        i += 1
    }
}

// The command line: shared options, then any number of `--variant "label: options"`.
var base: [String] = []
var variants: [(label: String, arguments: [String])] = []
do {
    var arguments: [String] = []
    // `@file` reads arguments from a file, one per line (blank lines and # comments
    // skipped), so a sweep needs no shell quoting.
    for argument in CommandLine.arguments.dropFirst() {
        guard argument.hasPrefix("@") else {
            arguments.append(argument)
            continue
        }
        guard let text = try? String(contentsOfFile: String(argument.dropFirst()), encoding: .utf8) else {
            fail("can't read \(argument.dropFirst())")
        }
        arguments += text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
    while let index = arguments.firstIndex(of: "--variant") {
        guard index + 1 < arguments.count else { fail("--variant needs \"label: options\"") }
        let text = arguments[index + 1]
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let label = parts[0].trimmingCharacters(in: .whitespaces)
        let rest = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
        variants.append((label.isEmpty ? "variant\(variants.count + 1)" : label, rest))
        arguments.removeSubrange(index...(index + 1))
    }
    base = arguments
}
if base.contains("--help") || base.contains("-h") {
    print("""
    pcvr-codec-bench [options] [--variant "label: options"]... [@argument-file]
      --mode link|encode|motion  --scenario \(LinkScenario.all.map(\.name).joined(separator: ","))
      --refresh 90 | 120:5,90:5,60  --seconds S  --bitrate MBPS[,MBPS] (encode)
      --max-mbps 120 --start-mbps 100 --depth-mbps 40 --depth-load 4
      --trajectory FILE --start S --gaze fixate|ahead --follow-gaze on|off --gaze-lag MS --box PX
      --crops DIR --crop-at S,S  --out FILE.json  --seed N
      encoder: --preset 1-7 --vbv-frames N --multipass off|quarter|full --aq 0-15 --taq on|off
               --max-qp N --min-qp N --key-scale N --tuning ull|ll --rate-change rebuild|reconfigure
               --fovea-qp N --edge-qp N --fovea-radius DEG --edge-radius DEG --warp CENTRE,RATIO --align-centre on|off
    """)
    exit(0)
}
if variants.isEmpty { variants = [("default", [])] }

var shared = Config()
apply(base, to: &shared)

let trajectory: HeadTrajectory
if let path = shared.trajectoryPath {
    do { trajectory = try HeadTrajectory(contentsOf: URL(fileURLWithPath: path)) } catch { fail("trajectory: \(error)") }
} else {
    trajectory = .shake(seconds: shared.start + shared.seconds + 1)
}

do {
    try StreamHostRuntime.initialize()
} catch {
    fail("runtime: \(error)")
}
let device: GraphicsDevice
do { device = try GraphicsDevice(for: nil) } catch { fail("device: \(error)") }
print("device: \(device.adapterName); trajectory \(String(format: "%.1f", trajectory.duration)) s, from \(shared.start) s for \(shared.seconds) s; refresh \(shared.refresh.description)")

if shared.mode == "motion" {
    // Motion estimation alone: no encoder, no network (Motion.swift). The picture is the
    // unwarped render eye at the wire's size, as the host sends with foveation off.
    var viewer = ViewerSettings(trajectory: trajectory)
    viewer.start = shared.start
    do {
        // LW_MOTION_EYE=WxH: estimate at another eye size (a smaller picture is cheaper to search).
        var eye = PixelSize(width: 2536, height: 2040)
        if let text = ProcessInfo.processInfo.environment["LW_MOTION_EYE"] {
            let parts = text.split(separator: "x").compactMap { UInt16($0) }
            if parts.count == 2 { eye = PixelSize(width: parts[0], height: parts[1]) }
        }
        try MotionProbe.run(device: device, viewer: viewer, eye: eye, seconds: shared.seconds,
                            sourceHz: 45, preset: shared.encoder.preset, scoreEvery: 4)
    } catch {
        fail("motion: \(error)")
    }
    exit(0)
}

struct FrameRow: Codable {
    var t: Double, hz: Double, mbps: Double, bytes: Int, key: Bool, qp: Int, encodeMs: Double
    var latencyMs: Double?, shown: Int, decodable: Bool
    var quality: FrameQuality?
}
struct RunOutput: Codable {
    var label: String
    var scenario: String
    var summary: RunSummary
    var rebuilds: Int
    var frames: [FrameRow]
}
var outputs: [RunOutput] = []

print(RunSummary.header)
for variant in variants {
    var config = shared
    apply(variant.arguments, to: &config)
    let runs: [(scenario: String, bitrate: Int?)] = config.mode == "encode"
        ? config.bitrates.map { ("none", $0) }
        : config.scenarios.map { ($0, nil) }
    for run in runs {
        let label = config.mode == "encode" ? "\(variant.label) @\(run.bitrate!)" : "\(variant.label) \(run.scenario)"
        do {
            var viewer = ViewerSettings(trajectory: trajectory)
            viewer.start = config.start
            viewer.gaze = config.gaze
            viewer.followGaze = config.followGaze
            viewer.gazeLag = config.gazeLag
            viewer.box = config.box
            viewer.sideOffset = config.sideOffset
            let pipeline = try Pipeline(device: device, settings: config.encoder, viewer: viewer)
            pipeline.label = label.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "@", with: "")
            if let crops = config.crops {
                let url = URL(fileURLWithPath: crops)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                pipeline.cropDirectory = url
                pipeline.cropTimes = config.cropAt
            }
            let result: StreamRunResult
            if let bitrate = run.bitrate {
                // No network: every frame at the fixed rate, shown at once.
                var frames: [FrameRecord] = [], ticks: [TickRecord] = []
                var t = 0.0, index = 0
                while t < config.seconds {
                    let hz = config.refresh.hz(at: t)
                    let request = FrameRequest(index: index, time: t, hz: hz, bitrate: bitrate * 1_000_000, forceKey: index == 0)
                    let encoded = try pipeline.encode(request)
                    var record = FrameRecord(index: index, time: t, hz: hz, bitrate: request.bitrate, size: encoded.size,
                                             isKey: encoded.isKey, qp: encoded.qp, encodeSeconds: encoded.encodeSeconds)
                    record.completed = t + encoded.encodeSeconds
                    record.decodable = true
                    record.shownTicks = 1
                    frames.append(record)
                    ticks.append(TickRecord(time: t, hz: hz, frame: index, age: encoded.encodeSeconds))
                    t += 1 / hz
                    index += 1
                }
                result = StreamRunResult(frames: frames, ticks: ticks)
            } else {
                var configuration = StreamRunConfiguration(scenario: LinkScenario.named(run.scenario)!, refresh: config.refresh,
                                                           seconds: config.seconds)
                configuration.maxMbps = config.maxMbps
                configuration.startMbps = config.startMbps
                configuration.depthReserveMbps = config.depthReserve
                configuration.minMbps = config.minMbps
                configuration.depthLoadMbps = config.depthLoad
                configuration.seed = config.seed
                result = try StreamRun(configuration: configuration, encoder: pipeline).run()
            }
            let summary = RunSummary(label: label, run: result, quality: pipeline.qualities)
            print(summary.line)
            let render = Stats.mean(pipeline.renderSeconds) * 1000
            FileHandle.standardError.write(Data(String(format: "  %@: %d frames, %.1f ms per frame on the GPU, %d rate changes, %d stalled datagrams (longest %.0f ms)\n",
                                                       label, result.frames.count, render, pipeline.rebuilds,
                                                       result.datagramsStalled, result.longestHold * 1000).utf8))
            let rows = result.frames.map { f in
                FrameRow(t: f.time, hz: f.hz, mbps: Double(f.bitrate) / 1e6, bytes: f.size, key: f.isKey, qp: f.qp,
                         encodeMs: f.encodeSeconds * 1000, latencyMs: f.completed.map { ($0 - f.time) * 1000 },
                         shown: f.shownTicks, decodable: f.decodable, quality: pipeline.qualities[f.index])
            }
            outputs.append(RunOutput(label: variant.label, scenario: run.scenario, summary: summary, rebuilds: pipeline.rebuilds,
                                     frames: rows))
        } catch {
            print("\(label): \(error)")
        }
    }
}

if let out = shared.out {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    do {
        try encoder.encode(outputs).write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    } catch {
        fail("could not write \(out): \(error)")
    }
}
