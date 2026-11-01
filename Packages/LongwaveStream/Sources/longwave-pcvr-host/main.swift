// longwave-pcvr-host: the v3 PCVR host (NATIVE_V3_PROTOCOL.md section 4.7).
//
//   longwave-pcvr-host [--channel pcvr] [--port 4857] [--max-mbps 150]
//                      [--start-mbps 30] [--refresh 90] [--log FILE] [--seconds N]
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
