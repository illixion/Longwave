import XCTest
import simd
import RAVEInput
@testable import Longwave

/// Per-title PCVR input: profile decoding, mapping precedence, the gesture turn and hand
/// ownership. Gated with the feature, same as PCVRSessionLimiterTests: these types only
/// exist inside the PCVR/foveated build. All pure — no ARKit, no UserDefaults.
#if FOVEATED_ENABLED

// MARK: - Profile decoding

final class GameInputDecodingTests: XCTestCase {

    private func decodeProfiles(_ json: String) throws -> [String: GameProfile] {
        try JSONDecoder().decode([String: GameProfile].self, from: Data(json.utf8))
    }

    /// A profile saved before any of the new keys existed loads unchanged, and every new
    /// setting reads as its default.
    func testProfileSavedByAnOlderBuildStillLoads() throws {
        let profiles = try decodeProfiles("""
            {"hlvr.exe": {"input": {"emulateControllers": false}, "graphics": {}}}
            """)
        let input = try XCTUnwrap(profiles["hlvr.exe"]).input
        XCTAssertEqual(input.emulateControllers, false)
        XCTAssertNil(input.locomotion)
        XCTAssertNil(input.turn)
        XCTAssertNil(input.turnHand)
        XCTAssertNil(input.joystickSensitivity)
        XCTAssertEqual(input.resolvedLocomotion, .pinchJoystick)
        XCTAssertEqual(input.resolvedTurn, .off)
        XCTAssertEqual(input.resolvedTurnHand, .right)
        XCTAssertEqual(input.resolvedJoystickSensitivity, 1)
    }

    /// `GameProfiles.saved()` decodes the whole dictionary at once, so one unreadable
    /// value must cost only that field — not every title's settings.
    func testUnknownValueDropsOnlyThatField() throws {
        let profiles = try decodeProfiles("""
            {
              "a.exe": {"input": {"locomotion": "teleport", "turn": "snap"}, "graphics": {}},
              "b.exe": {"input": {"emulateControllers": false}, "graphics": {}}
            }
            """)
        XCTAssertNil(profiles["a.exe"]?.input.locomotion)
        XCTAssertEqual(profiles["a.exe"]?.input.turn, .snap)
        XCTAssertEqual(profiles["b.exe"]?.input.emulateControllers, false)
    }

    func testNewFieldsRoundTrip() throws {
        var profile = GameProfile()
        profile.input = GameInput(locomotion: .armSwing, joystickSensitivity: 1.3,
                                  turn: .smooth, turnHand: .left)
        let data = try JSONEncoder().encode(["x.exe": profile])
        let decoded = try JSONDecoder().decode([String: GameProfile].self, from: data)
        XCTAssertEqual(decoded["x.exe"], profile)
    }

    func testSensitivityIsClampedWhenResolved() {
        XCTAssertEqual(GameInput(joystickSensitivity: 9).resolvedJoystickSensitivity, 1.5)
        XCTAssertEqual(GameInput(joystickSensitivity: 0).resolvedJoystickSensitivity, 0.5)
        XCTAssertEqual(GameInput(joystickSensitivity: .nan).resolvedJoystickSensitivity, 1)
    }

    /// The saved layer keeps only what differs, so a title set back to every default
    /// empties out and is removed rather than shadowing the shipped layer.
    func testDefaultsNormaliseToEmpty() {
        var input = GameInput(emulateControllers: true, locomotion: .pinchJoystick,
                              joystickSensitivity: 1, turn: .off, turnHand: .right)
        XCTAssertFalse(input.isEmpty)
        input.dropDefaults()
        XCTAssertTrue(input.isEmpty)
    }
}

// MARK: - Mapping precedence

final class GestureMappingPrecedenceTests: XCTestCase {

    private var edited: GestureControllerMapping {
        var m = GestureControllerMapping.defaults
        m.set(.grip, for: .right, finger: .ring)
        return m
    }

    func testTitleWithoutOverrideFollowsGlobalEdits() {
        let input = GameInput()
        XCTAssertEqual(input.effectiveMapping(global: .defaults), .defaults)
        // A global edit is picked up, because the title stores nothing of its own.
        XCTAssertEqual(input.effectiveMapping(global: edited), edited)
    }

    func testTitleOverrideWinsOverGlobal() {
        var input = GameInput()
        input.setMappingOverride(edited, global: .defaults)
        XCTAssertEqual(input.gestureMapping, edited)
        XCTAssertEqual(input.effectiveMapping(global: .defaults), edited)
    }

    /// Editing a title back to the global map clears the override, so the title goes
    /// back to following global edits instead of freezing a copy of today's.
    func testOverrideEqualToGlobalIsNotStored() {
        var input = GameInput()
        input.setMappingOverride(edited, global: .defaults)
        input.setMappingOverride(.defaults, global: .defaults)
        XCTAssertNil(input.gestureMapping)
        input.setMappingOverride(edited, global: edited)
        XCTAssertNil(input.gestureMapping)
    }

    func testClearingOverride() {
        var input = GameInput(gestureMapping: edited)
        input.setMappingOverride(nil, global: .defaults)
        XCTAssertNil(input.gestureMapping)
        XCTAssertTrue(input.isEmpty)
    }
}

// MARK: - Joystick settings

final class PCVRJoystickSettingsTests: XCTestCase {

    /// At the default sensitivity the joystick is exactly RAVEInput's own tuning.
    func testDefaultSensitivityIsRAVEDefaults() {
        let settings = PCVRJoystickSettings(sensitivity: 1)
        XCTAssertEqual(settings.holdThreshold, RAVEPinchTuning.joystick.holdThreshold, accuracy: 1e-9)
        XCTAssertEqual(settings.deadzoneMeters, 0.03, accuracy: 1e-6)
        XCTAssertEqual(settings.fullScaleMeters, 0.18, accuracy: 1e-6)
        XCTAssertEqual(settings.pinchTuning.candidateFingers, [.index])
    }

    func testSteadierIsSlowerAndWider() {
        let steady = PCVRJoystickSettings(sensitivity: 0.5)
        let quick = PCVRJoystickSettings(sensitivity: 1.5)
        XCTAssertGreaterThan(steady.holdThreshold, quick.holdThreshold)
        XCTAssertGreaterThan(steady.deadzoneMeters, quick.deadzoneMeters)
        XCTAssertGreaterThan(steady.fullScaleMeters, quick.fullScaleMeters)
        // Out-of-range values clamp rather than extrapolate.
        XCTAssertEqual(PCVRJoystickSettings(sensitivity: 5), quick)
    }
}

// MARK: - Gesture turn

final class GestureTurnTests: XCTestCase {

    private let right = SIMD3<Float>(1, 0, 0)
    private let origin = SIMD3<Float>(0.2, 1.0, -0.4)
    private let frame: TimeInterval = 1.0 / 90

    /// Run `seconds` of frames with a fixed input, returning every output.
    @discardableResult
    private func run(_ turn: inout GestureTurn, mode: GameTurnMode = .snap,
                     from start: TimeInterval, seconds: TimeInterval,
                     clutch: Bool, allowed: Bool = true,
                     sideways: Float) -> (outputs: [GestureTurn.Output], end: TimeInterval) {
        var t = start
        var outputs: [GestureTurn.Output] = []
        while t < start + seconds - 1e-9 {
            outputs.append(turn.update(mode: mode, clutchHeld: clutch, allowed: allowed,
                                       wrist: origin + right * sideways, right: right, now: t))
            t += frame
        }
        return (outputs, t)
    }

    func testOffNeverTurns() {
        var turn = GestureTurn()
        let r = run(&turn, mode: .off, from: 0, seconds: 1, clutch: true, sideways: 0.2)
        XCTAssertTrue(r.outputs.allSatisfy { $0.stickX == 0 && !$0.engaged })
    }

    /// Moving the hand without holding the clutch long enough does nothing — a pinch that
    /// happens on the way to something else is not a turn.
    func testShortClutchDoesNotEngage() {
        var turn = GestureTurn()
        let r = run(&turn, from: 0, seconds: 0.15, clutch: true, sideways: 0)
        XCTAssertFalse(r.outputs.contains { $0.engaged })
        let moved = run(&turn, from: r.end, seconds: 0.04, clutch: true, sideways: 0.08)
        XCTAssertTrue(moved.outputs.allSatisfy { $0.stickX == 0 })
    }

    /// Travel only counts from where the clutch engaged: a hand already off to the side
    /// when it engages anchors there and does not fire.
    func testTravelIsMeasuredFromTheEngagePoint() {
        var turn = GestureTurn()
        let r = run(&turn, from: 0, seconds: 0.5, clutch: true, sideways: 0.3)
        XCTAssertTrue(r.outputs.contains { $0.engaged })
        XCTAssertTrue(r.outputs.allSatisfy { $0.fired == 0 && $0.stickX == 0 })
    }

    func testSnapFiresOnePulseOfFixedLength() {
        var turn = GestureTurn()
        let engage = run(&turn, from: 0, seconds: 0.3, clutch: true, sideways: 0)
        XCTAssertTrue(engage.outputs.last?.engaged == true)

        // 6 cm to the right: past the 5 cm engage.
        let flick = run(&turn, from: engage.end, seconds: 0.5, clutch: true, sideways: 0.06)
        XCTAssertEqual(flick.outputs.filter { $0.fired != 0 }.map(\.fired), [1])
        let deflected = flick.outputs.filter { $0.stickX == 1 }.count
        let expected = Int((GestureTurn.pulseDuration / frame).rounded())
        XCTAssertEqual(Double(deflected), Double(expected), accuracy: 1)
        // And back to rest afterwards, while still held out: one flick, one step.
        XCTAssertEqual(flick.outputs.last?.stickX, 0)
    }

    /// The detector re-arms only once the hand comes back under 3 cm.
    func testSnapNeedsToReturnBeforeFiringAgain() {
        var turn = GestureTurn()
        var r = run(&turn, from: 0, seconds: 0.3, clutch: true, sideways: 0)
        r = run(&turn, from: r.end, seconds: 0.3, clutch: true, sideways: 0.06)
        // Drift down to 4 cm: still inside the hysteresis band.
        let band = run(&turn, from: r.end, seconds: 0.3, clutch: true, sideways: 0.04)
        XCTAssertTrue(band.outputs.allSatisfy { $0.fired == 0 })
        // Back to centre, then out the other way: a second, leftward step.
        let back = run(&turn, from: band.end, seconds: 0.3, clutch: true, sideways: 0)
        let left = run(&turn, from: back.end, seconds: 0.3, clutch: true, sideways: -0.07)
        XCTAssertEqual(left.outputs.filter { $0.fired != 0 }.map(\.fired), [-1])
        XCTAssertTrue(left.outputs.contains { $0.stickX == -1 })
    }

    /// A pulse that began runs its whole length even if the clutch opens mid-flick.
    func testPulseSurvivesClutchRelease() {
        var turn = GestureTurn()
        var r = run(&turn, from: 0, seconds: 0.3, clutch: true, sideways: 0)
        let fire = turn.update(mode: .snap, clutchHeld: true, allowed: true,
                               wrist: origin + right * 0.06, right: right, now: r.end)
        XCTAssertEqual(fire.fired, 1)
        r = run(&turn, from: r.end + frame, seconds: 0.05, clutch: false, sideways: 0.06)
        XCTAssertTrue(r.outputs.allSatisfy { $0.stickX == 1 })
        let after = run(&turn, from: r.end + 0.1, seconds: 0.05, clutch: false, sideways: 0.06)
        XCTAssertTrue(after.outputs.allSatisfy { $0.stickX == 0 && !$0.engaged })
    }

    /// Something else owning the hand (arm swing, the joystick, the HUD) keeps the clutch
    /// from engaging at all.
    func testDisallowedClutchNeverEngages() {
        var turn = GestureTurn()
        let r = run(&turn, from: 0, seconds: 1, clutch: true, allowed: false, sideways: 0.1)
        XCTAssertTrue(r.outputs.allSatisfy { !$0.engaged && $0.stickX == 0 })
    }

    func testSmoothIsProportionalWithADeadzone() {
        var turn = GestureTurn()
        var r = run(&turn, mode: .smooth, from: 0, seconds: 0.3, clutch: true, sideways: 0)
        // 1.5 cm: inside the 2 cm deadzone.
        r = run(&turn, mode: .smooth, from: r.end, seconds: 0.1, clutch: true, sideways: 0.015)
        XCTAssertEqual(r.outputs.last?.stickX, 0)
        // 6 cm: halfway through the active range.
        r = run(&turn, mode: .smooth, from: r.end, seconds: 0.1, clutch: true, sideways: 0.06)
        XCTAssertEqual(try XCTUnwrap(r.outputs.last).stickX, 0.5, accuracy: 0.01)
        // Well past full travel: clamped.
        r = run(&turn, mode: .smooth, from: r.end, seconds: 0.1, clutch: true, sideways: -0.3)
        XCTAssertEqual(try XCTUnwrap(r.outputs.last).stickX, -1, accuracy: 1e-5)
        // Let go: nothing lingers in smooth mode.
        r = run(&turn, mode: .smooth, from: r.end, seconds: 0.05, clutch: false, sideways: -0.3)
        XCTAssertEqual(r.outputs.last?.stickX, 0)
    }
}

// MARK: - Hand ownership

final class PCVRGestureArbiterTests: XCTestCase {

    typealias Input = PCVRGestureArbiter.Input

    /// A jogging fist's finger shapes press nothing, and the pinch it passes through as
    /// the fist opens stays refused until it is let go — it does not fire late.
    func testSwingingHandPressesNoButtons() {
        var arbiter = PCVRGestureArbiter()
        var out = arbiter.resolve(Input(swingingLeft: true, swingingRight: true), now: 0)
        XCTAssertFalse(out.swingBlocked)
        XCTAssertTrue(arbiter.isBusy(.right))

        out = arbiter.resolve(Input(swingingLeft: true, swingingRight: true,
                                    rightButtonHeld: true), now: 0.1)
        XCTAssertFalse(out.rightButtonsAllowed)

        // The swing ends with the pinch still held: still refused, holdoff or not.
        out = arbiter.resolve(Input(rightButtonHeld: true), now: 0.2)
        XCTAssertFalse(out.rightButtonsAllowed)
        out = arbiter.resolve(Input(rightButtonHeld: true), now: 1.0)
        XCTAssertFalse(out.rightButtonsAllowed)

        // Released and pinched again, after the holdoff: a real press.
        _ = arbiter.resolve(Input(), now: 1.1)
        out = arbiter.resolve(Input(rightButtonHeld: true), now: 1.2)
        XCTAssertTrue(out.rightButtonsAllowed)
    }

    /// Opening the fists at the end of a jog passes through pinch shapes; the holdoff
    /// covers the moment right after the swing lets go.
    func testHoldoffAfterSwingRelease() {
        var arbiter = PCVRGestureArbiter()
        _ = arbiter.resolve(Input(swingingRight: true), now: 0)
        _ = arbiter.resolve(Input(), now: 0.5)
        let early = arbiter.resolve(Input(rightButtonHeld: true), now: 0.6)
        XCTAssertFalse(early.rightButtonsAllowed)
        _ = arbiter.resolve(Input(), now: 0.65)
        let late = arbiter.resolve(Input(rightButtonHeld: true), now: 0.8)
        XCTAssertTrue(late.rightButtonsAllowed)
    }

    /// A pinch held before the swing started keeps its hand: equal priority, first wins.
    func testHeldPinchBlocksTheSwingOnItsHand() {
        var arbiter = PCVRGestureArbiter()
        var out = arbiter.resolve(Input(rightButtonHeld: true), now: 0)
        XCTAssertTrue(out.rightButtonsAllowed)
        out = arbiter.resolve(Input(swingingRight: true, rightButtonHeld: true), now: 0.1)
        XCTAssertTrue(out.rightButtonsAllowed)
        XCTAssertTrue(out.swingBlocked)
        // With the other hand free, the swing is not blocked outright.
        out = arbiter.resolve(Input(swingingLeft: true, swingingRight: true,
                                    rightButtonHeld: true), now: 0.2)
        XCTAssertFalse(out.swingBlocked)
        XCTAssertTrue(out.rightButtonsAllowed)
    }

    /// The joystick outranks arm swing on the left hand.
    func testJoystickPreemptsArmSwing() {
        var arbiter = PCVRGestureArbiter()
        _ = arbiter.resolve(Input(swingingLeft: true), now: 0)
        XCTAssertEqual(arbiter.ownership.owner(of: .left), .armSwing)
        let out = arbiter.resolve(Input(joystickEngaged: true, swingingLeft: true), now: 0.1)
        XCTAssertEqual(arbiter.ownership.owner(of: .left), .joystick)
        XCTAssertTrue(out.swingBlocked)
        XCTAssertFalse(arbiter.allowsTurn(on: .left))
    }

    func testTurnClutchFollowsTheTurnHand() {
        var arbiter = PCVRGestureArbiter()
        _ = arbiter.resolve(Input(turnEngaged: true, turnHand: .right), now: 0)
        XCTAssertEqual(arbiter.ownership.owner(of: .right), .turnClutch)
        XCTAssertTrue(arbiter.isBusy(.right))
        XCTAssertTrue(arbiter.allowsTurn(on: .right))
        // Moving the setting to the left hand releases the right-hand claim.
        _ = arbiter.resolve(Input(turnEngaged: false, turnHand: .left), now: 0.1)
        XCTAssertNil(arbiter.ownership.owner(of: .right))
    }

    /// Button pinches alone never make a hand "busy" — the wrist HUD may still open.
    func testButtonsDoNotMakeAHandBusy() {
        var arbiter = PCVRGestureArbiter()
        _ = arbiter.resolve(Input(leftButtonHeld: true), now: 0)
        XCTAssertFalse(arbiter.isBusy(.left))
    }
}
#endif
