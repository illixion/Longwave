import XCTest
import simd
@testable import Longwave

/// The headset's side of the tracker hub: the 0x11 decode and 0x12 encode (pinned against the
/// host's bytes), the command queue's acknowledgement rules, naming, status text, and the
/// overlay's pure decisions. The wire vectors are the ones the broker's own test builds
/// (SessionBroker `test_tracker_hub`), so drift on either side fails a test on that side.
///
/// Gated with the feature, like everything else on the PCVR path.
#if FOVEATED_ENABLED

final class TrackerWireTests: XCTestCase {

    /// 0x11: seq 7, ack 200 OK, AUTO_ALIGN|HUB_ACTIVE|HEAD_VALID, COLLECTING on device 1 with the
    /// right hand, 14 pairs, 0.18 of 0.25 m; a placed wand and an unplaced Touch controller.
    static let trackersGolden =
        "110307020fc8010201010e00ec51383e000000000000803e6c69676874686f75"
        + "73653a4c48522d31000000000000000000000000000000000000c03f0000a03f"
        + "000000bf00000000f404353f00000000f404353f0000403f0f0101570000000071"
        + "756573743a616263642d6c65667400000000000000000000000000000000000000"
        + "000000000000000000000000000000000000000000000000803f00000000010002"
        + "ffff000000"

    /// 0x12: ASSIGN, sequence 41, role 15 (left foot), key lighthouse:LHR-1.
    static let commandGolden =
        "120329040f0000006c69676874686f7573653a4c48522d3100000000000000000000000000000000"

    private func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    func testDecodesTheHostsGoldenPacket() throws {
        let data = bytes(Self.trackersGolden)
        XCTAssertEqual(data.count, 24 + 2 * 72)
        let t = try XCTUnwrap(ControllerBridgeTrackers(data))
        XCTAssertEqual(t.sequence, 7)
        XCTAssertEqual(t.ackSequence, 200)
        XCTAssertEqual(t.ackResult, .ok)
        XCTAssertEqual(t.flags, [.autoAlign, .hubActive, .headValid, .autoAlignOn])
        XCTAssertEqual(t.alignPhase, .collecting)
        XCTAssertEqual(t.alignDevice, 1)
        XCTAssertEqual(t.alignHand, 1)
        XCTAssertEqual(t.alignSamples, 14)
        XCTAssertEqual(t.alignSpreadMeters, 0.18, accuracy: 1e-6)
        XCTAssertEqual(t.alignSpreadTargetMeters, 0.25, accuracy: 1e-6)
        XCTAssertEqual(t.devices.count, 2)

        let wand = t.devices[0]
        XCTAssertEqual(wand.key, "lighthouse:LHR-1")
        XCTAssertEqual(wand.kind, .wand)
        XCTAssertEqual(wand.position, SIMD3(1.5, 1.25, -0.5))
        XCTAssertEqual(wand.orientation.vector.y, 0.7071, accuracy: 1e-4)
        XCTAssertEqual(wand.orientation.real, 0.7071, accuracy: 1e-4)
        XCTAssertEqual(wand.speed, 0.75, accuracy: 1e-6)
        XCTAssertEqual(wand.battery, 87)
        XCTAssertEqual(wand.role, TrackerRole.leftHand.rawValue)
        XCTAssertEqual(wand.ownsHand, 0)
        XCTAssertEqual(wand.flags, [.tracked, .placed, .aligned, .held])

        let touch = t.devices[1]
        XCTAssertEqual(touch.key, "quest:abcd-left")
        XCTAssertEqual(touch.kind, .touch)
        XCTAssertEqual(touch.flags, [.tracked])
        XCTAssertFalse(touch.isPlaced)
        XCTAssertEqual(touch.battery, ControllerBridgeTrackerDevice.batteryUnknown)
        XCTAssertEqual(touch.ownsHand, -1)
        XCTAssertEqual(touch.orientation.real, 1, accuracy: 1e-6)
    }

    func testReencodingTheGoldenPacketIsByteIdentical() throws {
        let data = bytes(Self.trackersGolden)
        let t = try XCTUnwrap(ControllerBridgeTrackers(data))
        XCTAssertEqual(t.encoded(), data)
    }

    func testEncodesTheCommandGoldenBytes() {
        let command = ControllerBridgeTrackerCommand(
            op: .assign, arg: TrackerRole.leftFoot.rawValue, key: "lighthouse:LHR-1")
        XCTAssertEqual(command.encoded(sequence: 41), bytes(Self.commandGolden))
    }

    func testRejectsMalformedPackets() throws {
        let good = bytes(Self.trackersGolden)
        XCTAssertNil(ControllerBridgeTrackers(good.prefix(23)), "shorter than the header")
        XCTAssertNil(ControllerBridgeTrackers(good.prefix(24 + 72 + 71)), "a record cut short")
        var wrongVersion = good
        wrongVersion[1] = 2
        XCTAssertNil(ControllerBridgeTrackers(wrongVersion))
        var wrongType = good
        wrongType[0] = 0x10
        XCTAssertNil(ControllerBridgeTrackers(wrongType))
        var tooMany = good
        tooMany[3] = 13
        XCTAssertNil(ControllerBridgeTrackers(tooMany), "more than CB_TRACKERS_MAX_DEVICES")
    }

    func testAnAlignDeviceIndexOutsideTheListDecodesAsNone() throws {
        var data = bytes(Self.trackersGolden)
        data[8] = 5
        XCTAssertNil(try XCTUnwrap(ControllerBridgeTrackers(data)).alignDevice)
        data[8] = 0xFF
        XCTAssertNil(try XCTUnwrap(ControllerBridgeTrackers(data)).alignDevice)
    }

    func testRolesFollowTheHubsEnumOrder() {
        XCTAssertEqual(TrackerRole.allCases.count, 17)
        XCTAssertEqual(TrackerRole.leftHand.rawValue, 1)
        XCTAssertEqual(TrackerRole.rightHand.rawValue, 2)
        XCTAssertEqual(TrackerRole.chest.rawValue, 3)
        XCTAssertEqual(TrackerRole.leftFoot.rawValue, 15)
        XCTAssertEqual(TrackerRole.rightFoot.rawValue, 16)
    }
}

final class TrackerCommandQueueTests: XCTestCase {

    private func sequenceOf(_ packet: Data) -> UInt8 { packet[2] }

    func testSendsOneCommandAtATimeAndWaitsForTheAcknowledgement() throws {
        var q = TrackerCommandQueue(startSequence: 10)
        q.enqueue(.init(op: .alignStart, arg: ControllerBridgeTrackerCommand.handAuto))
        q.enqueue(.init(op: .alignStop))

        let first = try XCTUnwrap(q.packetToSend(now: 0))
        XCTAssertEqual(first[3], ControllerBridgeTrackerCommand.Op.alignStart.rawValue)
        XCTAssertEqual(sequenceOf(first), 11)
        q.markSent(now: 0)

        // Not yet due again, and the second command must not overtake the first.
        XCTAssertNil(q.packetToSend(now: 0.1))
        let again = try XCTUnwrap(q.packetToSend(now: 0.25))
        XCTAssertEqual(again, first, "a resend carries the same sequence")
        q.markSent(now: 0.25)

        XCTAssertTrue(q.acknowledge(sequence: 11, result: .ok))
        let second = try XCTUnwrap(q.packetToSend(now: 0.3))
        XCTAssertEqual(second[3], ControllerBridgeTrackerCommand.Op.alignStop.rawValue)
        XCTAssertEqual(sequenceOf(second), 12)
    }

    func testAnUnrelatedOrEmptyAcknowledgementDoesNotCount() throws {
        var q = TrackerCommandQueue(startSequence: 0)
        q.enqueue(.init(op: .reset))
        _ = try XCTUnwrap(q.packetToSend(now: 0))
        XCTAssertEqual(q.sequence, 1, "the sequence never takes 0")
        // Before the first send nothing can have been executed.
        XCTAssertFalse(q.acknowledge(sequence: 1, result: .ok))
        q.markSent(now: 0)
        XCTAssertFalse(q.acknowledge(sequence: 2, result: .ok), "another command's answer")
        XCTAssertFalse(q.acknowledge(sequence: 1, result: .none), "a host that has run nothing says NONE")
        XCTAssertNotNil(q.inFlight)
        XCTAssertTrue(q.acknowledge(sequence: 1, result: .refused))
        XCTAssertEqual(q.lastOutcome, .acknowledged(.refused))
        XCTAssertTrue(q.isIdle)
    }

    func testTheSequenceWrapsPastZero() throws {
        var q = TrackerCommandQueue(startSequence: 254)
        for expected: UInt8 in [255, 1, 2] {
            q.enqueue(.init(op: .alignStop))
            let packet = try XCTUnwrap(q.packetToSend(now: 0))
            XCTAssertEqual(sequenceOf(packet), expected)
            q.markSent(now: 0)
            XCTAssertTrue(q.acknowledge(sequence: expected, result: .ok))
        }
    }

    func testAnUnansweredCommandIsGivenUpOnSoTheQueueDoesNotStick() throws {
        var q = TrackerCommandQueue(startSequence: 1)
        q.enqueue(.init(op: .reset))
        q.enqueue(.init(op: .alignStop))
        _ = try XCTUnwrap(q.packetToSend(now: 0))
        q.markSent(now: 0)
        let next = try XCTUnwrap(q.packetToSend(now: TrackerCommandQueue.giveUpAfter + 1))
        XCTAssertEqual(q.lastOutcome, .timedOut)
        XCTAssertEqual(next[3], ControllerBridgeTrackerCommand.Op.alignStop.rawValue)
    }

    func testARandomStartNeverStartsAtZero() {
        for _ in 0..<500 { XCTAssertNotEqual(TrackerCommandQueue().sequence, 0) }
    }
}

@MainActor
final class TrackerHubModelTests: XCTestCase {

    private func packet(devices: [ControllerBridgeTrackerDevice] = [],
                        phase: ControllerBridgeTrackers.AlignPhase = .idle,
                        ack: UInt8 = 0, result: ControllerBridgeTrackers.Result = .none)
        -> ControllerBridgeTrackers {
        var p = ControllerBridgeTrackers()
        p.devices = devices
        p.alignPhase = phase
        p.ackSequence = ack
        p.ackResult = result
        return p
    }

    private func device(_ key: String, kind: ControllerBridgeTrackerDevice.Kind = .wand,
                        flags: ControllerBridgeTrackerDevice.Flags? = nil)
        -> ControllerBridgeTrackerDevice {
        var d = ControllerBridgeTrackerDevice()
        d.key = key
        d.kind = kind
        d.flags = flags ?? [.tracked, .placed, .aligned]
        return d
    }

    func testNothingIsSentToAHostThatHasNotSpoken() {
        let model = TrackerHubModel()
        model.alignStart()
        XCTAssertNil(model.packetToSend(now: 0))
        XCTAssertEqual(model.pendingCommands, 0)
        model.ingest(packet(), now: 0)
        model.alignStart()
        XCTAssertNotNil(model.packetToSend(now: 0))
    }

    func testRealignIsAResetThenAStartAndRolesMapToAssignAndUnassign() throws {
        let model = TrackerHubModel()
        model.ingest(packet(), now: 0)
        model.realign()
        model.assign("lighthouse:LHR-1", role: .leftFoot)
        model.assign("lighthouse:LHR-1", role: .none)
        var ops: [UInt8] = []
        var now: CFTimeInterval = 0
        for _ in 0..<4 {
            let bytes = try XCTUnwrap(model.packetToSend(now: now))
            ops.append(bytes[3])
            model.markSent(now: now)
            model.ingest(packet(ack: model.commandSequence, result: .ok), now: now)
            now += 0.05
        }
        XCTAssertEqual(ops, [3, 1, 4, 5])
    }

    func testARefusedCommandSurfacesAMessage() throws {
        let model = TrackerHubModel()
        model.ingest(packet(), now: 0)
        model.assign("lighthouse:LHR-1", role: .chest)
        _ = model.packetToSend(now: 0)
        model.markSent(now: 0)
        model.ingest(packet(ack: model.commandSequence, result: .refused), now: 0.1)
        XCTAssertNotNil(model.lastError)
        model.dismissError()
        XCTAssertNil(model.lastError)
    }

    func testTheOverlayShowsOnlyWhileLiveAndWantedAndForAWhileAfterAnAlignment() {
        let model = TrackerHubModel()
        XCTAssertFalse(model.overlayWanted(now: 0), "no host")
        model.ingest(packet(devices: [device("a:1", flags: [.tracked])]), now: 100)
        XCTAssertFalse(model.overlayWanted(now: 100), "live, but nobody asked")
        model.panelAppeared()
        XCTAssertTrue(model.overlayWanted(now: 100.5))
        XCTAssertFalse(model.overlayWanted(now: 100 + TrackerHubModel.liveWithin + 0.1), "host went quiet")
        model.panelDisappeared()
        XCTAssertFalse(model.overlayWanted(now: 100.5))

        // The device becomes aligned: it is shown for the verify window, then not.
        model.ingest(packet(devices: [device("a:1")]), now: 101)
        XCTAssertTrue(model.overlayWanted(now: 101.5))
        model.ingest(packet(devices: [device("a:1")]), now: 101 + TrackerHubModel.verifyWindow + 1)
        XCTAssertFalse(model.overlayWanted(now: 101 + TrackerHubModel.verifyWindow + 1))
        model.showAlways = true
        XCTAssertTrue(model.overlayWanted(now: 101 + TrackerHubModel.verifyWindow + 1))
        model.showAlways = false
    }

    func testTheViewsAreRepublishedAtTenHertzButTheOverlayGetsEveryPacket() {
        let model = TrackerHubModel()
        var p = packet(devices: [device("a:1")])
        model.ingest(p, now: 0)
        let first = model.trackers
        p.devices[0].speed = 1
        model.ingest(p, now: 0.03)
        XCTAssertEqual(model.trackers, first, "a moving meter alone is not republished")
        XCTAssertEqual(model.latest?.devices[0].speed, 1, "but the overlay's copy is current")
        model.ingest(p, now: 0.2)
        XCTAssertEqual(model.trackers?.devices[0].speed, 1)
        p.alignPhase = .collecting
        model.ingest(p, now: 0.21)
        XCTAssertEqual(model.trackers?.alignPhase, .collecting, "a visible change is immediate")
    }

    func testHeadsetControllersBecomePlacedPseudoDevices() {
        var packet = ControllerBridgeTrackedControllers()
        packet.left = ControllerBridgeTrackedController(
            position: SIMD3(0.1, 1.2, -0.3), flags: [.present, .tracked, .inHand], source: .quest, battery: 55)
        packet.right = ControllerBridgeTrackedController(flags: [.present], source: .quest)
        let local = TrackerHubModel.localDevices(from: packet)
        XCTAssertEqual(local.count, 1, "an untracked side is not drawn")
        XCTAssertEqual(local[0].key, "headset:left")
        XCTAssertEqual(local[0].position, SIMD3(0.1, 1.2, -0.3))
        XCTAssertTrue(local[0].isPlaced)
        XCTAssertTrue(local[0].flags.contains(.held))
        XCTAssertEqual(local[0].ownsHand, 0)
        XCTAssertTrue(TrackerHubModel.localDevices(from: nil).isEmpty)
    }
}

final class TrackerNamingAndStatusTests: XCTestCase {

    func testNamesTellDevicesApart() {
        XCTAssertEqual(TrackerNaming.name(key: "lighthouse:LHR-F7C91FC0", kind: .wand), "Wand 1FC0")
        XCTAssertEqual(TrackerNaming.name(key: "lighthouse:LHR-F7CDFFC7", kind: .tracker), "Tracker FFC7")
        XCTAssertEqual(TrackerNaming.name(key: "quest:abcd-left", kind: .touch), "Left touch controller")
        XCTAssertEqual(TrackerNaming.name(key: "headset:right", kind: .touch), "Right touch controller")
        XCTAssertEqual(TrackerNaming.name(key: "", kind: .other), "Device")
    }

    private func status(_ configure: (inout ControllerBridgeTrackers) -> Void)
        -> (text: String, tone: TrackerAlignStatus.Tone) {
        var t = ControllerBridgeTrackers()
        configure(&t)
        return TrackerAlignStatus.describe(t)
    }

    func testStatusTextFollowsThePhase() {
        XCTAssertEqual(status { _ in }.text, "No trackers in view.")

        var wand = ControllerBridgeTrackerDevice()
        wand.key = "lighthouse:LHR-F7C91FC0"
        wand.kind = .wand
        wand.flags = [.tracked]
        let unaligned = status { $0.devices = [wand] }
        XCTAssertEqual(unaligned.tone, .warning)
        XCTAssertTrue(unaligned.text.contains("Not aligned"))

        wand.flags = [.tracked, .placed, .aligned]
        XCTAssertEqual(status { $0.devices = [wand] }.tone, .good)

        XCTAssertTrue(status { $0.alignPhase = .waiting }.text.hasPrefix("Waiting for a device"))

        let collecting = status {
            $0.devices = [wand]
            $0.alignPhase = .collecting
            $0.alignDevice = 0
            $0.alignHand = 0
            $0.alignSamples = 14
            $0.alignSpreadMeters = 0.18
            $0.alignSpreadTargetMeters = 0.25
        }
        XCTAssertEqual(collecting.text,
                       "Left hand: Wand 1FC0, 14 pairs, 0.18 of 0.25 m. Keep sweeping your arm.")
        XCTAssertTrue(status { $0.alignPhase = .collecting }.text.contains("Matching"))

        let done = status { $0.alignPhase = .done; $0.alignResidualMm = 3.14 }
        XCTAssertEqual(done.tone, .good)
        XCTAssertTrue(done.text.hasPrefix("Aligned, 3.1 mm."))
    }

    func testTheOutlineLookFollowsTheDevicesState() {
        var d = ControllerBridgeTrackerDevice()
        d.flags = [.tracked, .placed, .aligned, .held]
        XCTAssertEqual(TrackerOverlayDriver.look(for: d, isTarget: false, isLocal: false, pulse: true), .bright)
        d.flags = [.tracked, .placed, .aligned]
        XCTAssertEqual(TrackerOverlayDriver.look(for: d, isTarget: false, isLocal: false, pulse: true), .dim)
        XCTAssertEqual(TrackerOverlayDriver.look(for: d, isTarget: true, isLocal: false, pulse: true), .target)
        XCTAssertEqual(TrackerOverlayDriver.look(for: d, isTarget: true, isLocal: false, pulse: false), .targetAlt)
        XCTAssertEqual(TrackerOverlayDriver.look(for: d, isTarget: false, isLocal: true, pulse: true), .localDim)
        d.flags.insert(.held)
        XCTAssertEqual(TrackerOverlayDriver.look(for: d, isTarget: false, isLocal: true, pulse: true), .local)
    }
}

#endif
