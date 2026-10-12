// The external frame source's Windows layer (lw_frame_source.h) end to end
// in one process: a producer on its own D3D11 device and a host on another,
// sharing textures, a fence and the named section exactly as two processes
// would. Needs a GPU; the cross-process checks (crashes, restarts, another
// adapter) are in frame-source-spike, run by hand.
import CStreamWin
import Dispatch
@testable import StreamHostWindows
import Synchronization
import WinSDK
import XCTest

final class ExternalFrameSourceTests: XCTestCase {
    static let width: UInt32 = 1280, height: UInt32 = 720

    override class func setUp() {
        try? StreamHostRuntime.initialize()
    }

    func channelName(_ test: String = #function) -> String {
        "test.\(test.prefix(while: { $0 != "(" })).\(GetCurrentProcessId())"
    }

    /// A producer on its own device (same adapter as the host's).
    final class Producer {
        var device: OpaquePointer?
        var raw: OpaquePointer?
        var pattern: OpaquePointer?

        init(channel: String, aux: Bool = false, slots: UInt32 = 3) throws {
            try check(lw_device_create(nil, &device), "lw_device_create")
            let d3d = lw_device_get_d3d11(device)
            try check(lw_spike_pattern_create(d3d, Int32(width), Int32(height), &pattern), "lw_spike_pattern_create")
            var params = lw_frame_producer_params()
            params.device = d3d
            params.format.layout = UInt32(LW_FS_LAYOUT_MONO)
            params.format.slot_count = slots
            params.format.image_format = UInt32(LW_FS_FORMAT_B8G8R8A8_UNORM)
            params.format.image_width = width
            params.format.image_height = height
            if aux {
                params.format.aux_role = UInt32(LW_FS_AUX_DEPTH)
                params.format.aux_format = UInt32(LW_FS_FORMAT_R32_FLOAT)
                params.format.aux_width = width / 2
                params.format.aux_height = height / 2
            }
            let status = channel.withCString { name -> lw_status in
                params.channel = name
                return lw_frame_producer_attach(&params, &raw, nil)
            }
            try check(status, "lw_frame_producer_attach")
        }

        /// Draws frame `n` (and its aux) and submits it with `n` as side data.
        @discardableResult
        func submit(_ n: UInt64) -> lw_status {
            var slot = lw_frame_producer_slot()
            let status = lw_frame_producer_acquire(raw, &slot)
            guard status == LW_OK else { return status }
            lw_spike_pattern_draw(pattern, slot.textures.0, slot.textures.2, n)
            var side = n
            return withUnsafeBytes(of: &side) {
                lw_frame_producer_submit(raw, slot.index, n, $0.baseAddress, UInt32($0.count))
            }
        }

        func detach() {
            lw_frame_producer_detach(raw)
            raw = nil
        }

        deinit {
            if raw != nil { lw_frame_producer_detach(raw) }
            lw_spike_pattern_release(pattern)
            lw_device_release(device)
        }
    }

    /// Collects delivered frames.
    final class Collector: Sendable {
        let frames = Mutex<[CapturedFrame]>([])
        let arrived = DispatchSemaphore(value: 0)
        func take(_ frame: CapturedFrame) {
            frames.withLock { $0.append(frame) }
            arrived.signal()
        }
        func wait(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
            for _ in 0 ..< count {
                XCTAssertEqual(arrived.wait(timeout: .now() + 2), .success, "frame didn't arrive", file: file, line: line)
            }
        }
    }

    func testFramesArriveWithPictureAuxAndSideData() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let collector = Collector()
        let source = try ExternalFrameSource(device: device, channel: channel) { collector.take($0) }
        defer { source.stop() }
        let producer = try Producer(channel: channel, aux: true)
        XCTAssertTrue(source.statistics.attached)

        var verifier: OpaquePointer?
        try check(lw_spike_pattern_create(lw_device_get_d3d11(device.raw), Int32(Self.width), Int32(Self.height),
                                          &verifier), "lw_spike_pattern_create")
        defer { lw_spike_pattern_release(verifier) }

        for n in UInt64(1) ... 20 {
            XCTAssertEqual(producer.submit(n), LW_OK)
            collector.wait(1)
            guard let frame = collector.frames.withLock({ $0.popLast() }) else { continue }
            XCTAssertEqual(frame.sequence, n)
            XCTAssertEqual(frame.width, Int(Self.width))
            let external = try XCTUnwrap(frame.external)
            XCTAssertEqual(external.sideData, withUnsafeBytes(of: n) { Array($0) })
            XCTAssertEqual(external.auxWidth, Int(Self.width / 2))
            // The fence says the producer's drawing is done: the picture and
            // the aux must already hold frame n.
            var painted: UInt32 = 0
            var aux: Float = 0
            try check(lw_spike_pattern_read(verifier, frame.texture, external.auxTexture, &painted, &aux), "read")
            XCTAssertEqual(painted, UInt32(n))
            XCTAssertEqual(aux, Float(n))
            XCTAssertLessThanOrEqual(frame.presentTicks, frame.arrivalTicks)
            XCTAssertLessThanOrEqual(frame.arrivalTicks, frame.readyTicks)
        }
        XCTAssertEqual(source.statistics.delivered, 20)
    }

    func testFramesEncodeStraightFromTheSharedTexture() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let encoder = try VideoEncoder(device: device, parameters: .init(width: Int(Self.width), height: Int(Self.height),
                                                                         fps: 90, bitrate: 20_000_000))
        let collector = Collector()
        let source = try ExternalFrameSource(device: device, channel: channel) { collector.take($0) }
        defer { source.stop() }
        let producer = try Producer(channel: channel)
        for n in UInt64(1) ... 10 {
            XCTAssertEqual(producer.submit(n), LW_OK)
            collector.wait(1)
            let frame = try XCTUnwrap(collector.frames.withLock { $0.popLast() })
            let bytes = try encoder.encode(frame, timestamp: n, forceIDR: n == 1) { $0.bytes.count }
            XCTAssertGreaterThan(bytes, 0)
        }
    }

    func testHostStateReachesTheProducer() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let source = try ExternalFrameSource(device: device, channel: channel) { _ in }
        defer { source.stop() }
        let producer = try Producer(channel: channel)
        var state = ExternalHostState()
        state.poseSequence = 77
        state.head = .init()
        state.refreshMillihertz = 90_000
        state.gaze = (SIMD3(0, 0, -1), 1.5, 123)
        source.publish(state)
        var read = lw_fs_host_state()
        XCTAssertEqual(lw_frame_producer_read_host_state(producer.raw, &read), LW_OK)
        XCTAssertEqual(read.pose_sequence, 77)
        XCTAssertEqual(read.pose_valid, 1)
        XCTAssertEqual(read.head.orientation.3, 1)
        XCTAssertEqual(read.refresh_millihz, 90_000)
        XCTAssertEqual(read.gaze_valid, 1)
        XCTAssertEqual(read.gaze_distance, 1.5)
    }

    func testNoHostAndOneProducerPerChannel() throws {
        let channel = channelName()
        XCTAssertThrowsError(try Producer(channel: channel)) { error in
            XCTAssertEqual((error as? ShimError)?.status, LW_E_UNAVAILABLE)
        }
        let device = try GraphicsDevice(for: nil)
        let source = try ExternalFrameSource(device: device, channel: channel) { _ in }
        defer { source.stop() }
        let first = try Producer(channel: channel)
        XCTAssertThrowsError(try Producer(channel: channel)) { error in
            XCTAssertEqual((error as? ShimError)?.status, LW_E_BUSY)
        }
        first.detach()
        waitUntil { !source.statistics.attached }
        XCTAssertEqual(source.statistics.detaches, 1)
        XCTAssertNoThrow(try Producer(channel: channel), "the channel is free again")
    }

    func testOneHostPerChannel() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let source = try ExternalFrameSource(device: device, channel: channel) { _ in }
        defer { source.stop() }
        XCTAssertThrowsError(try ExternalFrameSource(device: device, channel: channel) { _ in }) { error in
            XCTAssertEqual((error as? ShimError)?.status, LW_E_BUSY)
        }
    }

    /// The host restarts while the producer still holds the section open, so
    /// the new host inherits it (owner check, epoch bump): the producer's
    /// attach goes stale, it attaches again, and the new ring has a new
    /// generation.
    func testHostRestart() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let collector = Collector()
        var source: ExternalFrameSource? = try ExternalFrameSource(device: device, channel: channel) { collector.take($0) }
        let producer = try Producer(channel: channel)
        XCTAssertEqual(producer.submit(1), LW_OK)
        collector.wait(1)
        let firstGeneration = try XCTUnwrap(collector.frames.withLock { $0.last?.external?.generation })
        source?.stop()
        source = nil
        XCTAssertEqual(producer.submit(2), LW_E_ACCESS_LOST)

        source = try ExternalFrameSource(device: device, channel: channel) { collector.take($0) }
        defer { source?.stop() }
        XCTAssertEqual(producer.submit(2), LW_E_ACCESS_LOST, "the old attach stays over")
        producer.detach()
        let again = try Producer(channel: channel)
        XCTAssertEqual(again.submit(3), LW_OK)
        collector.wait(1)
        let second = try XCTUnwrap(collector.frames.withLock { $0.last })
        XCTAssertEqual(second.sequence, 3)
        XCTAssertGreaterThan(try XCTUnwrap(second.external?.generation), firstGeneration)
    }

    /// The host holds every slot (a stalled encoder): the producer is told
    /// so and drops frames, and carries on as soon as one is released.
    func testStarvationAndRecovery() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let collector = Collector()
        let source = try ExternalFrameSource(device: device, channel: channel) { collector.take($0) }
        defer { source.stop() }
        let producer = try Producer(channel: channel, slots: 2)
        for n in UInt64(1) ... 2 {
            XCTAssertEqual(producer.submit(n), LW_OK)
            collector.wait(1)
        }
        XCTAssertEqual(producer.submit(3), LW_E_BUSY)
        collector.frames.withLock { _ = $0.removeFirst() } // release one
        XCTAssertEqual(producer.submit(4), LW_OK)
        collector.wait(1)
        XCTAssertEqual(collector.frames.withLock { $0.last?.sequence }, 4)
        XCTAssertEqual(source.statistics.starved, 1)
    }

    func testInvalidChannelNames() throws {
        let device = try GraphicsDevice(for: nil)
        for name in ["", "has space", "back\\slash", String(repeating: "x", count: Int(LW_FS_MAX_CHANNEL) + 1)] {
            XCTAssertThrowsError(try ExternalFrameSource(device: device, channel: name) { _ in }, name)
        }
    }

    func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = HostClock.now() + HostClock.ticksPerSecond * 2
        while !condition() {
            if HostClock.now() > deadline { return XCTFail("timed out", file: file, line: line) }
            Sleep(5)
        }
    }
}
