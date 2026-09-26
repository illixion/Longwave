import XCTest
import simd
import RAVEInput
@testable import Longwave

/// The 0x10 tracked-controllers packet and the glue that fills it. The byte layout is
/// pinned against the SAME golden vector the host's bridge_tests decodes
/// (OpenXRLayer/src/bridge_tests.cpp, `kTrackedControllersGolden`), so a drift on either
/// side of the wire fails a test on that side rather than a session. The rest is the
/// headset's own decisions — which device holds a side, where a haptic pulse goes, what
/// the HUD says — all pure.
///
/// Gated with the feature, like everything else on the PCVR path.
#if FOVEATED_ENABLED

final class ControllerBridgeTrackedControllersEncodingTests: XCTestCase {

    /// Left: a tracked, in-hand Sense with angular velocity and touch. Right: an untracked,
    /// in-hand Quest Touch with an unknown battery. Identical to the C side's vector.
    static let golden =
        "10032a000000000008070605040302010000803e0000c03f000000bf00000000"
        + "00000000000000000000803f0000003f000080bf000000400000403f0000003f"
        + "000080be0000803f210000001f025000000000be0000a03f0000c0be00000000"
        + "f304353f00000000f304353f0000000000000000000000000000803f00000000"
        + "00000000000000000a0000000501ff00"

    static func goldenPacket() -> ControllerBridgeTrackedControllers {
        var packet = ControllerBridgeTrackedControllers()
        packet.sequence = 0x2A
        packet.timestampNs = 0x0102_0304_0506_0708
        packet.left = ControllerBridgeTrackedController(
            position: SIMD3(0.25, 1.5, -0.5),
            orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            angularVelocity: SIMD3(0.5, -1, 2),
            trigger: 0.75, grip: 0.5, stick: SIMD2(-0.25, 1),
            buttons: RAVEControllerButtons([.primary, .triggerTouch]).rawValue,
            flags: [.present, .tracked, .inHand, .touchValid, .angularVelocity],
            source: .sense, battery: 80)
        packet.right = ControllerBridgeTrackedController(
            position: SIMD3(-0.125, 1.25, -0.375),
            orientation: simd_quatf(ix: 0, iy: 0.70710677, iz: 0, r: 0.70710677),
            angularVelocity: .zero,
            trigger: 1, grip: 0, stick: .zero,
            buttons: RAVEControllerButtons([.secondary, .menu]).rawValue,
            flags: [.present, .inHand],
            source: .quest, battery: ControllerBridgeTrackedController.batteryUnknown)
        return packet
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testMatchesTheHostsGoldenBytes() {
        let encoded = Self.goldenPacket().encoded()
        XCTAssertEqual(encoded.count, 144)
        XCTAssertEqual(hex(encoded), Self.golden)
    }

    func testHeaderAndOffsets() {
        let b = [UInt8](Self.goldenPacket().encoded())
        XCTAssertEqual(b[0], ControllerBridgeProtocol.packetTrackedControllers)
        XCTAssertEqual(b[0], 0x10)
        // v3 on this packet only; everything v2-era keeps its byte.
        XCTAssertEqual(b[1], ControllerBridgeProtocol.version3)
        XCTAssertEqual(ControllerBridgeProtocol.version, 2)
        XCTAssertEqual(b[2], 0x2A)
        // Per-side flags/source/battery at 60/61/62 of each 64-byte side.
        XCTAssertEqual(b[16 + 60], 0x1F)
        XCTAssertEqual(b[16 + 61], 2)
        XCTAssertEqual(b[16 + 62], 80)
        XCTAssertEqual(b[80 + 60], 0x05)
        XCTAssertEqual(b[80 + 61], 1)
        XCTAssertEqual(b[80 + 62], 0xFF)
    }

    /// RAVEControllerButtons travel verbatim; the C header's CB_TC_BTN_* are the same bits.
    func testButtonBitsAreRAVEs() {
        XCTAssertEqual(RAVEControllerButtons.primary.rawValue, 1 << 0)
        XCTAssertEqual(RAVEControllerButtons.secondary.rawValue, 1 << 1)
        XCTAssertEqual(RAVEControllerButtons.stickClick.rawValue, 1 << 2)
        XCTAssertEqual(RAVEControllerButtons.menu.rawValue, 1 << 3)
        XCTAssertEqual(RAVEControllerButtons.gripClick.rawValue, 1 << 4)
        XCTAssertEqual(RAVEControllerButtons.triggerTouch.rawValue, 1 << 5)
        XCTAssertEqual(RAVEControllerButtons.thumbTouch.rawValue, 1 << 6)
    }

    /// An absent side is what the host reads as "leave this side alone": no flags at all.
    func testAbsentSideCarriesNoFlags() {
        let b = [UInt8](ControllerBridgeTrackedControllers().encoded())
        XCTAssertEqual(b[16 + 60], 0)
        XCTAssertEqual(b[80 + 60], 0)
        XCTAssertEqual(b[16 + 62], 0xFF)
        // Identity rotation's w at offset 24 of the side.
        XCTAssertEqual(Array(b[16 + 24 ..< 16 + 28]), [0x00, 0x00, 0x80, 0x3F])
    }

    func testRendezvousAnnouncesTrackedControllers() throws {
        func rendezvous(flags: UInt8) -> Data {
            var b = [UInt8](repeating: 0, count: 226)
            b[0] = 0x0A
            b[1] = ControllerBridgeProtocol.version
            b[2] = 1
            b[3] = flags
            b[4] = 0x30; b[5] = 0x25            // input port 9520
            for i in 8 ..< 40 { b[i] = UInt8(i) }  // token
            Array("192.168.1.5".utf8).enumerated().forEach { b[40 + $0.offset] = $0.element }
            return Data(b)
        }
        let modern = try XCTUnwrap(ControllerBridgeRendezvous(rendezvous(flags: 0b111)))
        XCTAssertTrue(modern.sealsInput)
        XCTAssertTrue(modern.acceptsTrackedControllers)
        let older = try XCTUnwrap(ControllerBridgeRendezvous(rendezvous(flags: 0b011)))
        XCTAssertTrue(older.sealsInput)
        XCTAssertFalse(older.acceptsTrackedControllers)
    }
}

final class TrackedControllerForwardingTests: XCTestCase {

    private func state(_ chirality: RAVEHandChirality = .right, tracked: Bool = true,
                       inHand: Bool = true) -> RAVETrackedControllerState {
        RAVETrackedControllerState(
            chirality: chirality, isTracked: tracked, isInHand: inHand,
            position: SIMD3(0.3, 1.1, -0.4),
            orientation: simd_quatf(angle: .pi / 3, axis: SIMD3(0, 1, 0)),
            trigger: 0.6, grip: 0.4, stick: SIMD2(0.2, -0.9),
            buttons: [.primary, .thumbTouch], touchValid: true, batteryPercent: 55,
            timestamp: 10)
    }

    func testSideMapsEveryField() {
        let side = TrackedControllerForwarding.side(state(), source: .quest)
        XCTAssertEqual(side.flags, [.present, .tracked, .inHand, .touchValid])
        XCTAssertEqual(side.source, .quest)
        XCTAssertEqual(side.position, SIMD3(0.3, 1.1, -0.4))   // identity grip-from-origin
        XCTAssertEqual(side.orientation.angle, .pi / 3, accuracy: 1e-5)
        XCTAssertEqual(side.trigger, 0.6)
        XCTAssertEqual(side.grip, 0.4)
        XCTAssertEqual(side.stick, SIMD2(0.2, -0.9))
        XCTAssertEqual(side.buttons, RAVEControllerButtons([.primary, .thumbTouch]).rawValue)
        XCTAssertEqual(side.battery, 55)
        XCTAssertTrue(side.isHeld)
        XCTAssertTrue(side.ownsPose)
    }

    func testAngularVelocityOnlyWhenReported() {
        var s = state()
        XCTAssertFalse(TrackedControllerForwarding.side(s, source: .quest).flags.contains(.angularVelocity))
        s.angularVelocity = SIMD3(0, 2, 0)
        let side = TrackedControllerForwarding.side(s, source: .sense)
        XCTAssertTrue(side.flags.contains(.angularVelocity))
        XCTAssertEqual(side.angularVelocity, SIMD3(0, 2, 0))
    }

    func testUntrackedAndPutDownSides() {
        let untracked = TrackedControllerForwarding.side(state(tracked: false), source: .quest)
        XCTAssertTrue(untracked.isHeld)
        XCTAssertFalse(untracked.ownsPose)

        let putDown = TrackedControllerForwarding.side(state(inHand: false), source: .quest)
        XCTAssertFalse(putDown.isHeld)          // the host leaves this side to the hand
        XCTAssertFalse(putDown.ownsPose)
        XCTAssertTrue(putDown.flags.contains(.present))
    }

    func testClampsAndUnknownBattery() {
        var s = state()
        s.trigger = 1.7
        s.grip = -0.2
        s.stick = SIMD2(3, .nan)
        s.batteryPercent = nil
        let side = TrackedControllerForwarding.side(s, source: .sense)
        XCTAssertEqual(side.trigger, 1)
        XCTAssertEqual(side.grip, 0)
        XCTAssertEqual(side.stick, SIMD2(1, 0))
        XCTAssertEqual(side.battery, ControllerBridgeTrackedController.batteryUnknown)
    }

    func testNonFinitePoseIsNotTracked() {
        var s = state()
        s.position = SIMD3(.nan, 0, 0)
        let side = TrackedControllerForwarding.side(s, source: .sense)
        XCTAssertFalse(side.flags.contains(.tracked))
        XCTAssertEqual(side.position, .zero)
        XCTAssertTrue(side.isHeld)   // its buttons still count
    }

    func testArbitrationPrefersTheControllerThatCanDriveThePose() {
        // Only one backend: it wins.
        XCTAssertEqual(TrackedControllerForwarding.choose(quest: state(), sense: nil).source, .quest)
        XCTAssertEqual(TrackedControllerForwarding.choose(quest: nil, sense: state()).source, .sense)
        XCTAssertEqual(TrackedControllerForwarding.choose(quest: nil, sense: nil), .absent)
        // Tracked beats untracked, whichever backend.
        XCTAssertEqual(TrackedControllerForwarding.choose(quest: state(),
                                                          sense: state(tracked: false)).source, .quest)
        // In hand beats put down.
        XCTAssertEqual(TrackedControllerForwarding.choose(quest: state(tracked: false),
                                                          sense: state(tracked: false, inHand: false)).source,
                       .quest)
        // A tie goes to the Sense: the headset tracks it with no alignment in between.
        XCTAssertEqual(TrackedControllerForwarding.choose(quest: state(), sense: state()).source, .sense)
    }

    func testPacketFromFrames() {
        let quest = RAVETrackedControllerFrame(left: state(.left), right: nil)
        let sense = RAVETrackedControllerFrame(left: nil, right: state(.right))
        let packet = TrackedControllerForwarding.packet(quest: quest, sense: sense,
                                                        questAligned: true,
                                                        sequence: 7, now: 12.5)
        XCTAssertEqual(packet.sequence, 7)
        XCTAssertEqual(packet.timestampNs, 12_500_000_000)
        XCTAssertEqual(packet.left.source, .quest)
        XCTAssertEqual(packet.right.source, .sense)
        XCTAssertTrue(packet.left.ownsPose && packet.right.ownsPose)
    }

    /// Before the Quest is aligned its controllers override nothing — the hands keep
    /// their gestures while the user waves the controllers to calibrate. The Sense is
    /// never gated: the headset tracks it directly.
    func testUnalignedQuestOverridesNothing() {
        var untracked = state(.left, tracked: false)
        untracked.isInHand = true
        let quest = RAVETrackedControllerFrame(left: untracked, right: nil)
        let sense = RAVETrackedControllerFrame(left: nil, right: state(.right))
        let packet = TrackedControllerForwarding.packet(quest: quest, sense: sense,
                                                        questAligned: false,
                                                        sequence: 1, now: 1)
        XCTAssertEqual(packet.left.source, .quest)
        XCTAssertTrue(packet.left.flags.contains(.present))   // battery still reported
        XCTAssertFalse(packet.left.isHeld)
        XCTAssertTrue(packet.right.ownsPose)
    }

    func testQuestAlignedFollowsPollsRule() {
        var status = RAVEQuestBridgeSource.Status()
        XCTAssertFalse(TrackedControllerForwarding.questAligned(nil))
        status.phase = .collecting(samples: 3, spreadMeters: 0.1)
        XCTAssertFalse(TrackedControllerForwarding.questAligned(status))
        status.phase = .calibrated(residualMm: 8)
        XCTAssertTrue(TrackedControllerForwarding.questAligned(status))
        status.isWarmStart = true     // restored, not yet confirmed by fresh pairs
        XCTAssertFalse(TrackedControllerForwarding.questAligned(status))
    }

    func testHapticsGoToWhateverHoldsTheSide() {
        var packet = ControllerBridgeTrackedControllers()
        packet.left = TrackedControllerForwarding.side(state(.left), source: .quest)
        packet.right = TrackedControllerForwarding.side(state(.right), source: .sense)
        typealias F = TrackedControllerForwarding
        XCTAssertEqual(F.hapticTarget(for: .left, lastSent: packet, questAvailable: true,
                                      senseAvailable: true), .quest)
        XCTAssertEqual(F.hapticTarget(for: .right, lastSent: packet, questAvailable: true,
                                      senseAvailable: true), .sense)
        // The Quest listener was turned off since: the pad takes it.
        XCTAssertEqual(F.hapticTarget(for: .left, lastSent: packet, questAvailable: false,
                                      senseAvailable: true), .pad)
        // Put down: the hand is the hand again, so is its rumble.
        packet.left = TrackedControllerForwarding.side(state(.left, inHand: false), source: .quest)
        XCTAssertEqual(F.hapticTarget(for: .left, lastSent: packet, questAvailable: true,
                                      senseAvailable: true), .pad)
        XCTAssertEqual(F.hapticTarget(for: .left, lastSent: nil, questAvailable: true,
                                      senseAvailable: true), .pad)
    }

    func testWirePulseBecomesARAVEHaptic() throws {
        var bytes = [UInt8](repeating: 0, count: 14)
        bytes[0] = ControllerBridgeProtocol.packetHaptic
        bytes[1] = 1
        func put(_ v: Float, at o: Int) {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { bytes.replaceSubrange(o ..< o + 4, with: $0) }
        }
        put(0.05, at: 2); put(160, at: 6); put(1.4, at: 10)
        let pulse = try XCTUnwrap(ControllerBridgeHaptic(Data(bytes)))
        let haptic = TrackedControllerForwarding.haptic(pulse, hand: .right)
        XCTAssertEqual(haptic.chirality, .right)
        XCTAssertEqual(haptic.duration, 0.05, accuracy: 1e-6)
        XCTAssertEqual(haptic.frequency, 160)
        XCTAssertEqual(haptic.amplitude, 1)   // clamped
    }
}

final class QuestControllerStatusTextTests: XCTestCase {

    private func status(_ phase: RAVEQuestBridgeSource.Phase, left: Bool = true,
                        right: Bool = true) -> RAVEQuestBridgeSource.Status {
        var s = RAVEQuestBridgeSource.Status()
        s.isListening = true
        s.phase = phase
        s.leftTracked = left
        s.rightTracked = right
        s.advertisedName = "Vision Pro"
        return s
    }

    func testOffInvitesTurningItOn() {
        let line = QuestControllerStatusText.detail(enabled: false, status: nil, startError: nil)
        XCTAssertEqual(line.tone, .neutral)
        XCTAssertTrue(line.text.contains("Controller Bridge"))
    }

    func testWaitingNamesThisHeadset() {
        let line = QuestControllerStatusText.detail(enabled: true, status: status(.idle), startError: nil)
        XCTAssertTrue(line.text.contains("\u{201C}Vision Pro\u{201D}"))
    }

    func testCollectingNagsOnSpreadFirst() {
        let narrow = QuestControllerStatusText.detail(
            enabled: true, status: status(.collecting(samples: 30, spreadMeters: 0.1)), startError: nil)
        XCTAssertTrue(narrow.text.contains("wave your arms"))
        let wide = QuestControllerStatusText.detail(
            enabled: true, status: status(.collecting(samples: 30, spreadMeters: 0.4)), startError: nil)
        XCTAssertTrue(wide.text.contains("30 of \(RAVEQuestCalibration.minSamples)"))
    }

    func testCalibratedReportsResidualAndMissingSide() {
        let good = QuestControllerStatusText.detail(
            enabled: true, status: status(.calibrated(residualMm: 12)), startError: nil)
        XCTAssertEqual(good.tone, .good)
        XCTAssertTrue(good.text.contains("±12 mm"))
        let oneSide = QuestControllerStatusText.detail(
            enabled: true, status: status(.calibrated(residualMm: 12), right: false), startError: nil)
        XCTAssertTrue(oneSide.text.contains("right controller is not tracked"))
    }

    func testFailuresAreWarnings() {
        XCTAssertEqual(QuestControllerStatusText.detail(enabled: true, status: status(.lost),
                                                        startError: nil).tone, .warning)
        let failed = QuestControllerStatusText.detail(enabled: true, status: nil,
                                                      startError: "Address already in use")
        XCTAssertEqual(failed.tone, .warning)
        XCTAssertTrue(failed.text.contains("Address already in use"))
    }
}
#endif
