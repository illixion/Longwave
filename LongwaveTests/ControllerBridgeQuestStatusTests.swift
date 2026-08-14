import XCTest
@testable import Longwave

/// The 0x0D desk-Quest status is decoded by hand from bytes, against a C struct in
/// another repository that nothing on this side can check at compile time — so the
/// offsets are pinned here instead. The battery pair in particular has three
/// distinct "no number" cases (flag clear, sentinel, out of range) that must all
/// come out as nil rather than as a scary 0%.
///
/// Gated with the feature, like everything else on the PCVR path.
#if FOVEATED_ENABLED
final class ControllerBridgeQuestStatusTests: XCTestCase {

    /// A 28-byte packet with the fields this suite cares about; everything else
    /// stays zero.
    private func packet(state: UInt8 = 3,
                        flags: UInt8 = 0,
                        batteryLeft: UInt8 = 0xFF,
                        batteryRight: UInt8 = 0xFF,
                        residualMm: Float = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 28)
        bytes[0] = ControllerBridgeProtocol.packetQuestStatus
        bytes[1] = ControllerBridgeProtocol.version
        bytes[2] = 9                                   // sequence
        bytes[3] = state
        bytes[4] = flags
        bytes[5] = batteryLeft
        bytes[6] = batteryRight
        withUnsafeBytes(of: residualMm.bitPattern.littleEndian) {
            bytes.replaceSubrange(20..<24, with: $0)
        }
        return Data(bytes)
    }

    func testDecodesStateAndFlags() throws {
        let status = try XCTUnwrap(ControllerBridgeQuestStatus(packet(
            state: 2, flags: 0b0000_0011, residualMm: 12.5)))
        XCTAssertEqual(status.state, .collecting)
        XCTAssertTrue(status.flags.contains(.leftTracked))
        XCTAssertTrue(status.flags.contains(.rightTracked))
        XCTAssertFalse(status.flags.contains(.warmStart))
        XCTAssertEqual(status.residualMm, 12.5)
    }

    func testRejectsShortOrForeignPackets() {
        XCTAssertNil(ControllerBridgeQuestStatus(packet().prefix(27)))
        var wrongType = [UInt8](packet())
        wrongType[0] = 0x03
        XCTAssertNil(ControllerBridgeQuestStatus(Data(wrongType)))
        // A state the host never sends is a decode failure, not a default.
        XCTAssertNil(ControllerBridgeQuestStatus(packet(state: 9)))
    }

    func testBatteryNeedsItsFlag() throws {
        // Levels present but unflagged: an older host reuses these bytes as padding,
        // so they must not read as two nearly-flat controllers.
        let unflagged = try XCTUnwrap(ControllerBridgeQuestStatus(packet(
            flags: 0, batteryLeft: 3, batteryRight: 4)))
        XCTAssertNil(unflagged.batteryLeft)
        XCTAssertNil(unflagged.batteryRight)

        let flagged = try XCTUnwrap(ControllerBridgeQuestStatus(packet(
            flags: 1 << 3, batteryLeft: 87, batteryRight: 64)))
        XCTAssertEqual(flagged.batteryLeft, 87)
        XCTAssertEqual(flagged.batteryRight, 64)
    }

    func testBatteryUnknownAndOutOfRangeAreNil() throws {
        // Flag set, one controller switched off: that side has no number, the other
        // still does.
        let oneOff = try XCTUnwrap(ControllerBridgeQuestStatus(packet(
            flags: 1 << 3, batteryLeft: 0xFF, batteryRight: 100)))
        XCTAssertNil(oneOff.batteryLeft)
        XCTAssertEqual(oneOff.batteryRight, 100)

        let nonsense = try XCTUnwrap(ControllerBridgeQuestStatus(packet(
            flags: 1 << 3, batteryLeft: 200, batteryRight: 101)))
        XCTAssertNil(nonsense.batteryLeft)
        XCTAssertNil(nonsense.batteryRight)

        // Zero is a real reading, not a missing one.
        let empty = try XCTUnwrap(ControllerBridgeQuestStatus(packet(
            flags: 1 << 3, batteryLeft: 0, batteryRight: 0)))
        XCTAssertEqual(empty.batteryLeft, 0)
        XCTAssertEqual(empty.batteryRight, 0)
    }
}
#endif
