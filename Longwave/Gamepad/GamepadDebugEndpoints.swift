#if DEBUG
import DebugTrace
import Foundation
import GameController
import RAVEInput
#if MOONLIGHT_ENABLED
@preconcurrency import MoonlightCommonC
#endif

/// Debug-server endpoints for the gamepad path: what `GamepadRoster` holds, and virtual
/// pads an agent can drive, so a stream can be tested end to end without a controller.
///
/// The other end is `CompanionWindows/scripts/pad-probe.py` on the streaming PC, which
/// reads the virtual controller Sunshine (or the PCVR broker) presents to games. Set a
/// virtual pad here, read the probe there, compare. What this cannot reach is
/// GameController itself: claiming a real pad, a real IMU's axes, the visionOS stick
/// freeze. Those still need a pad in hand, and `gamepads` shows what one is reporting.
///
/// Debug builds only: driving a remote PC's input from the network is not something a
/// release build may do, debug server or not.
@MainActor
enum GamepadDebugEndpoints {

    static func register() {
        DebugSurface.shared.register([
            .query("gamepads",
                   "Pads GamepadRoster holds (slot = player index = Moonlight controller number), their sensors and live state, and which Moonlight sessions are reading them") { _ in
                status()
            },
            .command("gamepadVirtualAdd",
                     "Add a virtual pad, announced to every reader as a real one would be (Moonlight sends a controller arrival). Needs a Moonlight stream or PCVR session running; returns the status with the new slot",
                     parameters: [
                        .boolean("gyro", "declare a gyroscope (Moonlight reports LI_CCAP_GYRO, so Sunshine emulates a DS4)", default: true),
                        .boolean("accelerometer", "declare an accelerometer (LI_CCAP_ACCEL)", default: true),
                     ]) { args in
                let gyro = args.bool("gyro") ?? true
                let accelerometer = args.bool("accelerometer") ?? true
                guard let slot = GamepadRoster.shared.addVirtualPad(gyro: gyro, accelerometer: accelerometer) else {
                    if GamepadRoster.shared.subscriberCount == 0 {
                        throw DebugError.unavailable(
                            "nothing is reading gamepads, so there is no stream to drive",
                            hint: "start a Moonlight stream or a PCVR session on the headset, then retry")
                    }
                    throw DebugError.unavailable(
                        "all \(GamepadRoster.slotCount) gamepad slots are taken",
                        hint: "remove a virtual pad with gamepadVirtualRemove, or disconnect a controller; GET gamepads lists them")
                }
                return AddReply(slot: slot, status: status())
            },
            .command("gamepadVirtualSet",
                     "Set the whole state of a virtual pad and deliver it as one change. Omitted values are neutral (released, centred, still), so each call states everything held",
                     parameters: [
                        .integer("slot", "the virtual pad's slot, from gamepadVirtualAdd", required: true,
                                 range: 0...(GamepadRoster.slotCount - 1)),
                        .string("buttons", "comma-separated buttons held: \(buttonNames.map(\.name).joined(separator: ", ")) (GameController names: a is Xbox A / Nintendo B position)", default: ""),
                        .number("leftX", "left stick x, +right", default: 0, range: -1...1),
                        .number("leftY", "left stick y, +up", default: 0, range: -1...1),
                        .number("rightX", "right stick x, +right", default: 0, range: -1...1),
                        .number("rightY", "right stick y, +up", default: 0, range: -1...1),
                        .number("leftTrigger", "left trigger", default: 0, range: 0...1),
                        .number("rightTrigger", "right trigger", default: 0, range: 0...1),
                        .number("gyroX", "rotation rate about GameController's x axis, rad/s", default: 0, range: -40...40),
                        .number("gyroY", "rotation rate about y, rad/s", default: 0, range: -40...40),
                        .number("gyroZ", "rotation rate about z, rad/s", default: 0, range: -40...40),
                        .number("accelX", "acceleration along x incl. gravity, g", default: 0, range: -8...8),
                        .number("accelY", "acceleration along y incl. gravity, g", default: 0, range: -8...8),
                        .number("accelZ", "acceleration along z incl. gravity, g (−1 = lying flat at rest)", default: -1, range: -8...8),
                     ]) { args in
                let slot = try args.requireInt("slot")
                let state = try snapshot(from: args)
                guard GamepadRoster.shared.setVirtualPad(slot: slot, to: state) else {
                    throw notVirtual(slot)
                }
                return status()
            },
            .command("gamepadVirtualRemove",
                     "Disconnect a virtual pad, as if unplugged (Moonlight sends its removal)",
                     parameters: [
                        .integer("slot", "the virtual pad's slot", required: true,
                                 range: 0...(GamepadRoster.slotCount - 1)),
                     ]) { args in
                let slot = try args.requireInt("slot")
                guard GamepadRoster.shared.removeVirtualPad(slot: slot) else { throw notVirtual(slot) }
                return status()
            },
        ])
    }

    // MARK: Arguments

    private static let buttonNames: [(name: String, button: RAVEGamepadSnapshot.Buttons)] = [
        ("a", .a), ("b", .b), ("x", .x), ("y", .y),
        ("leftShoulder", .leftShoulder), ("rightShoulder", .rightShoulder),
        ("leftStick", .leftStick), ("rightStick", .rightStick),
        ("menu", .menu), ("options", .options), ("home", .home),
        ("dpadUp", .dpadUp), ("dpadDown", .dpadDown), ("dpadLeft", .dpadLeft), ("dpadRight", .dpadRight),
        // Read back only: a virtual trigger's press follows its value.
        ("leftTrigger", .leftTrigger), ("rightTrigger", .rightTrigger),
    ]

    private static func snapshot(from args: DebugArguments) throws(DebugError) -> RAVEGamepadSnapshot {
        var buttons: RAVEGamepadSnapshot.Buttons = []
        let settable = buttonNames.filter { $0.button != .leftTrigger && $0.button != .rightTrigger }
        for raw in (args.string("buttons") ?? "").split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard let entry = settable.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw DebugError.invalidArgument(
                    "unknown button '\(name)'",
                    hint: "use any of: \(settable.map(\.name).joined(separator: ", ")); triggers are leftTrigger/rightTrigger numbers")
            }
            buttons.insert(entry.button)
        }
        func number(_ name: String, _ fallback: Float = 0) -> Float {
            args.double(name).map(Float.init) ?? fallback
        }
        return RAVEGamepadSnapshot(
            buttons: buttons,
            leftStick: SIMD2(number("leftX"), number("leftY")),
            rightStick: SIMD2(number("rightX"), number("rightY")),
            leftTrigger: number("leftTrigger"), rightTrigger: number("rightTrigger"),
            rotationRate: SIMD3(number("gyroX"), number("gyroY"), number("gyroZ")),
            acceleration: SIMD3(number("accelX"), number("accelY"), number("accelZ", -1)))
    }

    private static func notVirtual(_ slot: Int) -> DebugError {
        DebugError.invalidArgument(
            "slot \(slot) holds no virtual pad",
            hint: "GET gamepads lists the slots (virtual: true marks the ones you can drive); add one with gamepadVirtualAdd")
    }

    // MARK: Status

    struct Status: Encodable {
        var subscriberCount: Int
        var pads: [Pad]
        var moonlightSessions: [MoonlightSession]
    }

    struct AddReply: Encodable {
        var slot: Int
        var status: Status
    }

    struct Pad: Encodable {
        var slot: Int
        var virtual: Bool
        var productCategory: String
        var gyro: Bool
        var accelerometer: Bool
        /// Subscribers that have the pad's motion sensors switched on.
        var motionRequests: Int
        var buttons: [String]
        var leftStick: [Float]
        var rightStick: [Float]
        var leftTrigger: Float
        var rightTrigger: Float
        var rotationRateRadPerS: [Float]?
        var accelerationG: [Float]?
    }

    struct MoonlightSession: Encodable {
        var librarySlot: Int
        var hasInputFocus: Bool
        var motionReports: [MotionReport]
    }

    struct MotionReport: Encodable {
        var padSlot: Int
        var sensor: String
        var rateHz: Int
    }

    private static func status() -> Status {
        let roster = GamepadRoster.shared
        let pads = roster.controllers.keys.sorted().compactMap { slot -> Pad? in
            guard let controller = roster.controllers[slot], let snapshot = roster.snapshot(slot: slot) else { return nil }
            let sensors = roster.motionSensors(slot: slot)
            return Pad(
                slot: slot,
                virtual: roster.isVirtual(slot: slot),
                // A product category, not the vendor name: the name can carry a user-given label.
                productCategory: controller.productCategory,
                gyro: sensors.gyro, accelerometer: sensors.accelerometer,
                motionRequests: roster.motionRequests(slot: slot),
                buttons: buttonNames.filter { snapshot.buttons.contains($0.button) }.map(\.name),
                leftStick: [snapshot.leftStick.x, snapshot.leftStick.y],
                rightStick: [snapshot.rightStick.x, snapshot.rightStick.y],
                leftTrigger: snapshot.leftTrigger, rightTrigger: snapshot.rightTrigger,
                rotationRateRadPerS: snapshot.rotationRate.map { [$0.x, $0.y, $0.z] },
                accelerationG: snapshot.acceleration.map { [$0.x, $0.y, $0.z] })
        }
        return Status(subscriberCount: roster.subscriberCount, pads: pads,
                      moonlightSessions: moonlightSessions())
    }

    private static func moonlightSessions() -> [MoonlightSession] {
        #if MOONLIGHT_ENABLED
        return MoonlightLibrary.all.compactMap { library in
            guard let manager = library.gamepadManager else { return nil }
            let reports = manager.motionReportRates
                .sorted { ($0.key.slot, $0.key.type) < ($1.key.slot, $1.key.type) }
                .map { key, rate in
                    MotionReport(padSlot: key.slot,
                                 sensor: Int32(key.type) == LI_MOTION_TYPE_GYRO ? "gyro" : "accelerometer",
                                 rateHz: Int(rate))
                }
            return MoonlightSession(librarySlot: library.slot,
                                    hasInputFocus: MoonlightInputFocus.owns(library.slot),
                                    motionReports: reports)
        }
        #else
        return []
        #endif
    }
}
#endif
