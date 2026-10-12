import StreamWire
import XCTest

final class InputEventTests: XCTestCase {
    static let time = "0807060504030201" // hostTime 0x0102030405060708
    static let hostTime: UInt64 = 0x0102_0304_0506_0708

    /// Interop vectors: one per event type.
    static let vectors: [(InputEvent, [UInt8])] = [
        (.keyDown(KeyEvent(keyCode: 0x0024, modifiers: [.shift, .command])), hex("40 0e", time, "2400", "09000000")),
        (.keyUp(KeyEvent(keyCode: 0x0024)), hex("41 0e", time, "2400", "00000000")),
        (.mouseDown(MouseButtonEvent(streamID: 0, button: .left, x: 100, y: 200)), hex("42 11", time, "00000000 00 6400 c800")),
        (.mouseUp(MouseButtonEvent(streamID: 0x55, button: .forward, x: 1, y: 2)), hex("43 11", time, "55000000 04 0100 0200")),
        (.scroll(ScrollEvent(streamID: 1, x: 10, y: 20, lineDeltaX: 0, lineDeltaY: -1, preciseDeltaX: 0, preciseDeltaY: -120)),
         hex("44 1c", time, "01000000 0a00 1400 0000 ffff 00000000 88ffffff")),
        (.textInput("hé"), hex("45 0b", time, "68c3a9")),
        (.focusWindow(streamID: 0x2A), hex("46 0c", time, "2a000000")),
        (.gamepadConnected(GamepadInfo(index: 1, kind: .dualSense, features: [.motion, .touchpad, .adaptiveTriggers])),
         hex("47 0b", time, "01 02 23")),
        (.gamepadDisconnected(index: 1), hex("48 09", time, "01")),
        (.releaseAll, hex("49 08", time)),
    ]

    func testGoldenVectors() throws {
        for (event, bytes) in Self.vectors {
            let timed = TimedInputEvent(hostTime: Self.hostTime, event: event)
            XCTAssertEqual(hexString(try timed.encodedMessage()), hexString(bytes), "\(event)")
            let message = try XCTUnwrap(try MessageFraming.next(in: bytes[...])).message
            XCTAssertEqual(try TimedInputEvent(message: message), timed)
        }
    }

    func testOtherMessageTypesAreNotInputEvents() throws {
        XCTAssertNil(try TimedInputEvent(message: Message(type: .formatDescription, body: [])))
        XCTAssertNil(try TimedInputEvent(message: Message(type: MessageType(rawValue: 0x5F), body: [1])))
        XCTAssertNil(try HostInputEvent(message: Message(type: .keyDown, body: [])))
    }

    func testRejects() {
        func decode(_ type: MessageType, _ body: [UInt8]) throws(WireError) -> TimedInputEvent? {
            try TimedInputEvent(message: Message(type: type, body: body[...]))
        }
        let t = hex(Self.time)
        XCTAssertWireError(.invalid("input.text.utf8")) { try decode(.textInput, t + [0xC3]) }
        XCTAssertWireError(.invalid("input.text.utf8")) { try decode(.textInput, t + [0xED, 0xA0, 0x80]) } // surrogate
        XCTAssertWireError(.invalid("input.text")) { try decode(.textInput, t) }
        XCTAssertWireError(.tooLarge("input.text")) { try decode(.textInput, t + [UInt8](repeating: 0x61, count: 4097)) }
        XCTAssertWireError(.invalid("input.key.modifiers")) { try decode(.keyDown, t + hex("2400 40000000")) }
        XCTAssertWireError(.invalid("input.mouse.button")) { try decode(.mouseDown, t + hex("00000000 05 0000 0000")) }
        XCTAssertWireError(.invalid("input.gamepad.index")) { try decode(.gamepadDisconnected, t + [16]) }
        XCTAssertWireError(.invalid("input.gamepad.features")) { try decode(.gamepadConnected, t + [0, 1, 0x40]) }
        XCTAssertWireError(.trailingBytes(1)) { try decode(.releaseAll, t + [0]) }
        XCTAssertWireError(.truncated) { try decode(.releaseAll, [1, 2, 3]) }
        XCTAssertWireError(.truncated) { try decode(.scroll, t + hex("01000000 0a00")) }
    }

    func testHostEventGoldenVectors() throws {
        let vectors: [(HostInputEvent, [UInt8])] = [
            (.rumble(Rumble(gamepad: 0, lowFrequency: 0xFFFF, highFrequency: 0x8000, durationMs: 100)),
             hex("60 0b 00 ffff 0080 0000 0000 6400")),
            (.lightBar(gamepad: 2, red: 255, green: 0, blue: 128), hex("61 04 02 ff 00 80")),
            (.triggerEffect(gamepad: 0, side: .right, effect: [0x21, 0x01]), hex("62 04 00 01 2101")),
            (.cursor(visible: true, shape: .iBeam), hex("63 02 01 01")),
            (.controlStatus(.keyboard, .accessibilityDenied), hex("64 02 01 02")),
        ]
        for (event, bytes) in vectors {
            XCTAssertEqual(try event.encodedMessage(), bytes, "\(event)")
            let message = try XCTUnwrap(try MessageFraming.next(in: bytes[...])).message
            XCTAssertEqual(try HostInputEvent(message: message), event)
        }
        XCTAssertWireError(.tooLarge("hostInput.triggerEffect")) {
            try HostInputEvent(message: Message(type: .triggerEffect, body: [0, 0] + [UInt8](repeating: 1, count: 33)))
        }
        XCTAssertWireError(.invalid("hostInput.cursor.visible")) { try HostInputEvent(message: Message(type: .cursor, body: [2, 0])) }
        XCTAssertWireError(.invalid("hostInput.status")) { try HostInputEvent(message: Message(type: .controlStatus, body: [0, 3])) }
    }
}

final class StateSnapshotTests: XCTestCase {
    func testGoldenPointerSnapshots() throws {
        let absolute = StateSnapshot(sequence: 9, hostTime: 1000, payload: .pointerAbsolute(PointerPosition(streamID: 0, x: 640, y: 360)))
        XCTAssertEqual(try absolute.encoded(), hex("01 00 09000000 e803000000000000", "00000000 8002 6801"))
        let relative = StateSnapshot(sequence: 10, hostTime: 1000, payload: .pointerRelative(RelativePointer(totalX: -256, totalY: 512)))
        XCTAssertEqual(try relative.encoded(), hex("02 00 0a000000 e803000000000000", "00ffffff 00020000"))
        for snapshot in [absolute, relative] {
            XCTAssertEqual(try StateSnapshot(frameBody: try snapshot.encoded()), snapshot)
        }
    }

    func testGoldenHeadPose() throws {
        let snapshot = StateSnapshot(sequence: 0x1234, hostTime: 999_000, payload: .headPose(Fixtures.headPose))
        let expected = hex(
            "04 00",                 // kind headPose, source 0
            "34120000",              // sequence
            "583e0f0000000000",      // hostTime 999000
            "40420f0000000000",      // displayTime 1000000
            "0100",                  // spaceEpoch
            "0300",                  // flags: gaze valid | presented valid
            SideDataTests.identity, "00000000 0000c03f 00000000", // head at (0, 1.5, 0)
            SideDataTests.leftEye,
            SideDataTests.rightEye,
            "29000000",              // presented frame 41
            "a0bb0d0000000000",      // present time 900000
            "00000000 00000000 000080bf", // gaze direction (0, 0, -1)
            "0000003f",              // gaze distance 0.5
            "301b0f0000000000")      // gaze sample time 990000
        XCTAssertEqual(expected.count, StateSnapshot.headerSize + HeadPose.wireSize)
        XCTAssertEqual(hexString(try snapshot.encoded()), hexString(expected))
        XCTAssertEqual(try StateSnapshot(frameBody: expected), snapshot)
    }

    func testHeadPoseWithoutGazeIsZeroFilled() throws {
        var pose = Fixtures.headPose
        pose.gaze = nil
        pose.presented = nil
        let bytes = try StateSnapshot(sequence: 1, hostTime: 0, payload: .headPose(pose)).encoded()
        XCTAssertEqual(Array(bytes[24...25]), [0, 0]) // flags
        XCTAssertTrue(bytes[142...].allSatisfy { $0 == 0 })
        XCTAssertEqual(try StateSnapshot(frameBody: bytes)?.payload, .headPose(pose))

        var stale = bytes
        stale[stale.count - 1] = 1 // a gaze timestamp while gaze is invalid
        XCTAssertWireError(.inconsistent("headPose.gaze")) { try StateSnapshot(frameBody: stale) }
        stale = bytes
        stale[142] = 1 // a presented frame number without the flag
        XCTAssertWireError(.inconsistent("headPose.presented")) { try StateSnapshot(frameBody: stale) }
        stale = bytes
        stale[24] = 0x04 // reserved flag
        XCTAssertWireError(.invalid("headPose.flags")) { try StateSnapshot(frameBody: stale) }
    }

    func testHeadPoseValidation() {
        var pose = Fixtures.headPose
        pose.gaze?.direction = Vector3(0, 0, -2)
        XCTAssertWireError(.invalid("headPose.gaze.direction")) {
            try StateSnapshot(sequence: 1, hostTime: 0, payload: .headPose(pose)).encoded()
        }
        pose = Fixtures.headPose
        pose.leftEye.fieldOfView.angleLeft = 0.9 // left of the view must be less than right
        XCTAssertWireError(.invalid("headPose.leftEye.fieldOfView")) {
            try StateSnapshot(sequence: 1, hostTime: 0, payload: .headPose(pose)).encoded()
        }
        pose = Fixtures.headPose
        pose.head.position.y = .infinity
        XCTAssertWireError(.invalid("headPose.head")) {
            try StateSnapshot(sequence: 1, hostTime: 0, payload: .headPose(pose)).encoded()
        }
        XCTAssertWireError(.invalid("state.source")) {
            try StateSnapshot(source: 1, sequence: 1, hostTime: 0, payload: .headPose(Fixtures.headPose)).encoded()
        }
    }

    func testGoldenGamepad() throws {
        let snapshot = StateSnapshot(source: 2, sequence: 5, hostTime: 0, payload: .gamepad(Fixtures.gamepad))
        let expected = hex(
            "03 02 05000000 0000000000000000",
            "01080000",                  // south | dpadUp
            "6400 9cff 0000 ff7f",       // sticks
            "0000 ffff",                 // triggers
            "03",                        // motion + touchpad
            "0000803e 00000000 00000000",// gyro (0.25, 0, 0)
            "00000000 000080bf 00000000",// accel (0, -1, 0)
            "01 01 0080 0040",           // contact 1
            "00 00 0000 0000")           // second slot empty
        XCTAssertEqual(try snapshot.encoded(), expected)
        XCTAssertEqual(try StateSnapshot(frameBody: expected), snapshot)

        let plain = StateSnapshot(source: 0, sequence: 1, hostTime: 0, payload: .gamepad(GamepadState()))
        XCTAssertEqual(try plain.encoded().count, StateSnapshot.headerSize + 17)
        XCTAssertEqual(try StateSnapshot(frameBody: try plain.encoded()), plain)

        var bad = expected
        bad[bad.count - 6] = 0x02 // contact flags reserved bit
        XCTAssertWireError(.invalid("gamepad.touchpad.flags")) { try StateSnapshot(frameBody: bad) }
        bad = expected
        bad[bad.count - 12] = 0x00 // first slot inactive but second... first has data: inactive must be zero
        XCTAssertWireError(.invalid("gamepad.touchpad.inactive")) { try StateSnapshot(frameBody: bad) }
        bad = expected
        bad[14 + 16] = 0x07 // reserved section bit
        XCTAssertWireError(.invalid("gamepad.sections")) { try StateSnapshot(frameBody: bad) }
        XCTAssertWireError(.invalid("state.source")) {
            try StateSnapshot(source: 16, sequence: 1, hostTime: 0, payload: .gamepad(GamepadState())).encoded()
        }
    }

    func testUnknownKindsAreSkippedAndBodiesAreExact() throws {
        XCTAssertNil(try StateSnapshot(frameBody: hex("7f 00 01000000 0000000000000000 aabb")))
        let good = try StateSnapshot(sequence: 1, hostTime: 0, payload: .pointerRelative(RelativePointer(totalX: 0, totalY: 0))).encoded()
        XCTAssertWireError(.trailingBytes(1)) { try StateSnapshot(frameBody: good + [0]) }
        XCTAssertWireError(.truncated) { try StateSnapshot(frameBody: Array(good.dropLast())) }
    }

    func testLatestWinsWithWraparound() {
        let old = StateSnapshot(sequence: UInt32.max, hostTime: 0, payload: .pointerRelative(RelativePointer(totalX: Int32.max, totalY: 0)))
        let new = StateSnapshot(sequence: 1, hostTime: 0, payload: .pointerRelative(RelativePointer(totalX: Int32.min &+ 9, totalY: 0)))
        XCTAssertTrue(new.supersedes(old))
        XCTAssertFalse(old.supersedes(new))
        XCTAssertFalse(new.supersedes(new))
        // Motion across the wrap of the running total is still the true delta.
        guard case .pointerRelative(let a) = old.payload, case .pointerRelative(let b) = new.payload else { return XCTFail() }
        XCTAssertEqual(b.delta(since: a).x, 10)

        let pad0 = StateSnapshot(source: 0, sequence: 5, hostTime: 0, payload: .gamepad(GamepadState()))
        let pad1 = StateSnapshot(source: 1, sequence: 6, hostTime: 0, payload: .gamepad(GamepadState()))
        XCTAssertFalse(pad1.supersedes(pad0)) // different series
    }
}

final class CapabilityTests: XCTestCase {
    func testGoldenEncoding() throws {
        let set = CapabilitySet([.windowStreams, .nack, .sideData, .depthVideo, .pcvr, .gaze])
        // bits 0, 8, 18, 19, 20, 21 -> bytes 01 01 3c
        XCTAssertEqual(try set.encoded(), hex("03 01 01 3c"))
        XCTAssertEqual(try CapabilitySet(decoding: hex("03 01 01 3c")), set)
        XCTAssertEqual(try CapabilitySet().encoded(), hex("00"))
        XCTAssertEqual(try CapabilitySet.known.encoded(), hex("03 ff ff 3f"))
        XCTAssertEqual(Array(set), [.windowStreams, .nack, .sideData, .depthVideo, .pcvr, .gaze])
    }

    func testUnknownCapabilitiesAreIgnored() throws {
        // Trailing zero bytes and bits this build doesn't know decode fine...
        let peer = try CapabilitySet(decoding: hex("20 01 00 00 80", String(repeating: "00", count: 27), "80"))
        XCTAssertTrue(peer.contains(Capability(rawValue: 255)))
        XCTAssertTrue(peer.contains(Capability(rawValue: 31)))
        // ...and drop out of negotiation.
        XCTAssertEqual(CapabilitySet.negotiated(peer, CapabilitySet((0...255).map { Capability(rawValue: UInt8($0)) })),
                       CapabilitySet([.windowStreams]))
        XCTAssertWireError(.tooLarge("capabilities")) { try CapabilitySet(decoding: [33] + [UInt8](repeating: 0, count: 33)) }
        XCTAssertEqual(Capability(rawValue: 200).description, "capability(200)")
        XCTAssertEqual(Capability.depthVideo.description, "depthVideo")
    }

    func testNegotiationDropsCapabilitiesMissingRequirements() {
        let client = CapabilitySet([.pcvr, .gaze, .depthVideo, .sideData, .nack])
        XCTAssertEqual(CapabilitySet.negotiated(client, CapabilitySet([.pcvr, .gaze, .depthVideo, .nack])),
                       CapabilitySet([.nack])) // host lacks sideData: pcvr, gaze, depthVideo all fall
        XCTAssertEqual(CapabilitySet.negotiated(client, CapabilitySet([.gaze, .sideData, .depthVideo])),
                       CapabilitySet([.sideData, .depthVideo])) // gaze needs pcvr
        XCTAssertEqual(CapabilitySet.negotiated(client, client), client)
    }
}
