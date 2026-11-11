// longwave-pcvr-host: the Windows v3 host (NATIVE_V3_PROTOCOL.md): the desktop
// (PCVRHost+Desktop.swift, as the Mac Companion serves it) and PCVR (section 4.7)
// on one UDP port. The Windows Companion keeps it running and starts the PCVR
// stack when a headset starts the PCVR stream (CompanionLink.swift).
//
//   longwave-pcvr-host [--channel pcvr] [--port 4857] [--max-mbps 150] [--min-mbps 0]
//                      [--start-mbps 30] [--refresh auto|display|Hz] [--max-stream-hz Hz] [--frame-lock on|off]
//                      [--wake-margin auto|half|ms] [--log FILE] [--seconds N]
//                      [--foveation off|auto|on] [--foveation-centre 0.3]
//                      [--foveation-ratio 3.5] [--depth off|auto|stereo]
//                      [--depth-mbps 16] [--depth-scale 16] [--depth-qp 12] [--depth-dump DIR] [--preset 1-7]
//                      [--vbv-frames 1-8] [--multipass off|quarter|full] [--aq 0-15] [--max-qp 0-51]
//                      [--max-eye WxH] [--fovea-qp -10] [--edge-qp 10] [--fovea-radius 8] [--edge-radius 30]
//                      [--rate-change reconfigure|rebuild] [--mic-device NAME|off]
//
// --mic-device names the render endpoint the headset's microphone plays into
// (any part of its name, e.g. "Line 1"); by default the first installed virtual
// cable ("Virtual Audio Cable", "CABLE Input"). Games then pick that cable's
// capture side as their microphone. "off" offers headsets no microphone.
//
// --fovea-qp/--edge-qp shift the colour encoder's QP per 32x32 block by angle
// from the warp centre (FovealQPMap; 0 and 0 turn it off). --rate-change says
// what a new stream rate does to the encoder: change it in place (the default,
// no key frame) or rebuild it.
//
// --max-eye caps each eye's encoded picture: a larger one (warped or not) is
// scaled down uniformly to fit, for viewers whose decoder takes no more.
//
// Foveation packs each eye with the centre/edge warp for viewers that can undo
// it: `auto` (the default) when they also send gaze, `on` even without (the
// centre then sits straight ahead). The centre is the fraction of each axis
// kept at full density, the ratio how much the rest is compressed.
//
// Depth goes to viewers that reproject by it (they negotiated depthVideo):
// `auto` (the default) sends the game's depth when the frame source carries it
// and estimates it from the two eyes otherwise, `stereo` always estimates.
//
// Run it in the signed-in desktop session (the frame source's objects live in
// that session's Local\ namespace), as the user the Windows Companion pairs
// devices for. The session broker attaches with LONGWAVE_BROKER_OUTPUT=native.

import Foundation
import StreamWire

func parseOptions(_ arguments: [String]) -> HostOptions {
    var options = HostOptions()
    var iterator = arguments.makeIterator()
    func value(_ flag: String) -> String {
        guard let next = iterator.next() else {
            print("\(flag) needs a value")
            exit(2)
        }
        return next
    }
    while let argument = iterator.next() {
        switch argument {
        case "--channel": options.channel = value(argument)
        case "--port": options.port = UInt16(value(argument)) ?? options.port
        case "--mic-device": options.micDevice = value(argument)
        case "--max-mbps": options.maxMbps = Int(value(argument)) ?? options.maxMbps
        case "--min-mbps": options.minMbps = Int(value(argument)) ?? options.minMbps
        case "--start-mbps": options.startMbps = Int(value(argument)) ?? options.startMbps
        case "--refresh":
            let rate = value(argument)
            if rate == "auto" || rate == "display" {
                options.followsHeadset = true
                options.halvesForEncoder = rate == "auto"
            } else if let hz = Double(rate), hz >= 30, hz <= 240 {
                options.refreshHz = hz
                options.followsHeadset = false
            } else {
                print("--refresh takes auto (the display's rate or half, as the encoder keeps up), display, or a rate in Hz (30-240)")
                exit(2)
            }
        case "--frame-lock":
            switch value(argument) {
            case "on": options.locksToHeadset = true
            case "off": options.locksToHeadset = false
            default:
                print("--frame-lock takes on or off")
                exit(2)
            }
        case "--max-stream-hz":
            guard let hz = Double(value(argument)), hz >= 30 else {
                print("--max-stream-hz takes a rate in Hz, at least 30")
                exit(2)
            }
            options.maxStreamHz = hz
        case "--wake-margin":
            let margin = value(argument)
            if margin == "auto" {
                options.wakeMargin = .auto
            } else if margin == "half" {
                options.wakeMargin = .half
            } else if let ms = Double(margin), ms >= 0, ms <= 20 {
                options.wakeMargin = .milliseconds(ms)
            } else {
                print("--wake-margin takes auto, half or milliseconds (0-20)")
                exit(2)
            }
        case "--log": options.logPath = value(argument)
        case "--seconds": options.seconds = Double(value(argument))
        case "--foveation":
            guard let mode = FoveationMode(rawValue: value(argument)) else {
                print("--foveation takes off, auto or on")
                exit(2)
            }
            options.foveation = mode
        case "--foveation-centre":
            guard let size = Float(value(argument)), size > 0, size <= 1 else {
                print("--foveation-centre takes a fraction in (0, 1]")
                exit(2)
            }
            options.warp.centreSizeX = size
            options.warp.centreSizeY = size
        case "--foveation-ratio":
            guard let ratio = Float(value(argument)), ratio.isFinite, ratio >= 1 else {
                print("--foveation-ratio takes a number of at least 1")
                exit(2)
            }
            options.warp.edgeRatioX = ratio
            options.warp.edgeRatioY = ratio
        case "--depth":
            guard let mode = DepthMode(rawValue: value(argument)) else {
                print("--depth takes off, auto or stereo")
                exit(2)
            }
            options.depth = mode
        case "--depth-mbps":
            guard let mbps = Int(value(argument)), mbps > 0 else {
                print("--depth-mbps takes a positive number")
                exit(2)
            }
            options.depthMbps = mbps
        case "--depth-qp":
            guard let qp = Int(value(argument)), (0...51).contains(qp) else {
                print("--depth-qp takes 0 (CBR at --depth-mbps) or a constant QP 1-51")
                exit(2)
            }
            options.depthQP = qp
        case "--depth-scale":
            guard let scale = Int(value(argument)), [2, 4, 8, 16, 32].contains(scale) else {
                print("--depth-scale takes 2, 4, 8, 16 or 32: the depth picture is the render eye divided by it")
                exit(2)
            }
            options.depthScale = scale
        case "--depth-dump": options.depthDump = value(argument)
        case "--max-eye":
            let parts = value(argument).split(separator: "x").compactMap { UInt16($0) }
            guard parts.count == 2, parts.allSatisfy({ $0 >= 256 }) else {
                print("--max-eye takes WxH, each at least 256")
                exit(2)
            }
            options.maxWireEye = PixelSize(width: parts[0], height: parts[1])
        case "--preset":
            guard let preset = Int(value(argument)), (1...7).contains(preset) else {
                print("--preset takes 1 (fastest) to 7")
                exit(2)
            }
            options.preset = preset
        case "--vbv-frames":
            guard let frames = Int(value(argument)), (1...8).contains(frames) else {
                print("--vbv-frames takes 1 to 8")
                exit(2)
            }
            options.vbvFrames = frames
        case "--multipass":
            guard let mode = ["off", "quarter", "full"].firstIndex(of: value(argument)) else {
                print("--multipass takes off, quarter or full")
                exit(2)
            }
            options.multiPass = mode
        case "--aq":
            guard let strength = Int(value(argument)), (0...15).contains(strength) else {
                print("--aq takes 0 (off) to 15")
                exit(2)
            }
            options.spatialAQ = strength
        case "--max-qp":
            guard let qp = Int(value(argument)), (0...51).contains(qp) else {
                print("--max-qp takes 0 (none) to 51")
                exit(2)
            }
            options.maxQP = qp
        case "--fovea-qp", "--edge-qp":
            guard let qp = Int(value(argument)), (-20...20).contains(qp) else {
                print("\(argument) takes -20 to 20")
                exit(2)
            }
            if argument == "--fovea-qp" { options.fovealQP.foveaQP = qp } else { options.fovealQP.edgeQP = qp }
        case "--fovea-radius", "--edge-radius":
            guard let degrees = Double(value(argument)), (0...90).contains(degrees) else {
                print("\(argument) takes 0 to 90 degrees")
                exit(2)
            }
            if argument == "--fovea-radius" { options.fovealQP.foveaRadius = degrees } else { options.fovealQP.edgeRadius = degrees }
        case "--rate-change":
            switch value(argument) {
            case "reconfigure": options.reconfiguresRate = true
            case "rebuild": options.reconfiguresRate = false
            default:
                print("--rate-change takes reconfigure or rebuild")
                exit(2)
            }
        default:
            print("unknown argument \(argument)")
            exit(2)
        }
    }
    return options
}

func runHost() -> Int32 {
    let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
    let log = HostLog(path: options.logPath)
    do {
        let host = try PCVRHost(options: options, log: log)
        try host.run()
        return 0
    } catch {
        log.line("fatal: \(error)")
        return 1
    }
}

exit(runHost())
