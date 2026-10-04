// SPIKE ONLY (Phase 2 go/no-go, NATIVE_V3_PROTOCOL.md section 8): a Swift
// executable driving the CStreamWin shim end to end on Windows.
//
//   longwave-host-spike monitors
//   longwave-host-spike endpoints
//   longwave-host-spike crypto
//   longwave-host-spike video [--backend wgc|dda] [--monitor N] [--seconds S] [--fps F]
//                             [--mbps M] [--preset P] [--codec hevc|h264] [--slices N]
//                             [--intra-refresh N] [--idr-at N] [--invalidate-at N]
//                             [--target IP:PORT] [--loopback FILE] [--csv FILE]
//   longwave-host-spike audio [--endpoint NAME-SUBSTRING|default] [--seconds S] [--out FILE.wav] [--tones]
//   longwave-host-spike animate [--monitor N] [--seconds S]
import StreamHostWindows
import WinSDK
import ucrt

struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>) {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { continue }
            let key = String(argument.dropFirst(2))
            if ["tones", "no-cursor"].contains(key) {
                flags.insert(key)
            } else if let value = iterator.next() {
                values[key] = value
            }
        }
    }

    func string(_ key: String, _ fallback: String) -> String { values[key] ?? fallback }
    func int(_ key: String, _ fallback: Int) -> Int { values[key].flatMap { Int($0) } ?? fallback }
    func double(_ key: String, _ fallback: Double) -> Double { values[key].flatMap { Double($0) } ?? fallback }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

func fail(_ message: String) -> Never {
    print("error: \(message)")
    exit(1)
}

let command = CommandLine.arguments.dropFirst().first ?? "help"
let options = Options(CommandLine.arguments.dropFirst(2))

do {
    try StreamHostRuntime.initialize()
} catch {
    fail("\(error)")
}

func pickMonitor(_ options: Options) -> Monitor {
    let monitors = Monitor.all()
    guard !monitors.isEmpty else { fail("no monitors (is this the interactive session?)") }
    if let index = options.values["monitor"].flatMap(Int.init) {
        guard monitors.indices.contains(index) else { fail("no monitor \(index)") }
        return monitors[index]
    }
    return monitors.first(where: \.isPrimary) ?? monitors[0]
}

switch command {
case "monitors":
    for (index, monitor) in Monitor.all().enumerated() { print("[\(index)] \(monitor)") }
case "endpoints":
    for (index, endpoint) in AudioLoopback.endpoints().enumerated() { print("[\(index)] \(endpoint)") }
case "crypto":
    runCryptoSmoke()
case "video":
    runVideo(options: options, monitor: pickMonitor(options))
case "audio":
    runAudio(options: options)
case "animate":
    runAnimator(monitor: pickMonitor(options), seconds: options.double("seconds", 10))
default:
    print("usage: longwave-host-spike monitors|endpoints|crypto|video|audio|animate [options]")
}
