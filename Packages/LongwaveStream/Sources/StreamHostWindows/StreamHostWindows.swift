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
    public let raw: OpaquePointer
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
    public let raw: OpaquePointer
    public let texture: UnsafeMutableRawPointer
    public let width: Int
    public let height: Int
    /// The capture sequence, or the producer's frame number for an external frame.
    public let sequence: UInt64
    /// QPC ticks. Capture: OS composition, shim arrival, GPU copy queued.
    /// External: producer submit, slot taken, producer's GPU work finished.
    public let presentTicks: Int64
    public let arrivalTicks: Int64
    public let readyTicks: Int64
    /// What an external frame source adds; nil for WGC and duplication.
    public let external: ExternalFrame?

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
        external = lw_frame_get_source_info(raw).map { ExternalFrame($0.pointee) }
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

// MARK: - External frame source

/// The parts of an external frame (lw_frame_source.h) beyond the picture.
public struct ExternalFrame: @unchecked Sendable {
    public enum Layout: Sendable { case mono, sideBySide, separateEyes }
    /// The attach this frame came from; a new one means a re-attached producer.
    public let generation: UInt64
    public let layout: Layout
    /// The right eye's texture with `.separateEyes` (the left is `CapturedFrame.texture`).
    public let rightTexture: UnsafeMutableRawPointer?
    /// The auxiliary (depth) texture, its DXGI format and size.
    public let auxTexture: UnsafeMutableRawPointer?
    public let auxFormat: UInt32
    public let auxWidth: Int
    public let auxHeight: Int
    /// The DXGI format of the picture.
    public let imageFormat: UInt32
    /// The producer's side data (v3 side-data TLVs), to send with this frame.
    public let sideData: [UInt8]

    init(_ info: lw_frame_source_info) {
        generation = info.generation
        switch Int32(info.format.layout) {
        case LW_FS_LAYOUT_STEREO_SIDE_BY_SIDE: layout = .sideBySide
        case LW_FS_LAYOUT_STEREO_SEPARATE: layout = .separateEyes
        default: layout = .mono
        }
        rightTexture = info.textures.1
        auxTexture = info.textures.2
        auxFormat = info.format.aux_format
        auxWidth = Int(info.format.aux_width)
        auxHeight = Int(info.format.aux_height)
        imageFormat = info.format.image_format
        sideData = info.side_data_size == 0 ? []
            : Array(UnsafeBufferPointer(start: info.side_data, count: Int(info.side_data_size)))
    }
}

/// What the host tells a producer each display frame (lw_fs_host_state):
/// the latest predicted head pose, eye geometry, gaze and pacing. OpenXR
/// conventions, as StreamWire's STATE: metres, right-handed, +Y up, -Z forward.
public struct ExternalHostState: Sendable {
    /// `XrPosef`.
    public struct Pose: Sendable {
        public var orientation: SIMD4<Float> = SIMD4(0, 0, 0, 1) // x, y, z, w
        public var position: SIMD3<Float> = .zero
        public init() {}
    }
    /// `XrFovf`: signed angles in radians, left and down negative.
    public struct FieldOfView: Sendable {
        public var angleLeft: Float = 0, angleRight: Float = 0, angleUp: Float = 0, angleDown: Float = 0
        public init() {}
    }
    /// The client's STATE sequence number; wraps (compare with
    /// lw_fs_serial_newer / StreamWire's SerialNumber).
    public var poseSequence: UInt32 = 0
    public var poseDisplayTicks: Int64 = 0
    public var spaceEpoch: UInt32 = 0
    public var head: Pose?
    public var eyeOffsets = (Pose(), Pose())
    public var eyeFieldsOfView = (FieldOfView(), FieldOfView())
    public var gaze: (direction: SIMD3<Float>, distance: Float, ticks: Int64)?
    public var refreshMillihertz: UInt32 = 0
    public var nextFrameStartTicks: Int64 = 0
    /// The render size per eye the client asked for; nil = the producer chooses.
    public var requestedEye: (width: UInt32, height: UInt32)?
    public init() {}

    var raw: lw_fs_host_state {
        func pose(_ p: Pose) -> lw_fs_pose {
            lw_fs_pose(orientation: (p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w),
                       position: (p.position.x, p.position.y, p.position.z))
        }
        func fov(_ f: FieldOfView) -> lw_fs_fov {
            lw_fs_fov(angle_left: f.angleLeft, angle_right: f.angleRight, angle_up: f.angleUp, angle_down: f.angleDown)
        }
        var s = lw_fs_host_state()
        s.pose_sequence = poseSequence
        s.pose_display_qpc = poseDisplayTicks
        s.space_epoch = spaceEpoch
        if let head {
            s.pose_valid = 1
            s.head = pose(head)
            s.eye_offset = (pose(eyeOffsets.0), pose(eyeOffsets.1))
            s.eye_fov = (fov(eyeFieldsOfView.0), fov(eyeFieldsOfView.1))
        }
        if let gaze {
            s.gaze_valid = 1
            s.gaze_direction = (gaze.direction.x, gaze.direction.y, gaze.direction.z)
            s.gaze_distance = gaze.distance
            s.gaze_qpc = gaze.ticks
        }
        s.refresh_millihz = refreshMillihertz
        if let requestedEye {
            s.requested_eye_width = requestedEye.width & ~1
            s.requested_eye_height = requestedEye.height & ~1
        }
        s.next_frame_start_qpc = nextFrameStartTicks
        s.written_qpc = HostClock.now()
        return s
    }
}

/// Frames another process renders (an in-game depth component, a VR
/// compositor), delivered like captured frames: lw_frame_source.h.
public final class ExternalFrameSource: @unchecked Sendable {
    public struct Statistics: Sendable {
        public let attached: Bool
        public let producerPID: UInt32
        public let generation: UInt64
        public let attaches, refusals, detaches, producerExits: UInt64
        public let lastRefusal: UInt32
        public let delivered, fenceTimeouts: UInt64
        /// Attaches ended for producer misbehaviour (impossible metadata in the
        /// section, or a fence that stopped moving).
        public let producerFaults: UInt64
        /// Attaches ended because the host's own device was removed.
        public let hostDeviceLost: UInt64
        /// This generation's ring, from the shared section.
        public let submitted, superseded, starved, consumed, dropped: UInt64
    }

    private final class Sink {
        let handler: @Sendable (CapturedFrame) -> Void
        init(_ handler: @escaping @Sendable (CapturedFrame) -> Void) { self.handler = handler }
    }

    private let raw: Mutex<OpaquePointer?>
    private let sink: Unmanaged<Sink>
    private let device: GraphicsDevice

    /// Listens on `channel`. `onFrame` runs on the source's thread; hand the
    /// frame off, and let it go only once the GPU is done with it (after the
    /// encode). It may call `stop()` or drop the last reference to the source.
    /// `producerSID` grants one more account access (a host running as SYSTEM
    /// names the signed-in user).
    public init(device: GraphicsDevice, channel: String, producerSID: String? = nil,
                onFrame: @escaping @Sendable (CapturedFrame) -> Void) throws {
        self.device = device
        let sink = Unmanaged.passRetained(Sink(onFrame))
        var source: OpaquePointer?
        let status = channel.withCString { channelName in
            withOptionalCString(producerSID) { sid in
                var params = lw_frame_source_params(channel: channelName, producer_sid: sid)
                return lw_frame_source_start(device.raw, &params, { context, frame in
                    guard let context, let frame else { return }
                    // Held for the whole call: a handler that stops the
                    // source releases the source's reference to the sink.
                    let sink = Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue()
                    withExtendedLifetime(sink) { sink.handler(CapturedFrame(frame)) }
                }, sink.toOpaque(), &source)
            }
        }
        do {
            try check(status, "lw_frame_source_start")
        } catch {
            sink.release()
            throw error
        }
        self.sink = sink
        raw = Mutex(source)
    }

    /// Publishes the state the producer reads. Any thread.
    public func publish(_ state: ExternalHostState) {
        var s = state.raw
        raw.withLock { source in
            if let source { lw_frame_source_publish(source, &s) }
        }
    }

    public var statistics: Statistics {
        raw.withLock { source in
            var s = lw_frame_source_stats()
            if let source { lw_frame_source_get_stats(source, &s) }
            return Statistics(attached: s.attached != 0, producerPID: s.producer_pid, generation: s.generation,
                              attaches: s.attaches, refusals: s.refusals, detaches: s.detaches,
                              producerExits: s.producer_exits, lastRefusal: s.last_refusal, delivered: s.delivered,
                              fenceTimeouts: s.fence_timeouts, producerFaults: s.producer_faults, hostDeviceLost: s.host_device_lost, submitted: s.submitted, superseded: s.superseded,
                              starved: s.starved, consumed: s.consumed, dropped: s.dropped)
        }
    }

    /// Stops listening; returns once no frame callback is running (or, called
    /// from `onFrame`, at once: no callback follows the current one). Idempotent.
    public func stop() {
        let source = raw.withLock { value -> OpaquePointer? in
            defer { value = nil }
            return value
        }
        guard let source else { return }
        lw_frame_source_stop(source)
        sink.release()
    }

    deinit { stop() }
}

func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
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
        /// CBR only: 0 single pass, 1 a quarter-resolution first pass, 2 a full-resolution one.
        public var multiPass: Int = 0
        /// CBR only: spatial adaptive quantisation strength 1...15, 0 off.
        public var spatialAQ: Int = 0
        /// CBR only: the highest QP allowed, 1...51; 0 no cap.
        public var maxQP: Int = 0
        public var intraRefreshPeriod: Int = 0
        public var slices: Int = 1
        /// Wait on an NVENC completion event rather than blocking in the lock call.
        public var asyncMode = false
        /// 1...51 encodes at that constant QP instead of CBR at `bitrate`
        /// (which then only caps the sender); 0 is CBR.
        public var constantQP = 0
        /// HEVC only: 10 encodes Main10 from the same 8-bit input; 8 is Main.
        public var bitDepth = 8
        /// NVENC's tuning: ultra-low latency (the host's) or low latency.
        public var lowLatencyTuning = false
        /// CBR only: temporal adaptive quantisation.
        public var temporalAQ = false
        /// CBR only: the I to P bit ratio aimed for in a short VBV; 0 is NVENC's default.
        public var keyFrameScale = 0
        /// CBR only: the lowest QP allowed, 1...51; 0 no floor.
        public var minQP = 0
        /// Write each picture's reconstruction to the `recon` texture `encode` is given.
        public var reconstruction = false
        /// Take a QP delta map (one per 32x32 CTB) with each picture.
        public var qpMap = false

        /// CTBs a QP map covers: one per 32x32 block, raster order.
        public var qpMapSize: (width: Int, height: Int) { ((width + 31) / 32, (height + 31) / 32) }

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
    public private(set) var parameters: Parameters
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
        params.multi_pass = UInt32(max(0, min(parameters.multiPass, 2)))
        params.spatial_aq = UInt32(max(0, min(parameters.spatialAQ, 15)))
        params.max_qp = UInt32(max(0, min(parameters.maxQP, 51)))
        params.intra_refresh_period = UInt32(parameters.intraRefreshPeriod)
        params.slices = UInt32(parameters.slices)
        params.async_mode = parameters.asyncMode ? 1 : 0
        params.const_qp = UInt32(max(0, min(parameters.constantQP, 51)))
        params.bit_depth = parameters.codec == .hevc && parameters.bitDepth == 10 ? 10 : 8
        params.tuning = parameters.lowLatencyTuning ? 1 : 0
        params.temporal_aq = parameters.temporalAQ ? 1 : 0
        params.key_frame_scale = UInt32(max(0, min(parameters.keyFrameScale, 255)))
        params.min_qp = UInt32(max(0, min(parameters.minQP, 51)))
        params.recon = parameters.reconstruction ? 1 : 0
        params.qp_map = parameters.qpMap ? 1 : 0
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

    /// Encodes one of our own textures (BGRA8, encoder-sized): the foveation
    /// warp's output.
    public func encode<R>(_ texture: GraphicsTexture, timestamp: UInt64, forceIDR: Bool = false,
                          _ body: (Picture) throws -> R) throws -> R {
        var packet = lw_packet()
        try check(lw_encoder_encode(raw, texture.raw, timestamp, forceIDR ? UInt32(LW_ENCODE_FORCE_IDR) : 0, &packet),
                  "lw_encoder_encode")
        return try body(Picture(bytes: UnsafeRawBufferPointer(start: packet.data, count: Int(packet.size)),
                                isIDR: packet.is_idr != 0, averageQP: Int(packet.average_qp),
                                timestamp: packet.timestamp, submitTicks: packet.submit_qpc,
                                doneTicks: packet.done_qpc))
    }

    /// `encode(_:timestamp:forceIDR:_:)` with a QP delta map (`Parameters.qpMap`,
    /// `qpMapSize` entries) and a reconstruction target (`Parameters.reconstruction`,
    /// an encoder-sized `.nv12` texture).
    public func encode<R>(_ texture: GraphicsTexture, timestamp: UInt64, forceIDR: Bool = false, qpDeltaMap: [Int8]?,
                          recon: GraphicsTexture?, _ body: (Picture) throws -> R) throws -> R {
        var packet = lw_packet()
        let flags = forceIDR ? UInt32(LW_ENCODE_FORCE_IDR) : 0
        let status: lw_status = (qpDeltaMap ?? []).withUnsafeBufferPointer { map in
            var extras = lw_encode_extras()
            extras.qp_delta_map = qpDeltaMap == nil ? nil : map.baseAddress
            extras.qp_delta_map_size = UInt32(map.count)
            extras.recon = recon?.raw
            return lw_encoder_encode_ex(raw, texture.raw, timestamp, flags, &extras, &packet)
        }
        try check(status, "lw_encoder_encode_ex")
        return try body(Picture(bytes: UnsafeRawBufferPointer(start: packet.data, count: Int(packet.size)),
                                isIDR: packet.is_idr != 0, averageQP: Int(packet.average_qp),
                                timestamp: packet.timestamp, submitTicks: packet.submit_qpc,
                                doneTicks: packet.done_qpc))
    }

    /// A new bitrate and frame rate in the same session: no key frame.
    public func reconfigure(bitrate: Int, fps: Int) throws {
        try check(lw_encoder_reconfigure(raw, UInt32(bitrate), UInt32(fps)), "lw_encoder_reconfigure")
        parameters.bitrate = bitrate
        parameters.fps = fps
    }

    /// Stops the encoder predicting from these pictures (by timestamp).
    public func invalidate(timestamps: [UInt64]) throws {
        try check(lw_encoder_invalidate(raw, timestamps, UInt32(timestamps.count)), "lw_encoder_invalidate")
    }

    public func setBitrate(_ bitsPerSecond: Int) throws {
        try check(lw_encoder_set_bitrate(raw, UInt32(bitsPerSecond)), "lw_encoder_set_bitrate")
        parameters.bitrate = bitsPerSecond
    }
}

// MARK: - Textures and the foveation warp

/// A texture on the shim's device that we own: a render target the shim's
/// shaders write and the encoder or a shader can read.
public final class GraphicsTexture: @unchecked Sendable {
    public enum Format: UInt32, Sendable {
        case bgra8 = 1        // LW_TEXTURE_BGRA8
        case rgba32Float = 2  // LW_TEXTURE_RGBA32F
        case r32Float = 3     // LW_TEXTURE_R32F
        /// An encoder's reconstruction (`VideoEncoder.Parameters.reconstruction`): GPU only, no `read()`.
        case nv12 = 4         // LW_TEXTURE_NV12

        public var bytesPerPixel: Int {
            switch self {
            case .bgra8, .r32Float: 4
            case .rgba32Float: 16
            case .nv12: 1 // luma; the chroma plane adds half again
            }
        }
    }

    public let raw: UnsafeMutableRawPointer
    private let device: GraphicsDevice
    public let width: Int
    public let height: Int
    public let format: Format

    /// - Parameter pixels: Initial contents, tightly packed rows, or nil.
    public init(device: GraphicsDevice, width: Int, height: Int, format: Format,
                pixels: UnsafeRawBufferPointer? = nil) throws {
        if let pixels { precondition(pixels.count >= width * height * format.bytesPerPixel, "too few pixels") }
        var texture: UnsafeMutableRawPointer?
        try check(lw_texture_create(device.raw, Int32(width), Int32(height), format.rawValue, pixels?.baseAddress,
                                    UInt32(width * format.bytesPerPixel), &texture), "lw_texture_create")
        raw = texture!
        self.device = device
        self.width = width
        self.height = height
        self.format = format
    }

    deinit { lw_texture_release(raw) }

    /// Queue a GPU crop from a captured SBS picture into this eye-sized texture.
    public func copy(from frame: CapturedFrame, x: Int, y: Int = 0) throws {
        try copy(fromRaw: frame.texture, x: x, y: y)
    }

    public func copy(from source: GraphicsTexture, x: Int, y: Int = 0) throws {
        try copy(fromRaw: source.raw, x: x, y: y)
    }

    private func copy(fromRaw source: UnsafeMutableRawPointer, x: Int, y: Int) throws {
        guard x >= 0, y >= 0, x <= Int(UInt32.max), y <= Int(UInt32.max) else {
            throw ShimError(operation: "lw_texture_copy_region", status: LW_E_INVALID_ARG, message: "invalid crop origin")
        }
        try check(lw_texture_copy_region(device.raw, source, UInt32(x), UInt32(y), raw), "lw_texture_copy_region")
    }

    /// The pixels, tightly packed rows. Waits for the GPU: tests and diagnostics only.
    public func read() throws -> [UInt8] {
        let pitch = width * format.bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: pitch * height)
        try bytes.withUnsafeMutableBytes { buffer in
            try check(lw_texture_read(device.raw, raw, buffer.baseAddress, UInt32(pitch)), "lw_texture_read")
        }
        return bytes
    }
}

/// v3's centre/edge foveation warp on the GPU (lw_warp_*): each eye of a
/// side-by-side render texture packed into a smaller wire texture.
public final class FoveationWarpPass: @unchecked Sendable {
    /// One eye's sampling map: per axis StreamWire's `CentreEdgeAxisMapping.constants`
    /// (centre start, centre end, edge ratio, packed length), passed on unchanged.
    public struct Eye: Sendable, Hashable {
        public var x: SIMD4<Float>
        public var y: SIMD4<Float>

        public init(x: SIMD4<Float>, y: SIMD4<Float>) {
            self.x = x
            self.y = y
        }
    }

    private let raw: OpaquePointer
    private let device: GraphicsDevice

    public init(device: GraphicsDevice) throws {
        var warp: OpaquePointer?
        try check(lw_warp_create(device.raw, &warp), "lw_warp_create")
        raw = warp!
        self.device = device
    }

    deinit { lw_warp_release(raw) }

    /// Queues the warp of `source` (two `renderEye` images side by side) into
    /// `destination` (two `wireEye` images side by side). GPU work only.
    public func apply(source: UnsafeMutableRawPointer, renderEye: (width: Int, height: Int),
                      destination: GraphicsTexture, wireEye: (width: Int, height: Int),
                      left: Eye, right: Eye) throws {
        func axis(_ v: SIMD4<Float>) -> lw_warp_axis { lw_warp_axis(lower: v.x, upper: v.y, ratio: v.z, length: v.w) }
        var params = lw_warp_params()
        params.render_eye_width = Int32(renderEye.width)
        params.render_eye_height = Int32(renderEye.height)
        params.wire_eye_width = Int32(wireEye.width)
        params.wire_eye_height = Int32(wireEye.height)
        params.eyes = (lw_warp_eye(x: axis(left.x), y: axis(left.y)), lw_warp_eye(x: axis(right.x), y: axis(right.y)))
        try check(lw_warp_apply(raw, source, destination.raw, &params), "lw_warp_apply")
    }

    public func apply(source: CapturedFrame, renderEye: (width: Int, height: Int), destination: GraphicsTexture,
                      wireEye: (width: Int, height: Int), left: Eye, right: Eye) throws {
        try apply(source: source.texture, renderEye: renderEye, destination: destination, wireEye: wireEye,
                  left: left, right: right)
    }

    public func apply(source: GraphicsTexture, renderEye: (width: Int, height: Int), destination: GraphicsTexture,
                      wireEye: (width: Int, height: Int), left: Eye, right: Eye) throws {
        try apply(source: source.raw, renderEye: renderEye, destination: destination, wireEye: wireEye,
                  left: left, right: right)
    }
}

/// Motion between two pictures from NVENC's motion-estimation-only mode
/// (`lw_motion_*`): the encoder engine's search, not the 3D engine's, so it
/// doesn't queue behind a game. Its own encoder session; `estimate` waits for
/// the result (a few ms beside the colour encode), so call it off the encode thread.
public final class MotionSearch: @unchecked Sendable {
    public struct Result: Sendable {
        public var gridWidth: Int
        public var gridHeight: Int
        public var block: Int
        /// Per block x then y, quarter pixels: current(p) matches reference(p + v).
        public var vectors: [Int16]
        /// 0: no inter vector.
        public var known: [UInt8]
        /// Submit to result, the encoder engine's queue included.
        public var milliseconds: Double
        public var knownBlocks: Int
    }

    public let width: Int
    public let height: Int
    private let raw: OpaquePointer

    /// `width` x `height`: the pictures searched (BGRA8). `block`: the output
    /// grid's block side, 8, 16 or 32 pixels.
    public init(device: GraphicsDevice, width: Int, height: Int, block: Int = 8, preset: Int = 1) throws {
        var params = lw_motion_params(width: Int32(width), height: Int32(height), preset: UInt32(preset), block: UInt32(block))
        var motion: OpaquePointer?
        try check(lw_motion_create(device.raw, &params, &motion), "lw_motion_create")
        raw = motion!
        self.width = width
        self.height = height
    }

    deinit { lw_motion_release(raw) }

    public func estimate(current: GraphicsTexture, reference: GraphicsTexture) throws -> Result {
        var field = lw_motion_field()
        try check(lw_motion_estimate(raw, current.raw, reference.raw, &field), "lw_motion_estimate")
        let blocks = Int(field.grid_width) * Int(field.grid_height)
        return Result(gridWidth: Int(field.grid_width), gridHeight: Int(field.grid_height), block: Int(field.block),
                      vectors: Array(UnsafeBufferPointer(start: field.vectors, count: blocks * 2)),
                      known: Array(UnsafeBufferPointer(start: field.known, count: blocks)),
                      milliseconds: field.stats.submit_ms + field.stats.wait_ms, knownBlocks: Int(field.stats.known_blocks))
    }
}

/// A PCVR frame's depth for the depthVideo stream (lw_depth_*): both eyes
/// side by side as grey BGRA8 holding inverse depth, `near / z`.
public final class DepthPass: @unchecked Sendable {
    public enum Source: Sendable, Equatable {
        /// Estimated from a side-by-side colour frame's two eyes. `baseline`:
        /// metres between the eyes along x; `maxDisparity`: grid texels, 1...128.
        case stereo(baseline: Float, maxDisparity: Int)
        /// Planar depth in metres (R32F or R16F, side by side).
        case linear
    }

    /// The nearest depth a stereo estimate can report: its widest disparity.
    public static func stereoNear(baseline: Float, maxDisparity: Int, leftTangents: SIMD4<Float>, depthEyeWidth: Int) -> Float {
        baseline / (Float(maxDisparity) * (leftTangents.y - leftTangents.x) / Float(depthEyeWidth))
    }

    private let raw: OpaquePointer

    public init(device: GraphicsDevice) throws {
        var depth: OpaquePointer?
        try check(lw_depth_create(device.raw, &depth), "lw_depth_create")
        raw = depth!
    }

    deinit { lw_depth_release(raw) }

    /// That apply's passes, ms: luminance, matching, output (stereo; linear has the output only).
    public var passMilliseconds: (luma: Double, match: Double, output: Double) {
        var out: (Float, Float, Float) = (-1, -1, -1)
        withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: Float.self, capacity: 3) { lw_depth_pass_milliseconds(raw, $0) } }
        return (Double(out.0), Double(out.1), Double(out.2))
    }

    public enum DebugGrid: Int32 { case luma = 0, disparity = 1, cleaned = 2 }

    /// Diagnostics: one of the last stereo estimate's grids, row-major, both
    /// eyes side by side: its luminance, its raw disparities, or those that
    /// survived cleaning (-1 = unknown). Waits for the GPU.
    public func debugGrid(_ which: DebugGrid) throws -> (width: Int, height: Int, values: [Float]) {
        var width: Int32 = 0, height: Int32 = 0
        try check(lw_depth_debug_read(raw, which.rawValue, nil, 0, &width, &height), "lw_depth_debug_read")
        var values = [Float](repeating: 0, count: Int(width * height))
        try values.withUnsafeMutableBufferPointer {
            try check(lw_depth_debug_read(raw, which.rawValue, $0.baseAddress, Int32($0.count), &width, &height),
                      "lw_depth_debug_read")
        }
        return (Int(width), Int(height), values)
    }

    /// GPU time of the latest apply the GPU has finished, ms; nil before the first.
    public var gpuMilliseconds: Double? {
        let ms = lw_depth_gpu_milliseconds(raw)
        return ms >= 0 ? Double(ms) : nil
    }

    /// Queues `destination`'s depth (two `depthEye` images side by side) from
    /// `source` (two `sourceEye` images). `tangents` per eye: left, right, up,
    /// down. `near`: the depth encoded as 1. GPU work only.
    public func apply(source: UnsafeMutableRawPointer, kind: Source, sourceEye: (width: Int, height: Int),
                      destination: GraphicsTexture, depthEye: (width: Int, height: Int),
                      tangents: (left: SIMD4<Float>, right: SIMD4<Float>), near: Float) throws {
        var params = lw_depth_params()
        params.source_eye_width = Int32(sourceEye.width)
        params.source_eye_height = Int32(sourceEye.height)
        params.depth_eye_width = Int32(depthEye.width)
        params.depth_eye_height = Int32(depthEye.height)
        let l = tangents.left, r = tangents.right
        params.tangents = ((l.x, l.y, l.z, l.w), (r.x, r.y, r.z, r.w))
        params.near_depth = near
        switch kind {
        case .stereo(let baseline, let maxDisparity):
            params.source_kind = UInt32(LW_DEPTH_STEREO)
            params.baseline = baseline
            params.max_disparity = Int32(maxDisparity)
        case .linear:
            params.source_kind = UInt32(LW_DEPTH_LINEAR)
        }
        try check(lw_depth_apply(raw, source, destination.raw, &params), "lw_depth_apply")
    }

    public func apply(source: GraphicsTexture, kind: Source, sourceEye: (width: Int, height: Int),
                      destination: GraphicsTexture, depthEye: (width: Int, height: Int),
                      tangents: (left: SIMD4<Float>, right: SIMD4<Float>), near: Float) throws {
        try apply(source: source.raw, kind: kind, sourceEye: sourceEye, destination: destination, depthEye: depthEye,
                  tangents: tangents, near: near)
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

/// A mono float32 stream played into a render endpoint (lw_audio_render): the
/// headset's microphone into a virtual cable, so PC apps hear it as a
/// microphone. Windows converts it to the endpoint's mix format and rate.
public final class AudioRender: @unchecked Sendable {
    private final class Source {
        let fill: (UnsafeMutableBufferPointer<Float>) -> Void
        init(_ fill: @escaping (UnsafeMutableBufferPointer<Float>) -> Void) { self.fill = fill }
    }

    /// The first active render endpoint whose name contains any of `names`
    /// (case-insensitive), in the order `names` lists them.
    public static func endpoint(matching names: [String]) -> AudioLoopback.Endpoint? {
        let endpoints = AudioLoopback.endpoints()
        for name in names {
            if let match = endpoints.first(where: { $0.name.lowercased().contains(name.lowercased()) }) {
                return match
            }
        }
        return nil
    }

    private var raw: OpaquePointer?
    private let source: Unmanaged<Source>
    public let sampleRate: Int

    /// `fill` runs on the shim's MMCSS audio thread every few milliseconds and
    /// must fill the whole buffer without blocking.
    public init(endpointID: String?, sampleRate: Int, fill: @escaping (UnsafeMutableBufferPointer<Float>) -> Void) throws {
        let source = Unmanaged.passRetained(Source(fill))
        var render: OpaquePointer?
        let status = lw_audio_render_start(endpointID, UInt32(sampleRate), { context, out, frames in
            guard let context, let out else { return }
            let source = Unmanaged<Source>.fromOpaque(context).takeUnretainedValue()
            source.fill(UnsafeMutableBufferPointer(start: out, count: Int(frames)))
        }, source.toOpaque(), &render)
        do {
            try check(status, "lw_audio_render_start")
        } catch {
            source.release()
            throw error
        }
        self.source = source
        self.sampleRate = sampleRate
        raw = render
    }

    public func stop() {
        guard let raw else { return }
        self.raw = nil
        lw_audio_render_stop(raw)
        source.release()
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
