// The external frame source's shared-memory protocol (CFrameSourceCore,
// NATIVE_V3_PROTOCOL.md 7.2), tested on one in-memory section. The core never
// touches an OS or GPU object, so these run on every platform; the Windows
// layer around it is tested on Windows (StreamHostWindowsTests).
import CFrameSourceCore
import Dispatch
import XCTest

/// One section in ordinary memory, shared by the "producer" and "host" sides
/// of a test exactly as two processes share the mapped section.
final class Section: @unchecked Sendable {
    let raw: UnsafeMutablePointer<lw_fs_shared>

    init(slots: UInt32 = UInt32(LW_FS_DEFAULT_SLOTS)) {
        raw = .allocate(capacity: 1)
        lw_fs_init(raw)
        raw.pointee.format = Section.format(slots: slots)
    }

    deinit { raw.deallocate() }

    static func format(slots: UInt32 = UInt32(LW_FS_DEFAULT_SLOTS)) -> lw_fs_format {
        var format = lw_fs_format()
        format.layout = UInt32(LW_FS_LAYOUT_MONO)
        format.slot_count = slots
        format.image_format = UInt32(LW_FS_FORMAT_B8G8R8A8_UNORM)
        format.image_width = 2560
        format.image_height = 1440
        return format
    }

    /// Runs the whole handshake and returns the generation.
    @discardableResult
    func attach(generation: UInt64 = 1) -> UInt64 {
        lw_fs_host_open(raw, 100)
        XCTAssertEqual(lw_fs_producer_begin_request(raw), 1)
        lw_fs_producer_commit_request(raw)
        XCTAssertEqual(lw_fs_host_begin_attach(raw), 1)
        lw_fs_host_finish_attach(raw, generation)
        return generation
    }

    func slotState(_ index: Int) -> UInt32 {
        withUnsafeBytes(of: &raw.pointee.slots) { slots in
            let word = slots.load(fromByteOffset: index * MemoryLayout<lw_fs_slot>.stride, as: UInt64.self)
            return UInt32(truncatingIfNeeded: word & 0xFF)
        }
    }

    func frameNumber(_ index: Int) -> UInt64 {
        withUnsafeBytes(of: &raw.pointee.slots) { slots in
            slots.load(fromByteOffset: index * MemoryLayout<lw_fs_slot>.stride
                + MemoryLayout<lw_fs_slot>.offset(of: \.frame_number)!, as: UInt64.self)
        }
    }

    func sideData(_ index: Int) -> [UInt8] {
        withUnsafeBytes(of: &raw.pointee.slots) { slots in
            let base = index * MemoryLayout<lw_fs_slot>.stride
            let size = Int(slots.load(fromByteOffset: base + MemoryLayout<lw_fs_slot>.offset(of: \.side_data_size)!,
                                      as: UInt32.self))
            let start = base + MemoryLayout<lw_fs_slot>.offset(of: \.side_data)!
            return Array(slots[start ..< start + size])
        }
    }

    /// Producer: acquire, then publish `frame` with its number as side data.
    func produce(_ frame: UInt64, generation: UInt64 = 1) -> Int32 {
        var slot: UInt32 = 0
        let result = lw_fs_producer_acquire(raw, generation, &slot)
        guard result == LW_FS_ACQUIRED || result == LW_FS_ACQUIRED_SUPERSEDED else { return result }
        var bytes = frame
        let published = withUnsafeBytes(of: &bytes) {
            lw_fs_producer_publish(raw, generation, slot, frame, frame, Int64(frame), $0.baseAddress, UInt32($0.count))
        }
        XCTAssertEqual(published, 1)
        return result
    }
}

final class FrameSourceLayoutTests: XCTestCase {
    /// The section is a cross-process, cross-build contract: these numbers
    /// may only change together with LW_FS_VERSION.
    func testLayoutMatchesTheContract() {
        XCTAssertEqual(MemoryLayout<lw_fs_format>.size, 48)
        XCTAssertEqual(MemoryLayout<lw_fs_host_state>.size, 256)
        XCTAssertEqual(MemoryLayout<lw_fs_slot>.size, 48 + Int(LW_FS_MAX_SIDE_DATA))
        XCTAssertEqual(MemoryLayout<lw_fs_shared>.size, 704 + Int(LW_FS_MAX_SLOTS) * (48 + Int(LW_FS_MAX_SIDE_DATA)))
        XCTAssertEqual(MemoryLayout<lw_fs_shared>.offset(of: \.attach), 32)
        XCTAssertEqual(MemoryLayout<lw_fs_shared>.offset(of: \.format), 80)
        XCTAssertEqual(MemoryLayout<lw_fs_shared>.offset(of: \.texture_handles), 144)
        XCTAssertEqual(MemoryLayout<lw_fs_shared>.offset(of: \.host_state_data), 392)
        XCTAssertEqual(MemoryLayout<lw_fs_shared>.offset(of: \.slots), 704)
        XCTAssertEqual(MemoryLayout<lw_fs_host_state>.offset(of: \.next_frame_start_qpc), 176)
    }

    func testFreshSectionHasThisBuildsIdentity() {
        let section = Section()
        XCTAssertEqual(lw_fs_check_identity(section.raw), UInt32(LW_FS_REFUSE_NONE))
        section.raw.pointee.version = LW_FS_VERSION + 1
        XCTAssertEqual(lw_fs_check_identity(section.raw), UInt32(LW_FS_REFUSE_VERSION))
    }

    func testFormatValidation() {
        var format = Section.format()
        XCTAssertEqual(lw_fs_validate_format(&format), UInt32(LW_FS_REFUSE_NONE))

        func refused(_ change: (inout lw_fs_format) -> Void, file: StaticString = #filePath, line: UInt = #line) {
            var bad = Section.format()
            change(&bad)
            XCTAssertEqual(lw_fs_validate_format(&bad), UInt32(LW_FS_REFUSE_FORMAT), file: file, line: line)
        }
        refused { $0.image_width = 2561 }
        refused { $0.image_height = 0 }
        refused { $0.image_width = UInt32(LW_FS_MAX_DIMENSION) + 2 }
        refused { $0.slot_count = UInt32(LW_FS_MIN_SLOTS) - 1 }
        refused { $0.slot_count = UInt32(LW_FS_MAX_SLOTS) + 1 }
        refused { $0.layout = 0 }
        refused { $0.image_format = UInt32(LW_FS_FORMAT_R32_FLOAT) } // an aux-only format
        refused { $0.layout = UInt32(LW_FS_LAYOUT_STEREO_SIDE_BY_SIDE); $0.image_width = 2562 } // odd eye width
        refused { $0.aux_width = 640 } // aux size without a role
        refused { $0.aux_role = UInt32(LW_FS_AUX_DEPTH) } // a role without format or size
        refused { $0.reserved.0 = 1 }

        var depth = Section.format()
        depth.aux_role = UInt32(LW_FS_AUX_DEPTH)
        depth.aux_format = UInt32(LW_FS_FORMAT_R32_FLOAT)
        depth.aux_width = 1280
        depth.aux_height = 720
        XCTAssertEqual(lw_fs_validate_format(&depth), UInt32(LW_FS_REFUSE_NONE))
    }
}

final class FrameSourceHandshakeTests: XCTestCase {
    func testAttachThenDetach() {
        let section = Section()
        XCTAssertEqual(lw_fs_host_listening(section.raw), 0)
        XCTAssertEqual(lw_fs_host_open(section.raw, 100), 1)
        XCTAssertEqual(lw_fs_host_listening(section.raw), 1)

        XCTAssertEqual(lw_fs_producer_begin_request(section.raw), 1)
        XCTAssertEqual(lw_fs_producer_begin_request(section.raw), 0, "one producer per channel")
        XCTAssertEqual(lw_fs_host_begin_attach(section.raw), 0, "the request isn't complete yet")
        lw_fs_producer_commit_request(section.raw)
        XCTAssertEqual(lw_fs_attach_state(section.raw), UInt32(LW_FS_ATTACH_REQUESTED))
        XCTAssertEqual(lw_fs_host_begin_attach(section.raw), 1)
        XCTAssertEqual(lw_fs_producer_cancel_request(section.raw), 0, "too late: the host is building")
        lw_fs_host_finish_attach(section.raw, 7)
        XCTAssertEqual(lw_fs_is_attached(section.raw, 7), 1)
        XCTAssertEqual(lw_fs_is_attached(section.raw, 6), 0)

        XCTAssertEqual(lw_fs_detach(section.raw, 6), 0, "an older attach can't end this one")
        XCTAssertEqual(lw_fs_detach(section.raw, 7), 1)
        XCTAssertEqual(lw_fs_detach(section.raw, 7), 0)
        XCTAssertEqual(lw_fs_attach_state(section.raw), UInt32(LW_FS_ATTACH_FREE))
    }

    func testRefusalIsAcknowledged() {
        let section = Section()
        lw_fs_host_open(section.raw, 100)
        XCTAssertEqual(lw_fs_producer_begin_request(section.raw), 1)
        lw_fs_producer_commit_request(section.raw)
        XCTAssertEqual(lw_fs_host_begin_attach(section.raw), 1)
        lw_fs_host_refuse(section.raw, UInt32(LW_FS_REFUSE_ADAPTER))
        XCTAssertEqual(section.raw.pointee.refuse_reason, UInt32(LW_FS_REFUSE_ADAPTER))
        XCTAssertEqual(lw_fs_producer_begin_request(section.raw), 0, "busy until the refusal is read")
        XCTAssertEqual(lw_fs_producer_acknowledge_refusal(section.raw), 1)
        XCTAssertEqual(lw_fs_producer_begin_request(section.raw), 1)
    }

    func testCancelWhenNoHostAnswers() {
        let section = Section()
        XCTAssertEqual(lw_fs_producer_begin_request(section.raw), 1)
        lw_fs_producer_commit_request(section.raw)
        XCTAssertEqual(lw_fs_producer_cancel_request(section.raw), 1)
        XCTAssertEqual(lw_fs_attach_state(section.raw), UInt32(LW_FS_ATTACH_FREE))
    }

    /// A restarted host inherits the section a producer kept open: the old
    /// attach ends (the producer sees its generation go stale), a waiting
    /// request survives.
    func testHostRestart() {
        let section = Section()
        let generation = section.attach()
        XCTAssertEqual(lw_fs_host_open(section.raw, 200), 2)
        XCTAssertEqual(lw_fs_is_attached(section.raw, generation), 0)
        XCTAssertEqual(lw_fs_attach_state(section.raw), UInt32(LW_FS_ATTACH_FREE))
        var slot: UInt32 = 0
        XCTAssertEqual(lw_fs_producer_acquire(section.raw, generation, &slot), LW_FS_STALE)

        XCTAssertEqual(lw_fs_producer_begin_request(section.raw), 1)
        lw_fs_producer_commit_request(section.raw)
        XCTAssertEqual(lw_fs_host_open(section.raw, 300), 3)
        XCTAssertEqual(lw_fs_attach_state(section.raw), UInt32(LW_FS_ATTACH_REQUESTED))
    }

    func testHostCloseEndsTheAttach() {
        let section = Section()
        let generation = section.attach()
        lw_fs_host_close(section.raw)
        XCTAssertEqual(lw_fs_host_listening(section.raw), 0)
        XCTAssertEqual(lw_fs_is_attached(section.raw, generation), 0)
        XCTAssertEqual(lw_fs_attach_state(section.raw), UInt32(LW_FS_ATTACH_FREE))
    }
}

final class FrameSourceRingTests: XCTestCase {
    func testProducerFillsFreeSlotsThenReclaimsTheOldestReadyFrame() {
        let section = Section(slots: 3)
        section.attach()
        XCTAssertEqual(section.produce(1), LW_FS_ACQUIRED)
        XCTAssertEqual(section.produce(2), LW_FS_ACQUIRED)
        XCTAssertEqual(section.produce(3), LW_FS_ACQUIRED)
        // Nobody consumed: frame 1 is the oldest and gives way to frame 4.
        XCTAssertEqual(section.produce(4), LW_FS_ACQUIRED_SUPERSEDED)
        XCTAssertEqual(section.raw.pointee.superseded, 1)
        XCTAssertEqual((0 ..< 3).map(section.frameNumber).sorted(), [2, 3, 4])
    }

    func testHostTakesTheNewestAndDropsOlderFrames() {
        let section = Section(slots: 4)
        let generation = section.attach()
        for frame in UInt64(1) ... 3 { XCTAssertEqual(section.produce(frame), LW_FS_ACQUIRED) }
        var slot: UInt32 = 0
        XCTAssertEqual(lw_fs_host_take_newest(section.raw, generation, &slot), 1)
        XCTAssertEqual(section.frameNumber(Int(slot)), 3)
        XCTAssertEqual(section.sideData(Int(slot)), withUnsafeBytes(of: UInt64(3)) { Array($0) })
        XCTAssertEqual(section.slotState(Int(slot)), UInt32(LW_FS_SLOT_CONSUMING))
        XCTAssertEqual(section.raw.pointee.dropped, 2)
        XCTAssertEqual(section.raw.pointee.consumed, 1)
        var other: UInt32 = 0
        XCTAssertEqual(lw_fs_host_take_newest(section.raw, generation, &other), 0, "nothing else is ready")
        XCTAssertEqual(lw_fs_host_release(section.raw, generation, slot), 1)
        XCTAssertEqual(lw_fs_host_release(section.raw, generation, slot), 0, "released once")
        XCTAssertEqual((0 ..< 4).map(section.slotState), Array(repeating: UInt32(LW_FS_SLOT_FREE), count: 4))
    }

    /// The host's scan of the ring isn't a snapshot, so a frame can turn up
    /// ready after a newer one was taken. It must be dropped, not delivered
    /// out of order (found by testConcurrentProducerAndHost).
    func testAFrameOlderThanTheLastTakenIsDropped() {
        let section = Section(slots: 3)
        let generation = section.attach()
        XCTAssertEqual(section.produce(1), LW_FS_ACQUIRED)
        var slot: UInt32 = 0
        XCTAssertEqual(lw_fs_host_take_newest(section.raw, generation, &slot), 1)
        XCTAssertEqual(lw_fs_host_release(section.raw, generation, slot), 1)
        section.raw.pointee.taken_sequence = 5 // as if a frame submitted later had been taken
        XCTAssertEqual(section.produce(2), LW_FS_ACQUIRED) // gets sequence 2
        XCTAssertEqual(lw_fs_host_take_newest(section.raw, generation, &slot), 0)
        XCTAssertEqual(section.raw.pointee.dropped, 1)
        XCTAssertEqual((0 ..< 3).map(section.slotState), Array(repeating: UInt32(LW_FS_SLOT_FREE), count: 3))
    }

    /// The consumer stalls holding frames: the producer runs out of slots,
    /// counts it, and carries on as soon as one comes back.
    func testStarvationAndRecovery() {
        let section = Section(slots: 2)
        let generation = section.attach()
        var held: [UInt32] = []
        for frame in UInt64(1) ... 2 {
            XCTAssertEqual(section.produce(frame), LW_FS_ACQUIRED)
            var slot: UInt32 = 0
            XCTAssertEqual(lw_fs_host_take_newest(section.raw, generation, &slot), 1)
            held.append(slot)
        }
        XCTAssertEqual(section.produce(3), LW_FS_NO_SLOT)
        XCTAssertEqual(section.produce(4), LW_FS_NO_SLOT)
        XCTAssertEqual(section.raw.pointee.starved, 2)
        XCTAssertEqual(lw_fs_host_release(section.raw, generation, held[0]), 1)
        XCTAssertEqual(section.produce(5), LW_FS_ACQUIRED)
    }

    func testDiscardReturnsTheSlot() {
        let section = Section(slots: 2)
        let generation = section.attach()
        var slot: UInt32 = 0
        XCTAssertEqual(lw_fs_producer_acquire(section.raw, generation, &slot), LW_FS_ACQUIRED)
        XCTAssertEqual(lw_fs_producer_discard(section.raw, generation, slot), 1)
        XCTAssertEqual(section.slotState(Int(slot)), UInt32(LW_FS_SLOT_FREE))
        XCTAssertEqual(lw_fs_producer_discard(section.raw, generation, slot), 0)
    }

    func testPublishRejectsBadArguments() {
        let section = Section(slots: 2)
        let generation = section.attach()
        var slot: UInt32 = 0
        XCTAssertEqual(lw_fs_producer_acquire(section.raw, generation, &slot), LW_FS_ACQUIRED)
        let big = [UInt8](repeating: 0, count: Int(LW_FS_MAX_SIDE_DATA) + 1)
        XCTAssertEqual(lw_fs_producer_publish(section.raw, generation, slot, 1, 1, 0, big, UInt32(big.count)), 0)
        XCTAssertEqual(lw_fs_producer_publish(section.raw, generation, 5, 1, 1, 0, nil, 0), 0, "slot out of range")
        XCTAssertEqual(lw_fs_producer_publish(section.raw, generation + 1, slot, 1, 1, 0, nil, 0), 0, "stale")
        XCTAssertEqual(lw_fs_producer_publish(section.raw, generation, slot, 1, 1, 0, nil, 0), 1)
    }

    /// A frame the host still holds when the producer re-attaches belongs to
    /// the old generation: releasing it must not free a slot of the new ring.
    func testStaleReleaseLeavesTheNewRingAlone() {
        let section = Section(slots: 2)
        let first = section.attach(generation: 1)
        XCTAssertEqual(section.produce(1, generation: first), LW_FS_ACQUIRED)
        var held: UInt32 = 0
        XCTAssertEqual(lw_fs_host_take_newest(section.raw, first, &held), 1)
        XCTAssertEqual(lw_fs_detach(section.raw, first), 1)

        let second = section.attach(generation: 2)
        XCTAssertEqual(section.produce(1, generation: second), LW_FS_ACQUIRED)
        var slot: UInt32 = 0
        XCTAssertEqual(lw_fs_host_take_newest(section.raw, second, &slot), 1)
        XCTAssertEqual(lw_fs_host_release(section.raw, first, held), 0)
        XCTAssertEqual(section.slotState(Int(slot)), UInt32(LW_FS_SLOT_CONSUMING))
        XCTAssertEqual(lw_fs_host_take_newest(section.raw, first, &slot), 0, "the old generation takes nothing")
    }

    /// Producer and host race on the ring from two threads, as two processes
    /// would. Every frame the host takes must be newer than the last, and its
    /// metadata must be the producer's for that frame (it would be torn if the
    /// producer could write a slot the host holds).
    func testConcurrentProducerAndHost() {
        let section = Section(slots: 3)
        let generation = section.attach()
        let frames: UInt64 = 200_000
        let producerDone = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var taken = 0
        nonisolated(unsafe) var failures: [String] = []

        DispatchQueue.global().async {
            var frame: UInt64 = 1
            while frame <= frames {
                var slot: UInt32 = 0
                let result = lw_fs_producer_acquire(section.raw, generation, &slot)
                guard result == LW_FS_ACQUIRED || result == LW_FS_ACQUIRED_SUPERSEDED else { continue }
                var side = (frame, ~frame)
                _ = withUnsafeBytes(of: &side) {
                    lw_fs_producer_publish(section.raw, generation, slot, frame, frame, 0, $0.baseAddress, UInt32($0.count))
                }
                frame += 1
            }
            producerDone.signal()
        }

        var last: UInt64 = 0
        var finished = false
        while true {
            var slot: UInt32 = 0
            if lw_fs_host_take_newest(section.raw, generation, &slot) == 1 {
                let frame = section.frameNumber(Int(slot))
                let side = section.sideData(Int(slot))
                let expected = withUnsafeBytes(of: (frame, ~frame)) { Array($0) }
                if frame <= last { failures.append("frame \(frame) after \(last)") }
                if side != expected { failures.append("torn side data for frame \(frame)") }
                last = frame
                taken += 1
                XCTAssertEqual(lw_fs_host_release(section.raw, generation, slot), 1)
                if last == frames { break }
            } else if finished {
                break
            } else if producerDone.wait(timeout: .now()) == .success {
                finished = true // one more pass picks up the final frame
            }
        }
        XCTAssertEqual(failures.prefix(5), [])
        XCTAssertEqual(last, frames, "the newest frame always reaches the host")
        XCTAssertGreaterThan(taken, 0)
        let shared = section.raw.pointee
        XCTAssertEqual(shared.submitted, frames)
        XCTAssertEqual(shared.consumed, UInt64(taken))
        // Every submitted frame was taken, dropped by the host or reclaimed by the producer.
        XCTAssertEqual(shared.consumed + shared.dropped + shared.superseded, frames)
    }
}

final class FrameSourceSeqlockTests: XCTestCase {
    /// Every field of a state written for `k` is derived from `k`, so a torn
    /// read (half one write, half another) is detectable.
    static func state(_ k: UInt64) -> lw_fs_host_state {
        var state = lw_fs_host_state()
        state.pose_sequence = k
        state.pose_display_qpc = Int64(bitPattern: k &* 3)
        state.pose_valid = 1
        state.space_epoch = UInt32(truncatingIfNeeded: k)
        state.head.position = (Float(k % 1000), Float(k % 1000), Float(k % 1000))
        state.gaze_direction = (Float(k % 999), 0, 1)
        state.refresh_millihz = UInt32(truncatingIfNeeded: k &* 7)
        state.next_frame_start_qpc = Int64(bitPattern: k &* 5)
        state.written_qpc = Int64(bitPattern: k)
        return state
    }

    static func isConsistent(_ s: lw_fs_host_state) -> Bool {
        let k = s.pose_sequence
        return s.pose_display_qpc == Int64(bitPattern: k &* 3) && s.space_epoch == UInt32(truncatingIfNeeded: k)
            && s.head.position.2 == Float(k % 1000) && s.gaze_direction.0 == Float(k % 999)
            && s.refresh_millihz == UInt32(truncatingIfNeeded: k &* 7) && s.next_frame_start_qpc == Int64(bitPattern: k &* 5)
            && s.written_qpc == Int64(bitPattern: k)
    }

    func testReadBeforeAnyWriteIsAZeroState() {
        let section = Section()
        var out = Self.state(9)
        XCTAssertEqual(lw_fs_read_host_state(section.raw, &out, 4), 1)
        XCTAssertEqual(out.pose_valid, 0)
        XCTAssertEqual(out.pose_sequence, 0)
    }

    func testRoundTrip() {
        let section = Section()
        var state = Self.state(42)
        lw_fs_host_write_state(section.raw, &state)
        var out = lw_fs_host_state()
        XCTAssertEqual(lw_fs_read_host_state(section.raw, &out, 4), 1)
        XCTAssertTrue(Self.isConsistent(out))
        XCTAssertEqual(out.pose_sequence, 42)
        XCTAssertEqual(section.raw.pointee.host_state_sequence, 2)
    }

    func testReaderGivesUpWhileAWriteIsInProgress() {
        let section = Section()
        section.raw.pointee.host_state_sequence = 1 // a writer stopped half-way
        var out = lw_fs_host_state()
        XCTAssertEqual(lw_fs_read_host_state(section.raw, &out, 16), 0)
    }

    func testConcurrentReadersNeverSeeATornState() {
        let section = Section()
        let writes: UInt64 = 300_000
        let stop = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for k in 1 ... writes {
                var state = Self.state(k)
                lw_fs_host_write_state(section.raw, &state)
            }
            stop.signal()
        }
        // The writer never pauses (a real host writes at the display rate), so
        // many reads are contended and retried; none may come back torn.
        var reads = 0, torn = 0, contended = 0
        var last: UInt64 = 0, backwards = 0
        while stop.wait(timeout: .now()) == .timedOut {
            var out = lw_fs_host_state()
            guard lw_fs_read_host_state(section.raw, &out, 64) == 1 else {
                contended += 1
                continue
            }
            reads += 1
            if !Self.isConsistent(out) { torn += 1 }
            if out.pose_sequence < last { backwards += 1 }
            last = out.pose_sequence
        }
        XCTAssertGreaterThan(reads, 100, "\(contended) contended")
        XCTAssertEqual(torn, 0)
        XCTAssertEqual(backwards, 0)
    }
}
