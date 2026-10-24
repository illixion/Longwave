import DebugTrace
import Foundation
import GameController
import RAVEInput
#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
/// Registered only when the debug server runs (`DebugTraceServer.requestedAtLaunch`): a
/// development build build-and-sign signed, never App Store or TestFlight. Driving a
/// remote PC's input from the network is not something a shipped build may offer.
/// A compile-time `#if DEBUG` would be the wrong gate: device builds are Release.
@MainActor
enum GamepadDebugEndpoints {

    static func register() {
        // Restores a visualizer left on, and with it the delivery log, from launch rather
        // than from whenever a stream view first draws.
        _ = GamepadVisualizer.shared
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
            .command("gamepadMotion",
                     "Ask for (on) or stop asking for (off) a pad's motion sensors, as one more reader would. For diagnosing a sensor that reads still: compare sensorsActive and the rotation rate in gamepads before and after",
                     parameters: [
                        .integer("slot", "the pad's slot", required: true, range: 0...(GamepadRoster.slotCount - 1)),
                        .boolean("on", "true to ask for the sensors, false to drop this request", required: true),
                        .boolean("reassert", "also switch the IMU off and straight back on (sensorsActive false → true)", default: false),
                        .boolean("handler", "install (true) or remove (false) a GCMotion valueChangedHandler that counts samples (gamepads: motionCallbacks, secondsSinceMotionCallback), which also tests whether visionOS wants a motion consumer"),
                        .boolean("monitorBackground", "set GCController.shouldMonitorBackgroundEvents (the header documents it as ignored on iOS and tvOS only)"),
                     ]) { args in
                let slot = try args.requireInt("slot")
                let on = try args.requireBool("on")
                let roster = GamepadRoster.shared
                // The roster claims pads only while someone reads them, so with no stream
                // running there is nothing in any slot until this reader subscribes.
                if on, motionSubscription == nil {
                    motionSubscription = roster.subscribe(connected: { _, _ in }, disconnected: { _, _ in })
                }
                guard let controller = roster.controllers[slot] else {
                    if let subscription = motionSubscription,
                       !(0..<GamepadRoster.slotCount).contains(where: { roster.hasMotionRequest(slot: $0, by: subscription) }) {
                        roster.unsubscribe(subscription)
                        motionSubscription = nil
                    }
                    throw DebugError.invalidArgument("slot \(slot) holds no pad",
                                                     hint: "GET gamepads lists the occupied slots")
                }
                if let monitor = args.bool("monitorBackground") {
                    GCController.shouldMonitorBackgroundEvents = monitor
                }
                if let motion = controller.motion {
                    if let handler = args.bool("handler") {
                        motionCallbacks[slot] = handler ? MotionCallbacks() : nil
                        motion.valueChangedHandler = handler ? { _ in
                            MainActor.assumeIsolated {
                                motionCallbacks[slot]?.count += 1
                                motionCallbacks[slot]?.last = Date()
                            }
                        } : nil
                        motionHandlerInstalled[slot] = handler
                    }
                    if args.bool("reassert") == true {
                        motion.sensorsActive = false
                        motion.sensorsActive = true
                    }
                }
                if on, let subscription = motionSubscription {
                    roster.setMotionWanted(true, slot: slot, by: subscription)
                } else if let subscription = motionSubscription {
                    roster.setMotionWanted(false, slot: slot, by: subscription)
                    // Nothing left asked for: stop being a reader, so the roster can let
                    // the pads go once the real readers do.
                    if !(0..<GamepadRoster.slotCount).contains(where: { roster.hasMotionRequest(slot: $0, by: subscription) }) {
                        roster.unsubscribe(subscription)
                        motionSubscription = nil
                    }
                }
                return status()
            },
            .command("gamepadVisualizer",
                     "Show (on) or hide (off) the live gamepad drawing: in the Moonlight stream window's corner and on a panel in the PCVR immersive space. It only reads what the roster holds; gamepads then reports the change ages it measured (visualizer)",
                     parameters: [
                        .boolean("on", "true to show it, false to hide it", required: true),
                     ]) { args in
                let on = try args.requireBool("on")
                GamepadVisualizer.shared.isShown = on
                GamepadRoster.shared.recordsDeliveries = on
                return status()
            },
            .query("gamepadDeliveries",
                   "When GameController delivered each pad input change, as counts per second over the last `seconds`, newest last, with the UTC second each bucket starts. Recorded only since gamepadDeliveries record=true (or while the visualizer is shown). Line it up with the system log's `_GCControllerManagerAppClient … env: keyboardFocus` policy changes to see where input went",
                   parameters: [
                    .integer("seconds", "how far back", default: 60, range: 1...600),
                   ]) { args in
                deliveries(seconds: args.int("seconds") ?? 60)
            },
            .command("gamepadDeliveriesRecord",
                     "Start (on) or stop and clear (off) recording when GameController delivers each pad input change",
                     parameters: [.boolean("on", "true to record, false to stop and clear", required: true)]) { args in
                GamepadRoster.shared.recordsDeliveries = try args.requireBool("on")
                return deliveries(seconds: 10)
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

    /// The debug server's own reader, held only while `gamepadMotion` has asked for a
    /// pad's sensors.
    private static var motionSubscription: GamepadRoster.Subscription?
    /// Slots whose GCMotion got an empty handler from `gamepadMotion handler=true`.
    private static var motionHandlerInstalled: [Int: Bool] = [:]
    /// Samples the counting handler has seen per slot, since it was installed: the
    /// direct answer to "is the IMU streaming", where a reading alone can be stale.
    private struct MotionCallbacks { var count = 0; var last: Date? }
    private static var motionCallbacks: [Int: MotionCallbacks] = [:]

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

    // MARK: Deliveries

    struct Deliveries: Encodable {
        var recording: Bool
        var slots: [SlotDeliveries]
    }

    struct SlotDeliveries: Encodable {
        var slot: Int
        var total: Int
        /// UTC second each `perSecond` bucket starts at, oldest first.
        var since: String
        var perSecond: [Int]
        var last: String?
    }

    private static func deliveries(seconds: Int) -> Deliveries {
        let roster = GamepadRoster.shared
        let now = Date()
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 - Double(seconds - 1)).rounded(.down))
        let format = ISO8601DateFormatter()
        let slots = roster.deliveries.keys.sorted().map { slot -> SlotDeliveries in
            let log = roster.deliveries[slot] ?? []
            var buckets = [Int](repeating: 0, count: seconds)
            for time in log where time >= start {
                let index = Int(time.timeIntervalSince(start))
                if index < seconds { buckets[index] += 1 }
            }
            return SlotDeliveries(slot: slot, total: log.count, since: format.string(from: start),
                                  perSecond: buckets, last: log.last.map(format.string))
        }
        return Deliveries(recording: roster.recordsDeliveries, slots: slots)
    }

    // MARK: Status

    struct Status: Encodable {
        var subscriberCount: Int
        var pads: [Pad]
        var moonlightSessions: [MoonlightSession]
        /// Where GameController routes input depends on which app and scene is in
        /// front, so the readings above are only meaningful next to this.
        var foreground: Foreground
        var visualizer: VisualizerStatus
    }

    struct Foreground: Encodable {
        var applicationState: String
        var shouldMonitorBackgroundEvents: Bool
        var scenes: [Scene]
    }

    struct Scene: Encodable {
        var role: String
        var activationState: String
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
        /// GameController's own view of a physical pad's IMU (nil for a virtual pad).
        var sensorsActive: Bool?
        var sensorsRequireManualActivation: Bool?
        /// Set by `gamepadMotion handler=…`; absent when never touched.
        var debugMotionHandler: Bool?
        /// Samples the counting handler has seen, and how long ago the last one came.
        var motionCallbacks: Int?
        var secondsSinceMotionCallback: Double?
        /// `GCController.current`: the pad the system last saw used.
        var isCurrent: Bool
        /// Measured by the visualizer while it is drawn; absent when it never drew this pad.
        var visualizer: PadActivity?
        var buttons: [String]
        var leftStick: [Float]
        var rightStick: [Float]
        var leftTrigger: Float
        var rightTrigger: Float
        var rotationRateRadPerS: [Float]?
        var accelerationG: [Float]?
    }

    struct PadActivity: Encodable {
        var inputChanges: Int
        var motionChanges: Int
        var secondsSinceInputChange: Double?
        var secondsSinceMotionChange: Double?
        /// How long this controller object has been drawn in its slot (a reconnect resets it).
        var trackedSeconds: Double
    }

    struct VisualizerStatus: Encodable {
        var shown: Bool
        /// Seconds since each place last drew it ("moonlight", "pcvr").
        var secondsSinceDrawn: [String: Double]
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
                sensorsActive: controller.motion?.sensorsActive,
                sensorsRequireManualActivation: controller.motion?.sensorsRequireManualActivation,
                debugMotionHandler: motionHandlerInstalled[slot],
                motionCallbacks: motionCallbacks[slot]?.count,
                secondsSinceMotionCallback: motionCallbacks[slot]?.last.map { -$0.timeIntervalSinceNow },
                isCurrent: GCController.current === controller,
                visualizer: GamepadVisualizer.shared.activity(slot: slot).map { tracked in
                    let now = GamepadVisualizer.now
                    return PadActivity(inputChanges: tracked.activity.inputChanges,
                                       motionChanges: tracked.activity.motionChanges,
                                       secondsSinceInputChange: tracked.activity.secondsSinceInputChange(now: now),
                                       secondsSinceMotionChange: tracked.activity.secondsSinceMotionChange(now: now),
                                       trackedSeconds: now - tracked.trackedSince)
                },
                buttons: buttonNames.filter { snapshot.buttons.contains($0.button) }.map(\.name),
                leftStick: [snapshot.leftStick.x, snapshot.leftStick.y],
                rightStick: [snapshot.rightStick.x, snapshot.rightStick.y],
                leftTrigger: snapshot.leftTrigger, rightTrigger: snapshot.rightTrigger,
                rotationRateRadPerS: snapshot.rotationRate.map { [$0.x, $0.y, $0.z] },
                accelerationG: snapshot.acceleration.map { [$0.x, $0.y, $0.z] })
        }
        return Status(subscriberCount: roster.subscriberCount, pads: pads,
                      moonlightSessions: moonlightSessions(), foreground: foreground(),
                      visualizer: VisualizerStatus(
                        shown: GamepadVisualizer.shared.isShown,
                        secondsSinceDrawn: GamepadVisualizer.shared.drawnAt.mapValues { GamepadVisualizer.now - $0 }))
    }

    private static func foreground() -> Foreground {
        #if os(macOS)
        return Foreground(applicationState: NSApp.isActive ? "active" : "inactive",
                          shouldMonitorBackgroundEvents: GCController.shouldMonitorBackgroundEvents,
                          scenes: [])
        #else
        let state = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let scenes = UIApplication.shared.connectedScenes.map { scene in
            let activation = switch scene.activationState {
            case .foregroundActive: "foregroundActive"
            case .foregroundInactive: "foregroundInactive"
            case .background: "background"
            case .unattached: "unattached"
            @unknown default: "unknown"
            }
            return Scene(role: scene.session.role.rawValue, activationState: activation)
        }
        return Foreground(applicationState: state,
                          shouldMonitorBackgroundEvents: GCController.shouldMonitorBackgroundEvents,
                          scenes: scenes.sorted { ($0.role, $0.activationState) < ($1.role, $1.activationState) })
        #endif
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
