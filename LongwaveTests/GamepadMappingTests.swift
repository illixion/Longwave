import XCTest
import simd
import RAVEInput
@testable import Longwave

/// Both gamepad readers map the same `RAVEGamepadSnapshot` now; these pin each mapping
/// to the wire values it produced when it still walked `GCExtendedGamepad` itself, so
/// the move to a shared snapshot cannot quietly change what a host receives. Expected
/// values are literals on purpose: they are the wire, not a restatement of the code.

#if FOVEATED_ENABLED
@MainActor
final class ControllerBridgeGamepadTests: XCTestCase {

    private func buttons(for pad: RAVEGamepadSnapshot.Buttons) -> UInt32 {
        var state = ControllerBridgeInputState()
        ControllerBridgeSender.applyGamepad(RAVEGamepadSnapshot(buttons: pad), to: &state)
        return state.buttons.rawValue
    }

    /// The Switch Pro bit each GameController button lands on (`cb_input_state_t.buttons`).
    func testEveryButtonLandsOnItsWireBit() {
        let expected: [(RAVEGamepadSnapshot.Buttons, UInt32)] = [
            (.a, 1 << 0), (.b, 1 << 1), (.x, 1 << 2), (.y, 1 << 3),
            (.leftShoulder, 1 << 4), (.rightShoulder, 1 << 5),
            (.leftTrigger, 1 << 6), (.rightTrigger, 1 << 7),
            (.options, 1 << 8), (.menu, 1 << 9),
            (.leftStick, 1 << 10), (.rightStick, 1 << 11), (.home, 1 << 12),
            (.dpadUp, 1 << 14), (.dpadDown, 1 << 15), (.dpadLeft, 1 << 16), (.dpadRight, 1 << 17),
        ]
        for (button, bit) in expected {
            XCTAssertEqual(buttons(for: button), bit, "\(button)")
        }
        XCTAssertEqual(buttons(for: []), 0)
    }

    /// Gestures write first; a pad merges over them rather than masking them.
    func testPadMergesOverGestures() {
        var state = ControllerBridgeInputState()
        state.buttons = [.capture]
        state.leftStick = SIMD2(0, 0.8)          // gesture joystick
        state.rightStick = SIMD2(0.6, 0)         // gesture turn
        state.leftTrigger = 0.5
        let resting = RAVEGamepadSnapshot(buttons: [.a], leftStick: SIMD2(0.1, 0),
                                          rightStick: SIMD2(0, 0.1), rightTrigger: 0.25)
        ControllerBridgeSender.applyGamepad(resting, to: &state)
        XCTAssertEqual(state.buttons, [.capture, .a])
        XCTAssertEqual(state.leftStick, SIMD2(0, 0.8), "an undeflected pad stick leaves the gesture joystick")
        XCTAssertEqual(state.rightStick, SIMD2(0.6, 0), "an undeflected pad stick leaves the gesture turn")
        XCTAssertEqual(state.leftTrigger, 0.5)
        XCTAssertEqual(state.rightTrigger, 0.25)

        let deflected = RAVEGamepadSnapshot(leftStick: SIMD2(-1, 0), rightStick: SIMD2(0, -0.5))
        ControllerBridgeSender.applyGamepad(deflected, to: &state)
        XCTAssertEqual(state.leftStick, SIMD2(-1, 0))
        XCTAssertEqual(state.rightStick, SIMD2(0, -0.5))
    }

    /// With no turn in progress the pad's right stick passes through even at rest.
    func testRightStickPassesThroughWhenNoTurn() {
        var state = ControllerBridgeInputState()
        ControllerBridgeSender.applyGamepad(RAVEGamepadSnapshot(rightStick: SIMD2(0.05, 0)), to: &state)
        XCTAssertEqual(state.rightStick, SIMD2(0.05, 0))
    }
}
#endif

#if MOONLIGHT_ENABLED
@MainActor
final class MoonlightGamepadMappingTests: XCTestCase {

    private func flags(_ pad: RAVEGamepadSnapshot.Buttons, swap: Bool = false) -> Int32 {
        MoonlightGamepadMapping.state(RAVEGamepadSnapshot(buttons: pad), swapABXY: swap).buttonFlags
    }

    /// moonlight-common-c's `*_FLAG` values (Limelight.h).
    func testEveryButtonLandsOnItsFlag() {
        let expected: [(RAVEGamepadSnapshot.Buttons, Int32)] = [
            (.a, 0x1000), (.b, 0x2000), (.x, 0x4000), (.y, 0x8000),
            (.dpadUp, 0x0001), (.dpadDown, 0x0002), (.dpadLeft, 0x0004), (.dpadRight, 0x0008),
            (.menu, 0x0010), (.options, 0x0020), (.leftStick, 0x0040), (.rightStick, 0x0080),
            (.leftShoulder, 0x0100), (.rightShoulder, 0x0200), (.home, 0x0400),
            // Moonlight carries the triggers as analog values only.
            (.leftTrigger, 0), (.rightTrigger, 0),
        ]
        for (button, flag) in expected {
            XCTAssertEqual(flags(button), flag, "\(button)")
        }
    }

    func testNintendoLayoutSwapsFaceButtonsOnly() {
        XCTAssertEqual(flags(.a, swap: true), 0x2000)
        XCTAssertEqual(flags(.b, swap: true), 0x1000)
        XCTAssertEqual(flags(.x, swap: true), 0x8000)
        XCTAssertEqual(flags(.y, swap: true), 0x4000)
        XCTAssertEqual(flags([.a, .b], swap: true), 0x3000)
        XCTAssertEqual(flags(.dpadUp, swap: true), 0x0001)
    }

    func testAxesScaleToTheWireRanges() {
        let pad = RAVEGamepadSnapshot(leftStick: SIMD2(1, -1), rightStick: SIMD2(0.5, 0),
                                      leftTrigger: 1, rightTrigger: 0.5)
        let state = MoonlightGamepadMapping.state(pad, swapABXY: false)
        XCTAssertEqual(state.leftStickX, 0x7FFE)
        XCTAssertEqual(state.leftStickY, -0x7FFE)
        XCTAssertEqual(state.rightStickX, 0x3FFF)
        XCTAssertEqual(state.rightStickY, 0)
        XCTAssertEqual(state.leftTrigger, 0xFF)
        XCTAssertEqual(state.rightTrigger, 127)
    }

    /// Axis order and signs as moonlight-ios sends them to Sunshine.
    func testMotionConvertsUnitsAndAxes() {
        let gyro = MoonlightGamepadMapping.gyro(SIMD3(1, 2, 3))
        XCTAssertEqual(gyro.x, 57.2957795, accuracy: 1e-3)
        XCTAssertEqual(gyro.y, 3 * 57.2957795, accuracy: 1e-3)
        XCTAssertEqual(gyro.z, -2 * 57.2957795, accuracy: 1e-3)

        let accel = MoonlightGamepadMapping.acceleration(SIMD3(0, -1, 0.5))
        XCTAssertEqual(accel.x, 0, accuracy: 1e-6)
        XCTAssertEqual(accel.y, 9.80665, accuracy: 1e-4)
        XCTAssertEqual(accel.z, -4.903325, accuracy: 1e-4)
    }
}
#endif

/// The roster's claim and fan-out, driven through a virtual pad — the same path the
/// debug endpoints use, so a green run here means the harness drives what real pads do.
@MainActor
final class GamepadRosterVirtualPadTests: XCTestCase {

    func testVirtualPadIsClaimedFannedOutAndReleased() throws {
        let roster = GamepadRoster.shared
        var connected: [Int] = []
        var disconnected: [Int] = []
        var changes: [(Int, RAVEGamepadSnapshot)] = []
        XCTAssertNil(roster.addVirtualPad(gyro: true, accelerometer: false),
                     "with nobody subscribed there is nothing to drive")

        let subscription = roster.subscribe(
            connected: { slot, _ in connected.append(slot) },
            disconnected: { slot, _ in disconnected.append(slot) },
            changed: { slot, snapshot in changes.append((slot, snapshot)) })
        defer { roster.unsubscribe(subscription) }

        let slot = try XCTUnwrap(roster.addVirtualPad(gyro: true, accelerometer: false))
        XCTAssertEqual(connected, [slot])
        XCTAssertTrue(roster.isVirtual(slot: slot))
        XCTAssertEqual(roster.controllers[slot]?.playerIndex.rawValue, slot)
        XCTAssertNotEqual(roster.activeMask & UInt16(1 << slot), 0)
        XCTAssertTrue(roster.motionSensors(slot: slot) == (true, false))

        let state = RAVEGamepadSnapshot(buttons: [.a, .dpadUp], leftStick: SIMD2(0.5, 0),
                                        rightTrigger: 1, rotationRate: SIMD3(1, 2, 3))
        XCTAssertTrue(roster.setVirtualPad(slot: slot, to: state))
        let delivered = try XCTUnwrap(changes.last)
        XCTAssertEqual(delivered.0, slot)
        XCTAssertEqual(delivered.1.buttons, [.a, .dpadUp, .rightTrigger], "a full trigger reads as pressed")
        XCTAssertEqual(delivered.1.leftStick, SIMD2(0.5, 0))
        XCTAssertNil(delivered.1.rotationRate, "change events carry no motion; readers poll it")

        let polled = try XCTUnwrap(roster.snapshot(slot: slot))
        XCTAssertEqual(polled.rotationRate, SIMD3(1, 2, 3))
        XCTAssertNil(polled.acceleration, "an undeclared sensor reads as absent")

        roster.setMotionWanted(true, slot: slot, by: subscription)
        XCTAssertEqual(roster.motionRequests(slot: slot), 1)

        XCTAssertTrue(roster.removeVirtualPad(slot: slot))
        XCTAssertEqual(disconnected, [slot])
        XCTAssertNil(roster.controllers[slot])
        XCTAssertEqual(roster.motionRequests(slot: slot), 0)
        XCTAssertFalse(roster.setVirtualPad(slot: slot, to: state))
    }
}
