// longwave-pcvr-host: the v3 PCVR host (NATIVE_V3_PROTOCOL.md section 4.7).
//
//   longwave-pcvr-host [--channel pcvr] [--port 4857] [--max-mbps 150]
//                      [--start-mbps 30] [--refresh 90] [--log FILE] [--seconds N]
//                      [--foveation off|auto|on] [--foveation-centre 0.3]
//                      [--foveation-ratio 3.5] [--depth off|auto|stereo]
//                      [--depth-mbps 6]
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
        case "--max-mbps": options.maxMbps = Int(value(argument)) ?? options.maxMbps
        case "--start-mbps": options.startMbps = Int(value(argument)) ?? options.startMbps
        case "--refresh": options.refreshHz = Double(value(argument)) ?? options.refreshHz
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
        case "--depth-dump": options.depthDump = value(argument)
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
