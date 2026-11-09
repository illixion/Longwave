// The desktop stream's picture: the primary monitor through Windows.Graphics.Capture
// (cursor composited), encoded once with NVENC as HEVC Main and handed to every
// viewer. Runs only while a viewer watches.
//
// Capture delivers a frame only when the screen changes, so each one is copied
// into a texture of our own before its ring slot goes back: a viewer joining a
// still desktop, or one waiting for a key frame, gets it from there.

import Dispatch
import Foundation
import StreamHost
import StreamHostWindows
import StreamWire

final class DesktopCapture: @unchecked Sendable {
    struct Encoded {
        /// Length-prefixed NAL units, parameter sets taken out.
        var sample: [UInt8]
        var isKeyFrame: Bool
        /// Host ns on QPC, when the OS composed the picture.
        var captureTime: UInt64
        /// The format, with every key frame.
        var format: FormatDescription?
    }

    static let maxFrameRate = 60
    private static let minBitrate = 3_000_000

    private let log: HostLog
    /// Called on the encode thread with every frame.
    private let onFrame: (Encoded) -> Void
    /// Whether every viewer can take another frame now (their send queues have room).
    private let canSend: () -> Bool
    private let lock = NSLock()
    private var current: Run?
    private var bitrate = 20_000_000

    init(log: HostLog, canSend: @escaping () -> Bool, onFrame: @escaping (Encoded) -> Void) {
        self.log = log
        self.canSend = canSend
        self.onFrame = onFrame
    }

    var isRunning: Bool { lock.withLock { current != nil } }

    /// The captured monitor's origin on the virtual desktop, while capture runs.
    var origin: (x: Int, y: Int)? { lock.withLock { current?.origin } }

    /// Starts capturing the primary monitor. Throws when it can't.
    func start() throws {
        guard !isRunning else { return }
        guard let monitor = Monitor.all().first(where: \.isPrimary) ?? Monitor.all().first else {
            throw HostError("no monitor to capture")
        }
        let run = try Run(monitor: monitor, owner: self)
        lock.withLock { current = run }
        log.line("desktop: capturing \(monitor)")
        run.begin()
    }

    /// Stops capture. Doesn't wait: the run's thread lets its capture, encoder and still go as it ends.
    func stop() {
        guard let run = lock.withLock({ () -> Run? in defer { current = nil }; return current }) else { return }
        run.end()
        log.line("desktop: capture stopping")
    }

    func requestKeyFrame() { lock.withLock { current }?.requestKeyFrame() }

    /// The slowest viewer's budget, bits/s.
    func setBitrate(_ bitsPerSecond: Int) {
        lock.withLock { bitrate = max(bitsPerSecond, Self.minBitrate) }
    }

    /// The viewers' queues drained: a held frame can go now.
    func pipeCleared() { lock.withLock { current }?.poke() }

    fileprivate var currentBitrate: Int { lock.withLock { bitrate } }
    fileprivate var hostLog: HostLog { log }
    fileprivate func deliver(_ encoded: Encoded) { onFrame(encoded) }
    fileprivate var viewersCanTakeAFrame: Bool { canSend() }
}

/// One capture, from start to stop, with everything its thread uses.
private final class Run: @unchecked Sendable {
    let origin: (x: Int, y: Int)
    private unowned let owner: DesktopCapture
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var running = true
    private var pending: CapturedFrame?
    private var keyFrameWanted = true

    // The thread's.
    private let device: GraphicsDevice
    private var capture: CaptureSession?
    private var still: GraphicsTexture?
    private var stillCaptureTime: UInt64 = 0
    private var stillChanged = false
    private var encoder: VideoEncoder?
    private var lastEncode: UInt64 = 0

    init(monitor: Monitor, owner: DesktopCapture) throws {
        self.owner = owner
        origin = (monitor.x, monitor.y)
        device = try GraphicsDevice(for: monitor)
        capture = try CaptureSession(device: device, monitor: monitor, backend: .graphicsCapture, cursor: true) { [weak self] frame in
            self?.arrived(frame)
        }
    }

    func begin() {
        let thread = Thread { [self] in loop() }
        thread.name = "desktop encoder"
        thread.start()
    }

    func end() {
        lock.withLock { running = false }
        wake.signal()
    }

    func requestKeyFrame() {
        lock.withLock { keyFrameWanted = true }
        wake.signal()
    }

    func poke() { wake.signal() }

    private func arrived(_ frame: CapturedFrame) {
        lock.withLock { pending = frame } // an older one is released here
        wake.signal()
    }

    private func loop() {
        let interval = UInt64(1_000_000_000 / DesktopCapture.maxFrameRate)
        var timeout = 50
        while true {
            _ = wake.wait(timeout: .now() + .milliseconds(timeout))
            let (alive, frame, wantsKey) = lock.withLock { () -> (Bool, CapturedFrame?, Bool) in
                defer { pending = nil }
                return (running, pending, keyFrameWanted)
            }
            guard alive else { break }
            timeout = 50
            do {
                if let frame { try keep(frame) }
                guard still != nil, stillChanged || wantsKey else { continue }
                let now = PCVRHost.now()
                if now &- lastEncode < interval {
                    timeout = max(1, Int((interval - (now &- lastEncode)) / 1_000_000))
                    continue
                }
                guard owner.viewersCanTakeAFrame else { continue } // pipeCleared() wakes us
                lock.withLock { keyFrameWanted = false }
                try encode(forceKey: wantsKey)
                lastEncode = now
            } catch {
                owner.hostLog.line("desktop: \(error)")
                encoder = nil
                lock.withLock { keyFrameWanted = true }
                timeout = 500
            }
        }
        capture?.stop()
        capture = nil
        lock.withLock { pending = nil }
        encoder = nil
        still = nil
        owner.hostLog.line("desktop: capture stopped")
    }

    /// Copies the frame into the still (even sides, for the encoder).
    private func keep(_ frame: CapturedFrame) throws {
        let width = frame.width & ~1, height = frame.height & ~1
        guard width >= 64, height >= 64 else { return }
        if still?.width != width || still?.height != height {
            still = try GraphicsTexture(device: device, width: width, height: height, format: .bgra8)
            encoder = nil
        }
        try still!.copy(from: frame, x: 0)
        stillCaptureTime = HostClock.nanoseconds(frame.presentTicks)
        stillChanged = true
    }

    private func encode(forceKey: Bool) throws {
        guard let still else { return }
        let bitrate = owner.currentBitrate
        var forceKey = forceKey
        if encoder == nil {
            var parameters = VideoEncoder.Parameters(width: still.width, height: still.height,
                                                     fps: DesktopCapture.maxFrameRate, bitrate: bitrate)
            parameters.codec = .hevc
            encoder = try VideoEncoder(device: device, parameters: parameters)
            forceKey = true
            owner.hostLog.line("desktop: encoding \(still.width)x\(still.height) HEVC from \(bitrate / 1_000_000) Mbps")
        }
        guard let encoder else { return }
        if abs(encoder.parameters.bitrate - bitrate) * 100 > encoder.parameters.bitrate * 3 {
            try encoder.setBitrate(bitrate)
        }
        let captureTime = stillCaptureTime
        let (unit, isKey) = try encoder.encode(still, timestamp: captureTime, forceIDR: forceKey) { (Array($0.bytes), $0.isIDR) }
        stillChanged = false
        let repacked = AnnexBRepacker.repack(hevc: unit)
        var format: FormatDescription?
        if isKey, !repacked.parameterSets.isEmpty {
            format = FormatDescription(
                streamID: PCVRHost.desktopStreamID, firstFrameNumber: 0, codec: .hevc, formatKind: .annexBParameterSets,
                size: PixelSize(width: UInt16(clamping: still.width), height: UInt16(clamping: still.height)),
                bitDepth: 8, chromaFormat: .yuv420, colour: .bt709, configuration: repacked.parameterSets)
        }
        guard !repacked.sample.isEmpty else { return }
        owner.deliver(DesktopCapture.Encoded(sample: repacked.sample, isKeyFrame: isKey, captureTime: captureTime, format: format))
    }
}
