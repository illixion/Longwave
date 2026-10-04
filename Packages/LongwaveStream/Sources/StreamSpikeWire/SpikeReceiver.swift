// SPIKE ONLY: receives the spike wire, writes complete pictures to an Annex-B
// elementary stream (playable with ffplay/ffprobe), and reports loss and
// timing. Used by the stream-spike-receiver tool (Mac) and by the Windows
// host's loopback mode.

#if os(Windows)
import WinSDK
#endif
#if canImport(ucrt)
import ucrt
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SpikeReceiverReport: Sendable {
    public var pictures = 0
    public var idrPictures = 0
    public var bytes = 0
    public var datagrams = 0
    public var lostPictures = 0
    public var lateDatagrams = 0
    public var malformedDatagrams = 0
    public var duplicateShards = 0
    /// capture -> picture complete at the receiver, ms. Only meaningful when
    /// sender and receiver share a clock (same machine).
    public var latenciesMs: [Double] = []
    /// Gaps between consecutive completed pictures, ms.
    public var intervalsMs: [Double] = []
    public var firstPictureNanos: UInt64 = 0
    public var lastPictureNanos: UInt64 = 0

    public var summary: String {
        var lines: [String] = []
        let seconds = Double(lastPictureNanos &- firstPictureNanos) / 1e9
        let fps = seconds > 0 ? Double(max(0, pictures - 1)) / seconds : 0
        lines.append("pictures \(pictures) (IDR \(idrPictures)), \(datagrams) datagrams, \(bytes) bytes")
        lines.append("lost pictures \(lostPictures), late datagrams \(lateDatagrams), malformed \(malformedDatagrams), duplicate shards \(duplicateShards)")
        lines.append(String(format2: "received rate %.1f fps over %.2f s, %.1f Mbit/s", fps, seconds,
                            seconds > 0 ? Double(bytes) * 8 / seconds / 1e6 : 0))
        if !intervalsMs.isEmpty {
            lines.append("picture interval ms " + SpikeStats.describe(intervalsMs))
        }
        if !latenciesMs.isEmpty {
            lines.append("capture->received ms " + SpikeStats.describe(latenciesMs))
        }
        return lines.joined(separator: "\n")
    }
}

public final class SpikeReceiverSession {
    private let socket: SpikeUDPSocket
    private let sameHostClock: Bool
    private var file: UnsafeMutablePointer<FILE>?

    public init(socket: SpikeUDPSocket, outputPath: String?, sameHostClock: Bool) throws {
        self.socket = socket
        self.sameHostClock = sameHostClock
        if let outputPath {
            file = fopen(outputPath, "wb")
            if file == nil { throw SpikeSocketError(operation: "fopen(\(outputPath))", code: -1) }
        }
    }

    deinit {
        if let file { fclose(file) }
    }

    /// Receives until `seconds` have passed since the first datagram, or until
    /// nothing arrives for `idleSeconds` after the first one, or `shouldStop`.
    public func run(seconds: Double, idleSeconds: Double = 2, shouldStop: () -> Bool = { false }) -> SpikeReceiverReport {
        var report = SpikeReceiverReport()
        var reassembler = SpikeReassembler()
        var buffer = [UInt8](repeating: 0, count: 65536)
        socket.setReceiveTimeout(milliseconds: 100)
        var started: UInt64 = 0
        var lastActivity: UInt64 = 0
        var previousComplete: UInt64 = 0
        let runStart = SpikeClock.now()

        while !shouldStop() {
            let now = SpikeClock.now()
            if started == 0, Double(now - runStart) / 1e9 > seconds + 30 { break } // sender never came
            if started != 0 {
                if Double(now - started) / 1e9 > seconds { break }
                if Double(now - lastActivity) / 1e9 > idleSeconds { break }
            }
            let length = buffer.withUnsafeMutableBytes { socket.receive(into: $0) }
            guard length > 0 else { continue }
            let arrival = SpikeClock.now()
            if started == 0 { started = arrival }
            lastActivity = arrival
            report.datagrams += 1
            let picture = buffer.withUnsafeBytes { raw in
                reassembler.receive(UnsafeRawBufferPointer(rebasing: raw[0..<length]))
            }
            guard let picture else { continue }
            report.pictures += 1
            report.bytes += picture.bytes.count
            if picture.isIDR { report.idrPictures += 1 }
            if report.firstPictureNanos == 0 { report.firstPictureNanos = arrival }
            report.lastPictureNanos = arrival
            if previousComplete != 0 { report.intervalsMs.append(Double(arrival - previousComplete) / 1e6) }
            previousComplete = arrival
            if sameHostClock, arrival > picture.captureNanos {
                report.latenciesMs.append(Double(arrival - picture.captureNanos) / 1e6)
            }
            if let file {
                picture.bytes.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, $0.count, file) }
            }
        }
        if let file { fflush(file) }
        report.lostPictures = reassembler.lostPictures
        report.lateDatagrams = reassembler.lateDatagrams
        report.malformedDatagrams = reassembler.malformedDatagrams
        report.duplicateShards = reassembler.duplicateShards
        return report
    }
}

public enum SpikeStats {
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = p / 100 * Double(sorted.count - 1)
        let low = Int(rank)
        let high = min(sorted.count - 1, low + 1)
        let fraction = rank - Double(low)
        return sorted[low] + (sorted[high] - sorted[low]) * fraction
    }

    /// "n=.. mean .. p50 .. p95 .. p99 .. max .."
    public static func describe(_ values: [Double]) -> String {
        let sorted = values.sorted()
        let mean = sorted.reduce(0, +) / Double(max(1, sorted.count))
        return String(format2: "n=%d mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f", sorted.count, mean,
                      percentile(sorted, 50), percentile(sorted, 95), percentile(sorted, 99), sorted.last ?? 0)
    }
}

extension String {
    /// printf-style formatting without Foundation (which would pull ICU into
    /// the Windows distribution just for String(format:)).
    public init(format2 format: String, _ args: CVarArg...) {
        var buffer = [CChar](repeating: 0, count: 512)
        let count = withVaList(args) { list in
            buffer.withUnsafeMutableBufferPointer { vsnprintf($0.baseAddress, $0.count, format, list) }
        }
        if count >= buffer.count {
            buffer = [CChar](repeating: 0, count: Int(count) + 1)
            _ = withVaList(args) { list in
                buffer.withUnsafeMutableBufferPointer { vsnprintf($0.baseAddress, $0.count, format, list) }
            }
        }
        self = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
