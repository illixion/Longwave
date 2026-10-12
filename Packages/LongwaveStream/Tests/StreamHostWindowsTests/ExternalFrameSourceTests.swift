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

    // MARK: A producer that writes the section directly

    /// Maps the channel's section the way a misbehaving producer would, to
    /// write fields the producer API never lets through.
    func withSection(_ channel: String, _ body: (UnsafeMutablePointer<lw_fs_shared>) throws -> Void) throws {
        let mapping = "Local\\lw_frame_source.\(channel)".withCString(encodedAs: UTF16.self) {
            OpenFileMappingW(DWORD(FILE_MAP_READ) | DWORD(FILE_MAP_WRITE), false, $0)
        }
        let handle = try XCTUnwrap(mapping, "OpenFileMappingW")
        defer { CloseHandle(handle) }
        let view = try XCTUnwrap(MapViewOfFile(handle, DWORD(FILE_MAP_READ) | DWORD(FILE_MAP_WRITE), 0, 0,
                                               SIZE_T(MemoryLayout<lw_fs_shared>.size)), "MapViewOfFile")
        defer { UnmapViewOfFile(view) }
        try body(view.assumingMemoryBound(to: lw_fs_shared.self))
    }

    /// Writes slot `index` as a submitted frame, bypassing lw_frame_producer_submit.
    func forgeReadySlot(_ shared: UnsafeMutablePointer<lw_fs_shared>, index: Int, fence: UInt64,
                        sideDataSize: UInt32) {
        let generation = shared.pointee.generation
        withUnsafeMutablePointer(to: &shared.pointee.slots) {
            $0.withMemoryRebound(to: lw_fs_slot.self, capacity: Int(LW_FS_MAX_SLOTS)) { slots in
                let slot = slots + index
                slot.pointee.fence_value = fence
                slot.pointee.frame_number = 99
                slot.pointee.side_data_size = sideDataSize
                slot.pointee.submit_sequence = 1
                let word = (UInt64(UInt32(truncatingIfNeeded: generation)) << 32) | (1 << 8) | UInt64(LW_FS_SLOT_READY)
                withUnsafeMutablePointer(to: &slot.pointee.state) {
                    UnsafeMutableRawPointer($0).storeBytes(of: word, as: UInt64.self) // aligned 8-byte store: atomic on x64
                }
            }
        }
    }

    /// The finding that motivated lw_fs_host_snapshot: a side data size of
    /// 4 GB written straight into a slot. The host must drop the frame, end
    /// that producer's attach, and read nothing past the slot.
    func testForgedSideDataSizeEndsTheAttach() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let collector = Collector()
        let source = try ExternalFrameSource(device: device, channel: channel) { collector.take($0) }
        defer { source.stop() }
        let producer = try Producer(channel: channel)
        try withSection(channel) { forgeReadySlot($0, index: 0, fence: 1, sideDataSize: .max) }
        waitUntil { source.statistics.producerFaults == 1 }
        XCTAssertFalse(source.statistics.attached)
        XCTAssertEqual(source.statistics.delivered, 0)
        XCTAssertEqual(collector.frames.withLock { $0.count }, 0)
        XCTAssertEqual(producer.submit(1), LW_E_ACCESS_LOST)
        producer.detach()
        // An honest producer is served again.
        let next = try Producer(channel: channel)
        XCTAssertEqual(next.submit(1), LW_OK)
        collector.wait(1)
    }

    /// A fence value the producer never signals: the host gives up after its
    /// timeout and ends the attach, rather than waiting on every frame.
    func testForgedFenceValueEndsTheAttach() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let source = try ExternalFrameSource(device: device, channel: channel) { _ in }
        defer { source.stop() }
        let producer = try Producer(channel: channel)
        try withSection(channel) { forgeReadySlot($0, index: 0, fence: 1_000_000, sideDataSize: 0) }
        waitUntil(seconds: 4) { source.statistics.fenceTimeouts == 1 }
        XCTAssertFalse(source.statistics.attached)
        XCTAssertEqual(producer.submit(1), LW_E_ACCESS_LOST)
    }

    /// The producer raises the section's slot count after attach and marks a
    /// slot ready that has no textures. The host goes by the count it
    /// validated and never touches it.
    func testRaisedSlotCountIsIgnored() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let collector = Collector()
        let source = try ExternalFrameSource(device: device, channel: channel) { collector.take($0) }
        defer { source.stop() }
        let producer = try Producer(channel: channel, slots: 2)
        try withSection(channel) { shared in
            shared.pointee.format.slot_count = UInt32(LW_FS_MAX_SLOTS)
            forgeReadySlot(shared, index: 6, fence: 1, sideDataSize: 0)
        }
        Sleep(400) // more than one pass of the host's loop
        XCTAssertEqual(collector.frames.withLock { $0.count }, 0)
        XCTAssertTrue(source.statistics.attached)
        XCTAssertEqual(producer.submit(1), LW_OK)
        collector.wait(1)
        XCTAssertEqual(collector.frames.withLock { $0.last?.sequence }, 1)
    }

    // MARK: Stopping from the frame callback

    final class SourceBox: @unchecked Sendable {
        var source: ExternalFrameSource?
        let callbacks = Atomic<Int>(0)
    }

    /// onFrame runs on the source's own thread; stopping there used to join
    /// that thread from itself (std::system_error across the C ABI).
    func testStopFromTheCallback() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let box = SourceBox()
        box.source = try ExternalFrameSource(device: device, channel: channel) { [box] _ in
            box.callbacks.add(1, ordering: .relaxed)
            box.source?.stop()
        }
        let producer = try Producer(channel: channel)
        XCTAssertEqual(producer.submit(1), LW_OK)
        waitUntil { box.callbacks.load(ordering: .relaxed) == 1 }
        // The host tears down after the callback: the producer's attach ends.
        waitUntil { producer.submit(2) == LW_E_ACCESS_LOST }
        Sleep(100)
        XCTAssertEqual(box.callbacks.load(ordering: .relaxed), 1, "no callback after stop")
        box.source = nil
    }

    /// The same, by dropping the last reference: deinit runs stop() on the
    /// callback thread.
    func testLastReferenceDroppedInTheCallback() throws {
        let channel = channelName()
        let device = try GraphicsDevice(for: nil)
        let box = SourceBox()
        box.source = try ExternalFrameSource(device: device, channel: channel) { [box] _ in
            box.callbacks.add(1, ordering: .relaxed)
            box.source = nil
        }
        let producer = try Producer(channel: channel)
        XCTAssertEqual(producer.submit(1), LW_OK)
        waitUntil { box.callbacks.load(ordering: .relaxed) == 1 }
        waitUntil { producer.submit(2) == LW_E_ACCESS_LOST }
        XCTAssertEqual(box.callbacks.load(ordering: .relaxed), 1)
        // The channel is free for a new host once the teardown has finished.
        producer.detach()
        Sleep(100)
        let again = try ExternalFrameSource(device: device, channel: channel) { _ in }
        again.stop()
    }

    func testInvalidChannelNames() throws {
        let device = try GraphicsDevice(for: nil)
        for name in ["", "has space", "back\\slash", String(repeating: "x", count: Int(LW_FS_MAX_CHANNEL) + 1)] {
            XCTAssertThrowsError(try ExternalFrameSource(device: device, channel: name) { _ in }, name)
        }
    }

    func waitUntil(seconds: Int64 = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = HostClock.now() + HostClock.ticksPerSecond * seconds
        while !condition() {
            if HostClock.now() > deadline { return XCTFail("timed out", file: file, line: line) }
            Sleep(5)
        }
    }
}
