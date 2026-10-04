// SPIKE ONLY: receives the spike wire on a UDP port and writes an Annex-B
// elementary stream. Runs on macOS, Linux and Windows.
//
//   stream-spike-receiver --port 47998 --out capture.h265 --seconds 15 [--same-host]
import StreamSpikeWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

var port: UInt16 = 47998
var output: String? = "capture.h265"
var seconds = 15.0
var sameHost = false

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--port": port = UInt16(arguments.next() ?? "") ?? port
    case "--out": output = arguments.next()
    case "--seconds": seconds = Double(arguments.next() ?? "") ?? seconds
    case "--same-host": sameHost = true
    default:
        print("usage: stream-spike-receiver [--port N] [--out file.h265] [--seconds S] [--same-host]")
        exit(2)
    }
}

do {
    let socket = try SpikeUDPSocket(port: port)
    print("listening on UDP \(socket.localPort), writing \(output ?? "-")")
    let session = try SpikeReceiverSession(socket: socket, outputPath: output, sameHostClock: sameHost)
    let report = session.run(seconds: seconds, idleSeconds: 5)
    print(report.summary)
} catch {
    print("error: \(error)")
    exit(1)
}
