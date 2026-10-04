// Swift side of the CStreamWin shim: owning wrappers over its opaque handles,
// errors as Swift errors, C callbacks as Swift closures. Nothing here touches
// COM or a Windows header; that is the shim's job (NATIVE_V3_PROTOCOL.md 7.2).
import CStreamWin
import Synchronization

// MARK: - Errors and process set-up

public struct ShimError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let status: Int32
    public let message: String
    public var description: String { "\(operation): \(message) [\(status)]" }
}

@inline(__always)
func check(_ status: lw_status, _ operation: @autoclosure () -> String) throws {
    guard status == LW_OK else {
        throw ShimError(operation: operation(), status: status, message: String(cString: lw_last_error()))
    }
}

/// Reads a fixed-size C `char[N]` field (imported as a tuple) as UTF-8.
func string<T>(fromCharTuple tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

public enum StreamHostRuntime {
    /// DPI awareness, WinRT apartment, timer resolution. Call once from main.
    public static func initialize() throws {
        try check(lw_runtime_init(), "lw_runtime_init")
    }
}

/// The host clock: QueryPerformanceCounter, shared by capture, encode, audio
/// and the network stamps.
public enum HostClock {
    public static let ticksPerSecond = lw_qpc_frequency()
    public static func now() -> Int64 { lw_qpc_now() }
    public static func milliseconds(_ ticks: Int64) -> Double { Double(ticks) * 1000 / Double(ticksPerSecond) }
    public static func nanoseconds(_ ticks: Int64) -> UInt64 {
        let whole = ticks / ticksPerSecond
        let rest = ticks % ticksPerSecond
        return UInt64(whole) &* 1_000_000_000 &+ UInt64(rest * 1_000_000_000 / ticksPerSecond)
    }
}

// MARK: - Displays and device

public struct Monitor: Sendable, CustomStringConvertible {
    let handleBits: UInt
    public let x, y, width, height: Int
    public let refreshHz: Int
    public let isPrimary: Bool
    public let deviceName: String
    public let adapterName: String

    var handle: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: handleBits) }

    public var description: String {
        "\(deviceName) \(width)x\(height)@\(refreshHz)Hz at (\(x),\(y))\(isPrimary ? " primary" : "") on \(adapterName)"
    }

    public static func all() -> [Monitor] {
        let count = Int(lw_monitor_list(nil, 0))
        guard count > 0 else { return [] }
        var raw = [lw_monitor_info](repeating: lw_monitor_info(), count: count)
        let filled = min(count, Int(lw_monitor_list(&raw, Int32(count))))
        return raw.prefix(filled).map { info in
            Monitor(handleBits: UInt(bitPattern: info.handle), x: Int(info.x), y: Int(info.y),
                    width: Int(info.width), height: Int(info.height), refreshHz: Int(info.refresh_hz),
                    isPrimary: info.is_primary != 0, deviceName: string(fromCharTuple: info.device_name),
                    adapterName: string(fromCharTuple: info.adapter_name))
        }
    }
}

/// One D3D11 device shared by capture and encode.
public final class GraphicsDevice: @unchecked Sendable {
    let raw: OpaquePointer
    public let adapterName: String
    public let vendorID: UInt32

    /// The adapter driving `monitor`, or the first hardware adapter.
    public init(for monitor: Monitor?) throws {
        var device: OpaquePointer?
        try check(lw_device_create(monitor?.handle, &device), "lw_device_create")
        raw = device!
        var info = lw_device_info()
        lw_device_get_info(raw, &info)
        adapterName = string(fromCharTuple: info.adapter_name)
        vendorID = info.vendor_id
    }

    deinit { lw_device_release(raw) }
}

// MARK: - Capture

/// A captured picture: a GPU texture the shim lent us. Releasing (deinit)
/// returns its ring slot, so hold it only until it is encoded.
public final class CapturedFrame: @unchecked Sendable {
    let raw: OpaquePointer
    public let texture: UnsafeMutableRawPointer
    public let width: Int
    public let height: Int
    public let sequence: UInt64
    /// QPC ticks: OS composition, shim arrival, GPU copy queued.
    public let presentTicks: Int64
    public let arrivalTicks: Int64
    public let readyTicks: Int64

    init(_ raw: OpaquePointer) {
        self.raw = raw
        let info = lw_frame_get_info(raw)!.pointee
        texture = info.texture
        width = Int(info.width)
        height = Int(info.height)
        sequence = info.sequence
        presentTicks = info.present_qpc
        arrivalTicks = info.arrival_qpc
        readyTicks = info.ready_qpc
    }

    deinit { lw_frame_release(raw) }
}

public final class CaptureSession: @unchecked Sendable {
    public enum Backend: Sendable {
        /// Windows.Graphics.Capture: monitors and windows, cursor composited.
        case graphicsCapture
        /// DXGI Desktop Duplication: monitors only, no cursor.
        case desktopDuplication
    }

    public struct Statistics: Sendable {
        public let osFrames: UInt64
        public let delivered: UInt64
        public let droppedRingFull: UInt64
        public let errors: UInt64
        public let sourceLost: Bool
    }

    private final class Sink {
        let handler: @Sendable (CapturedFrame) -> Void
        init(_ handler: @escaping @Sendable (CapturedFrame) -> Void) { self.handler = handler }
    }

    private let raw: Mutex<OpaquePointer?>
    private let sink: Unmanaged<Sink>
    private let device: GraphicsDevice // the shim's device must outlive the capture

    /// `onFrame` runs on a shim thread; keep it short (hand the frame off).
    public convenience init(device: GraphicsDevice, monitor: Monitor, backend: Backend, cursor: Bool = true,
                            ringSize: Int = 4, onFrame: @escaping @Sendable (CapturedFrame) -> Void) throws {
        var params = lw_capture_params()
        params.backend = backend == .graphicsCapture ? UInt32(LW_CAPTURE_WGC) : UInt32(LW_CAPTURE_DDA)
        params.monitor = monitor.handle
        params.cursor = cursor ? 1 : 0
        params.ring_size = Int32(ringSize)
        try self.init(device: device, onFrame: onFrame) { callback, context, out in
            lw_capture_start(device.raw, &params, callback, context, out)
        }
    }

    /// SPIKE ONLY: synthetic frames on the same path (see lw_capture_start_synthetic).
    public convenience init(syntheticOn device: GraphicsDevice, width: Int, height: Int, fps: Int, panning: Bool,
                            onFrame: @escaping @Sendable (CapturedFrame) -> Void) throws {
        try self.init(device: device, onFrame: onFrame) { callback, context, out in
            lw_capture_start_synthetic(device.raw, Int32(width), Int32(height), UInt32(fps), panning ? 1 : 0,
                                       callback, context, out)
        }
    }

    private init(device: GraphicsDevice, onFrame: @escaping @Sendable (CapturedFrame) -> Void,
                 start: (lw_frame_callback, UnsafeMutableRawPointer, UnsafeMutablePointer<OpaquePointer?>) -> lw_status) throws {
        self.device = device
        let sink = Unmanaged.passRetained(Sink(onFrame))
        var capture: OpaquePointer?
        let status = start({ context, frame in
            guard let context, let frame else { return }
            Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue().handler(CapturedFrame(frame))
        }, sink.toOpaque(), &capture)
        do {
            try check(status, "lw_capture_start")
        } catch {
            sink.release()
            throw error
        }
        self.sink = sink
        raw = Mutex(capture)
    }

    public var statistics: Statistics {
        raw.withLock { capture in
            var stats = lw_capture_stats()
            if let capture { lw_capture_get_stats(capture, &stats) }
            return Statistics(osFrames: stats.os_frames, delivered: stats.delivered,
                              droppedRingFull: stats.dropped_ring_full, errors: stats.errors,
                              sourceLost: stats.last_error == LW_E_ACCESS_LOST)
        }
    }

    /// Stops capture; returns once no frame callback is running. Idempotent.
    public func stop() {
        let capture = raw.withLock { value -> OpaquePointer? in
            defer { value = nil }
            return value
        }
        guard let capture else { return }
        lw_capture_stop(capture)
        sink.release()
    }

    deinit { stop() }
}

// MARK: - Encoder

public final class VideoEncoder: @unchecked Sendable {
    public enum Codec: Sendable { case h264, hevc }

    public struct Parameters: Sendable {
        public var codec: Codec = .hevc
        public var width: Int
        public var height: Int
        public var fps: Int
        public var bitrate: Int
        public var preset: Int = 1
        public var vbvFrames: Int = 1
        public var intraRefreshPeriod: Int = 0
        public var slices: Int = 1
        /// Wait on an NVENC completion event rather than blocking in the lock call.
        public var asyncMode = false

        public init(width: Int, height: Int, fps: Int, bitrate: Int) {
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
        }
    }

    public struct Info: Sendable {
        public let name: String
        public let headerAPI: String
        public let driverAPI: String
        public let supportsReferenceInvalidation: Bool
        public let supportsIntraRefresh: Bool
        public let maxLTRFrames: Int
        public let maxWidth: Int
        public let maxHeight: Int
    }

    /// One encoded picture. `bytes` is valid only inside the closure it is passed to.
    public struct Picture {
        public let bytes: UnsafeRawBufferPointer
        public let isIDR: Bool
        public let averageQP: Int
        public let timestamp: UInt64
        public let submitTicks: Int64
        public let doneTicks: Int64
    }

    private let raw: OpaquePointer
    private let device: GraphicsDevice
    public let parameters: Parameters
    public let info: Info

    public init(device: GraphicsDevice, parameters: Parameters) throws {
        self.device = device
        self.parameters = parameters
        var params = lw_encoder_params()
        params.codec = parameters.codec == .hevc ? UInt32(LW_CODEC_HEVC) : UInt32(LW_CODEC_H264)
        params.width = Int32(parameters.width)
        params.height = Int32(parameters.height)
        params.fps = UInt32(parameters.fps)
        params.bitrate_bps = UInt32(parameters.bitrate)
        params.preset = UInt32(parameters.preset)
        params.vbv_frames = UInt32(parameters.vbvFrames)
        params.intra_refresh_period = UInt32(parameters.intraRefreshPeriod)
        params.slices = UInt32(parameters.slices)
        params.async_mode = parameters.asyncMode ? 1 : 0
        var encoder: OpaquePointer?
        try check(lw_encoder_create(device.raw, &params, &encoder), "lw_encoder_create")
        raw = encoder!
        var i = lw_encoder_info()
        lw_encoder_get_info(raw, &i)
        info = Info(name: string(fromCharTuple: i.name),
                    headerAPI: "\(i.header_api_major).\(i.header_api_minor)",
                    driverAPI: "\(i.driver_api_major).\(i.driver_api_minor)",
                    supportsReferenceInvalidation: i.supports_ref_invalidation != 0,
                    supportsIntraRefresh: i.supports_intra_refresh != 0,
                    maxLTRFrames: Int(i.supports_ltr), maxWidth: Int(i.max_width), maxHeight: Int(i.max_height))
    }

    deinit { lw_encoder_release(raw) }

    /// Encodes synchronously and hands the bitstream to `body` without copying.
    /// Call from one thread at a time.
    public func encode<R>(_ frame: CapturedFrame, timestamp: UInt64, forceIDR: Bool = false,
                          _ body: (Picture) throws -> R) throws -> R {
        var packet = lw_packet()
        try check(lw_encoder_encode(raw, frame.texture, timestamp, forceIDR ? UInt32(LW_ENCODE_FORCE_IDR) : 0, &packet),
                  "lw_encoder_encode")
        return try body(Picture(bytes: UnsafeRawBufferPointer(start: packet.data, count: Int(packet.size)),
                                isIDR: packet.is_idr != 0, averageQP: Int(packet.average_qp),
                                timestamp: packet.timestamp, submitTicks: packet.submit_qpc,
                                doneTicks: packet.done_qpc))
    }

    /// Stops the encoder predicting from these pictures (by timestamp).
    public func invalidate(timestamps: [UInt64]) throws {
        try check(lw_encoder_invalidate(raw, timestamps, UInt32(timestamps.count)), "lw_encoder_invalidate")
    }

    public func setBitrate(_ bitsPerSecond: Int) throws {
        try check(lw_encoder_set_bitrate(raw, UInt32(bitsPerSecond)), "lw_encoder_set_bitrate")
    }
}

// MARK: - Audio

public final class AudioLoopback: @unchecked Sendable {
    public struct Endpoint: Sendable, CustomStringConvertible {
        public let id: String
        public let name: String
        public let channels: Int
        public let sampleRate: Int
        public let channelMask: UInt32
        public let isDefault: Bool
        public var description: String {
            "\(name): \(channels) ch @ \(sampleRate) Hz, mask 0x\(String(channelMask, radix: 16))\(isDefault ? " (default)" : "")"
        }
    }

    public struct Format: Sendable {
        public let sampleRate: Int
        public let channels: Int
        public let bitsPerSample: Int
        public let channelMask: UInt32
        public let isFloat: Bool
        public let bytesPerFrame: Int
    }

    /// One buffer from the engine. `samples` is nil for silence and valid
    /// only during the callback.
    public struct Buffer {
        public let samples: UnsafeRawBufferPointer?
        public let frames: Int
        public let captureTicks: Int64
        public let isSilent: Bool
        public let followsDiscontinuity: Bool
    }

    private final class Sink {
        let handler: (Buffer) -> Void
        init(_ handler: @escaping (Buffer) -> Void) { self.handler = handler }
    }

    public static func endpoints() -> [Endpoint] {
        let count = Int(lw_audio_endpoint_list(nil, 0))
        guard count > 0 else { return [] }
        var raw = [lw_audio_endpoint_info](repeating: lw_audio_endpoint_info(), count: count)
        let filled = min(count, Int(lw_audio_endpoint_list(&raw, Int32(count))))
        return raw.prefix(filled).map {
            Endpoint(id: string(fromCharTuple: $0.id), name: string(fromCharTuple: $0.name), channels: Int($0.channels),
                     sampleRate: Int($0.sample_rate), channelMask: $0.channel_mask, isDefault: $0.is_default != 0)
        }
    }

    /// SPIKE ONLY: a distinct sine per channel (channel n at 250 * (n + 1) Hz).
    public static func playTestTones(endpointID: String?, milliseconds: Int, amplitude: Float) throws {
        try check(lw_audio_play_test_tones(endpointID, UInt32(milliseconds), amplitude), "lw_audio_play_test_tones")
    }

    private var raw: OpaquePointer?
    private let sink: Unmanaged<Sink>
    public let format: Format

    /// `onBuffer` runs on the shim's MMCSS audio thread.
    public init(endpointID: String?, onBuffer: @escaping (Buffer) -> Void) throws {
        let sink = Unmanaged.passRetained(Sink(onBuffer))
        var loopback: OpaquePointer?
        var f = lw_audio_format()
        let status = lw_audio_loopback_start(endpointID, { context, data, frames, bytes, qpc, flags in
            guard let context else { return }
            let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
            sink.handler(Buffer(samples: data.map { UnsafeRawBufferPointer(start: $0, count: Int(bytes)) },
                                frames: Int(frames), captureTicks: qpc,
                                isSilent: flags & UInt32(LW_AUDIO_SILENT) != 0,
                                followsDiscontinuity: flags & UInt32(LW_AUDIO_DISCONTINUITY) != 0))
        }, sink.toOpaque(), &loopback, &f)
        do {
            try check(status, "lw_audio_loopback_start")
        } catch {
            sink.release()
            throw error
        }
        self.sink = sink
        raw = loopback
        format = Format(sampleRate: Int(f.sample_rate), channels: Int(f.channels), bitsPerSample: Int(f.bits_per_sample),
                        channelMask: f.channel_mask, isFloat: f.is_float != 0, bytesPerFrame: Int(f.block_align))
    }

    public func stop() {
        guard let raw else { return }
        self.raw = nil
        lw_audio_loopback_stop(raw)
        sink.release()
    }

    deinit { stop() }
}

// MARK: - Spike helpers

/// SPIKE ONLY: GPU busy-work standing in for a game (lw_spike_gpu_load_start).
public final class SpikeGPULoad: @unchecked Sendable {
    private var raw: OpaquePointer?
    public init(percent: Int) throws {
        var load: OpaquePointer?
        try check(lw_spike_gpu_load_start(Int32(percent), &load), "lw_spike_gpu_load_start")
        raw = load
    }
    public func stop() {
        guard let raw else { return }
        self.raw = nil
        lw_spike_gpu_load_stop(raw)
    }
    deinit { stop() }
}
