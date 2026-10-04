// SPIKE ONLY: capture -> NVENC -> spike wire -> UDP, with per-frame timing.
//
// Threads: the shim's capture thread hands each due frame to a one-slot,
// latest-wins mailbox; one encode thread takes the newest frame, encodes it
// synchronously and sends its datagrams. A frame that waits while a newer one
// arrives is dropped ("superseded"), so latency never accumulates.
import Dispatch
import StreamHostWindows
import StreamSpikeWire
import Synchronization
import WinSDK
import ucrt

/// One-slot latest-wins handoff between the capture and encode threads.
final class FrameMailbox: Sendable {
    private let slot = Mutex<CapturedFrame?>(nil)
    private let signal = DispatchSemaphore(value: 0)
    let superseded = Atomic<Int>(0)

    func put(_ frame: CapturedFrame) {
        let replaced = slot.withLock { value -> CapturedFrame? in
            defer { value = frame }
            return value
        }
        if replaced != nil { superseded.add(1, ordering: .relaxed) } else { signal.signal() }
        // `replaced` is released here, on the capture thread, returning its ring slot.
    }

    func take(timeoutMilliseconds: Int) -> CapturedFrame? {
        guard signal.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .success else { return nil }
        return slot.withLock { value in
            defer { value = nil }
            return value
        }
    }
}

/// Decides which captured frames to encode so the output runs at `fps` even
/// when the display refreshes faster (e.g. 180 Hz panel, 120 fps stream).
final class FramePacer: Sendable {
    private let interval: Int64
    private let nextDue = Mutex<Int64>(0)
    let skipped = Atomic<Int>(0)

    init(fps: Int) { interval = HostClock.ticksPerSecond / Int64(fps) }

    func admit(presentTicks: Int64) -> Bool {
        let tolerance = interval / 8 // absorbs composition jitter at equal rates
        let admitted = nextDue.withLock { due -> Bool in
            if due == 0 || presentTicks + tolerance >= due {
                // Advance along the ideal grid, so a 180 Hz source decimates
                // to 120 on average (2 of every 3 frames); after a pause (no
                // frames while nothing changed) restart the grid at now
                // rather than bursting to catch up.
                due += interval
                if due < presentTicks - interval { due = presentTicks + interval }
                return true
            }
            return false
        }
        if !admitted { skipped.add(1, ordering: .relaxed) }
        return admitted
    }
}

struct FrameRecord {
    var sequence: UInt64
    var present: Int64
    var arrival: Int64
    var ready: Int64
    var dequeued: Int64
    var submit: Int64
    var done: Int64
    var sent: Int64
    var bytes: Int
    var idr: Bool
    var qp: Int
}

func processCPUTime100ns() -> UInt64 {
    var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
    GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user)
    func value(_ t: FILETIME) -> UInt64 { UInt64(t.dwHighDateTime) << 32 | UInt64(t.dwLowDateTime) }
    return value(kernel) + value(user)
}

func runVideo(options: Options, monitor: Monitor) {
    let backend: CaptureSession.Backend = options.string("backend", "wgc") == "dda" ? .desktopDuplication : .graphicsCapture
    let seconds = options.double("seconds", 10)
    let fps = options.int("fps", 120)
    let idrAt = options.int("idr-at", -1)
    let invalidateAt = options.int("invalidate-at", -1)

    let synthetic = options.string("source", "display") == "synthetic"
    let width = synthetic ? options.int("width", 2560) : monitor.width & ~1
    let height = synthetic ? options.int("height", 1440) : monitor.height & ~1
    let panning = options.string("motion", "random") == "pan"
    if synthetic {
        print("source: synthetic \(width)x\(height) @ \(fps), \(panning ? "panning" : "random noise every frame")")
    } else {
        print("monitor: \(monitor)")
    }
    let device: GraphicsDevice
    let encoder: VideoEncoder
    do {
        device = try GraphicsDevice(for: synthetic ? nil : monitor)
        var parameters = VideoEncoder.Parameters(width: width, height: height, fps: fps,
                                                 bitrate: Int(options.double("mbps", 50) * 1_000_000))
        parameters.codec = options.string("codec", "hevc") == "h264" ? .h264 : .hevc
        parameters.preset = options.int("preset", 1)
        parameters.intraRefreshPeriod = options.int("intra-refresh", 0)
        parameters.slices = options.int("slices", 1)
        parameters.asyncMode = options.string("wait", "sync") == "async"
        encoder = try VideoEncoder(device: device, parameters: parameters)
    } catch {
        fail("\(error)")
    }
    let info = encoder.info
    print("device: \(device.adapterName); encoder: \(info.name), NVENC API header \(info.headerAPI) / driver \(info.driverAPI)")
    print("  caps: ref invalidation \(info.supportsReferenceInvalidation), intra refresh \(info.supportsIntraRefresh), max LTR \(info.maxLTRFrames), max \(info.maxWidth)x\(info.maxHeight)")
    print("  \(encoder.parameters.width)x\(encoder.parameters.height) @ \(fps) fps, \(encoder.parameters.bitrate / 1_000_000) Mbit/s CBR, P\(encoder.parameters.preset), 1-frame VBV, infinite GOP")

    // Network: optional remote target, optional in-process loopback receiver.
    var senders: [SpikeUDPSocket] = []
    var loopbackDone: DispatchSemaphore?
    let loopbackReport = Mutex<SpikeReceiverReport?>(nil)
    let stopReceiver = Atomic<Bool>(false)
    do {
        if let target = options.values["target"] {
            let parts = target.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else { fail("--target wants IP:PORT") }
            let socket = try SpikeUDPSocket()
            try socket.connect(host: String(parts[0]), port: port)
            senders.append(socket)
        }
        if let path = options.values["loopback"] {
            let receiver = try SpikeUDPSocket(bindAddress: "127.0.0.1", port: 0)
            let session = try SpikeReceiverSession(socket: receiver, outputPath: path, sameHostClock: true)
            let socket = try SpikeUDPSocket(bindAddress: "127.0.0.1")
            try socket.connect(host: "127.0.0.1", port: receiver.localPort)
            senders.append(socket)
            let done = DispatchSemaphore(value: 0)
            loopbackDone = done
            nonisolated(unsafe) let unsafeSession = session
            DispatchQueue(label: "loopback-receiver", qos: .userInitiated).async {
                let report = unsafeSession.run(seconds: seconds + 10, idleSeconds: 3,
                                               shouldStop: { stopReceiver.load(ordering: .relaxed) })
                loopbackReport.withLock { $0 = report }
                done.signal()
            }
        }
    } catch {
        fail("\(error)")
    }

    let mailbox = FrameMailbox()
    let pacer = FramePacer(fps: fps)
    let stopEncoding = Atomic<Bool>(false)
    let encodeFinished = DispatchSemaphore(value: 0)
    let records = Mutex<[FrameRecord]>([])
    let encodeErrors = Mutex<[String]>([])
    let sendFailures = Atomic<Int>(0)
    let datagramsSent = Atomic<Int>(0)
    records.withLock { $0.reserveCapacity(Int(seconds) * fps + 64) }

    let unsafeSenders = senders
    DispatchQueue(label: "encode", qos: .userInteractive).async {
        var packetizer = SpikePacketizer()
        var encoded = 0
        var timestamps: [UInt64] = []
        while !stopEncoding.load(ordering: .relaxed) {
            guard let frame = mailbox.take(timeoutMilliseconds: 50) else { continue }
            let dequeued = HostClock.now()
            let timestamp = frame.sequence
            do {
                if encoded == invalidateAt, timestamps.count >= 2 {
                    // Pretend the client lost the last two pictures.
                    try encoder.invalidate(timestamps: Array(timestamps.suffix(2)))
                    print("invalidated references \(timestamps.suffix(2)) before picture \(encoded)")
                }
                let forceIDR = encoded == 0 || encoded == idrAt
                let record = try encoder.encode(frame, timestamp: timestamp, forceIDR: forceIDR) { picture -> FrameRecord in
                    packetizer.packetize(picture.bytes, isIDR: picture.isIDR,
                                         captureNanos: HostClock.nanoseconds(min(frame.presentTicks, frame.arrivalTicks))) { datagram in
                        for socket in unsafeSenders {
                            if socket.send(datagram) {
                                datagramsSent.add(1, ordering: .relaxed)
                            } else {
                                sendFailures.add(1, ordering: .relaxed)
                            }
                        }
                    }
                    return FrameRecord(sequence: frame.sequence, present: frame.presentTicks, arrival: frame.arrivalTicks,
                                       ready: frame.readyTicks, dequeued: dequeued, submit: picture.submitTicks,
                                       done: picture.doneTicks, sent: HostClock.now(), bytes: picture.bytes.count,
                                       idr: picture.isIDR, qp: picture.averageQP)
                }
                records.withLock { $0.append(record) }
                timestamps.append(timestamp)
                if timestamps.count > 8 { timestamps.removeFirst() }
                encoded += 1
            } catch {
                encodeErrors.withLock { if $0.count < 5 { $0.append("\(error)") } }
            }
        }
        encodeFinished.signal()
    }

    var gpuLoad: SpikeGPULoad?
    if let percent = options.values["gpu-load"].flatMap(Int.init) {
        do { gpuLoad = try SpikeGPULoad(percent: percent) } catch { fail("\(error)") }
        print("GPU load generator at ~\(percent)% duty (stands in for a game)")
        Sleep(1500) // let the driver raise clocks
    }
    let cpuStart = processCPUTime100ns()
    let wallStart = HostClock.now()
    let capture: CaptureSession
    let handler: @Sendable (CapturedFrame) -> Void = { frame in
        if pacer.admit(presentTicks: min(frame.presentTicks, frame.arrivalTicks)) { mailbox.put(frame) }
    }
    do {
        if synthetic {
            capture = try CaptureSession(syntheticOn: device, width: width, height: height, fps: fps, panning: panning,
                                         onFrame: handler)
        } else {
            capture = try CaptureSession(device: device, monitor: monitor, backend: backend,
                                         cursor: !options.has("no-cursor"), ringSize: 4, onFrame: handler)
        }
    } catch {
        fail("\(error)")
    }
    let sourceName = synthetic ? "the synthetic source" : backend == .graphicsCapture ? "Windows.Graphics.Capture" : "DXGI Desktop Duplication"
    print("capturing with \(sourceName) for \(seconds) s ...")
    Sleep(DWORD(seconds * 1000))
    let stats = capture.statistics
    capture.stop()
    stopEncoding.store(true, ordering: .relaxed)
    encodeFinished.wait()
    let wallEnd = HostClock.now()
    let cpuEnd = processCPUTime100ns()
    gpuLoad?.stop()

    if let done = loopbackDone {
        if done.wait(timeout: .now() + .seconds(5)) == .timedOut {
            stopReceiver.store(true, ordering: .relaxed)
            done.wait()
        }
    }

    // ---- Report ----
    let rows = records.withLock { $0 }
    let wallSeconds = HostClock.milliseconds(wallEnd - wallStart) / 1000
    let cpuSeconds = Double(cpuEnd - cpuStart) / 1e7
    var logical = SYSTEM_INFO()
    GetSystemInfo(&logical)
    print("")
    print("capture: OS frames \(stats.osFrames), delivered \(stats.delivered), ring-full drops \(stats.droppedRingFull), errors \(stats.errors)\(stats.sourceLost ? ", SOURCE LOST" : "")")
    print("pacing: skipped \(pacer.skipped.load(ordering: .relaxed)) (above \(fps) fps), superseded in mailbox \(mailbox.superseded.load(ordering: .relaxed))")
    for error in encodeErrors.withLock({ $0 }) { print("encode error: \(error)") }
    guard rows.count > 1 else {
        print("no frames encoded - is the screen changing? (WGC/DDA deliver only on change)")
        return
    }
    let spanMs = HostClock.milliseconds(min(rows.last!.present, rows.last!.arrival) - min(rows.first!.present, rows.first!.arrival))
    let totalBytes = rows.reduce(0) { $0 + $1.bytes }
    print(String(format2: "encoded %d pictures (%d IDR) in %.2f s of capture time = %.1f fps; %.1f Mbit/s actual",
                 rows.count, rows.filter(\.idr).count, spanMs / 1000, Double(rows.count - 1) / (spanMs / 1000),
                 Double(totalBytes) * 8 / (spanMs / 1000) / 1e6))
    print("datagrams sent \(datagramsSent.load(ordering: .relaxed)), send failures \(sendFailures.load(ordering: .relaxed))")
    func stage(_ name: String, _ f: (FrameRecord) -> Int64) {
        print("  " + name.padding(28) + SpikeStats.describe(rows.map { HostClock.milliseconds(f($0)) }))
    }
    // "Capture time" is the earlier of the OS stamp and our arrival: DXGI's
    // LastPresentTime is in the past, but WGC's SystemRelativeTime can be the
    // (future) vblank the composed frame is meant for, which would make every
    // later stage look negative.
    func captured(_ r: FrameRecord) -> Int64 { min(r.present, r.arrival) }
    print("latency per frame, ms (QPC):")
    stage("OS stamp -> shim arrival", { $0.arrival - $0.present })
    stage("arrival -> GPU copy queued", { $0.ready - $0.arrival })
    stage("copy queued -> encode start", { $0.dequeued - $0.ready })
    stage("encode (submit -> locked)", { $0.done - $0.submit })
    stage("packetize + send", { $0.sent - $0.done })
    stage("CAPTURE -> ENCODED", { $0.done - captured($0) })
    stage("capture -> sent", { $0.sent - captured($0) })
    let intervals = zip(rows.dropFirst(), rows).map { HostClock.milliseconds(captured($0) - captured($1)) }
    print("  " + "encoded frame interval".padding(28) + SpikeStats.describe(intervals))
    print("  " + "picture size KB".padding(28) + SpikeStats.describe(rows.map { Double($0.bytes) / 1024 }))
    print(String(format2: "CPU: %.2f s over %.2f s wall = %.1f%% of one core, %.1f%% of %d logical CPUs",
                 cpuSeconds, wallSeconds, cpuSeconds / wallSeconds * 100,
                 cpuSeconds / wallSeconds * 100 / Double(logical.dwNumberOfProcessors), Int(logical.dwNumberOfProcessors)))

    if let report = loopbackReport.withLock({ $0 }) {
        print("loopback receiver (\(options.values["loopback"]!)):")
        for line in report.summary.split(separator: "\n") { print("  " + line) }
    }

    if let path = options.values["csv"], let file = fopen(path, "w") {
        fputs("sequence,present_ms,arrival_ms,ready_ms,dequeued_ms,submit_ms,done_ms,sent_ms,bytes,idr,qp\n", file)
        let base = rows.first!.present
        for r in rows {
            func ms(_ t: Int64) -> String { String(format2: "%.3f", HostClock.milliseconds(t - base)) }
            fputs("\(r.sequence),\(ms(r.present)),\(ms(r.arrival)),\(ms(r.ready)),\(ms(r.dequeued)),\(ms(r.submit)),\(ms(r.done)),\(ms(r.sent)),\(r.bytes),\(r.idr ? 1 : 0),\(r.qp)\n", file)
        }
        fclose(file)
        print("wrote \(path)")
    }
}

extension String {
    func padding(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
