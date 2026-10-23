#if MOONLIGHT_ENABLED
import DebugTrace
import Foundation
import GameController
import CoreHaptics
import RAVEInput
@preconcurrency import MoonlightCommonC

/// Bridges the app's gamepads to one Moonlight session.
/// Pads come from `GamepadRoster`, which claims them for every reader at once; this
/// maps their snapshots to moonlight-common-c controller events (`MoonlightGamepadMapping`)
/// and passes motion through when the host asks for it.
@Observable
class MoonlightGamepadManager: @unchecked Sendable {

    /// The session's copy of moonlight-common-c — controller events go to it.
    let library: MoonlightLibrary

    /// Whether A/B and X/Y buttons should be swapped (Nintendo layout).
    let swapABXY: Bool

    /// GameController delivers every pad to every listening session, so only
    /// the session holding input focus forwards state (see
    /// `MoonlightInputFocus`). Losing focus sends a neutral state so a button
    /// held at the moment of the switch is not left down on that host.
    private var focusObserver: NSObjectProtocol?

    @ObservationIgnored
    private var subscription: GamepadRoster.Subscription?

    /// Motion reports the host asked for, per pad and sensor. Polled on a timer at the
    /// host's rate, as moonlight-ios does, rather than on every sensor callback: the
    /// host names the rate it can use, and a pad's IMU reports far faster.
    @ObservationIgnored
    private var motionTimers: [MotionKey: Timer] = [:]
    @ObservationIgnored
    private var lastMotionSample: [MotionKey: SIMD3<Float>] = [:]

    private struct MotionKey: Hashable {
        let slot: Int
        let type: UInt8
    }

    private var roster: GamepadRoster { .shared }

    init(library: MoonlightLibrary, swapABXY: Bool = false) {
        self.library = library
        self.swapABXY = swapABXY
    }

    // MARK: - Lifecycle

    func startListening() {
        AppLog.gamepadManager.log("Starting controller listening")

        focusObserver = NotificationCenter.default.addObserver(
            forName: MoonlightInputFocus.didChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? Int) == self.library.slot else { return }
            self.releaseAllControllers()
        }

        subscription = roster.subscribe(
            connected: { [weak self] slot, controller in self?.controllerConnected(controller, slot: slot) },
            disconnected: { [weak self] slot, controller in self?.controllerDisconnected(controller, slot: slot) },
            changed: { [weak self] slot, snapshot in self?.sendControllerState(snapshot, controllerNumber: slot) }
        )
    }

    /// Neutral state for every attached pad — the focus just moved to another
    /// session, and whatever was pressed here must not stay pressed.
    private func releaseAllControllers() {
        for slot in roster.controllers.keys {
            sendNeutral(controllerNumber: slot, activeGamepadMask: roster.activeMask)
        }
    }

    func stopListening() {
        AppLog.gamepadManager.log("Stopping controller listening")

        if let obs = focusObserver {
            NotificationCenter.default.removeObserver(obs)
            focusObserver = nil
        }
        stopAllMotion()

        // Zero state for every pad, removing each from the mask in turn, so the host
        // ends with no controllers attached.
        var mask = roster.activeMask
        for slot in roster.controllers.keys.sorted() {
            mask &= ~UInt16(1 << slot)
            sendNeutral(controllerNumber: slot, activeGamepadMask: mask)
        }
        if let subscription {
            roster.unsubscribe(subscription)
            self.subscription = nil
        }
    }

    // MARK: - Controller Connect/Disconnect

    private func controllerConnected(_ controller: GCController, slot: Int) {
        let controllerType = detectControllerType(controller)
        let capabilities = detectCapabilities(controller)
        let supportedButtons = buildSupportedButtonFlags()

        AppLog.gamepadManager.log("Controller \(slot) connected: \(controller.vendorName ?? "unknown"), type=\(controllerType), caps=0x\(String(capabilities, radix: 16), privacy: .public)")

        // Notify host of controller arrival
        library.sendControllerArrival(
            controllerNumber: UInt8(slot),
            activeGamepadMask: roster.activeMask,
            type: controllerType,
            supportedButtonFlags: supportedButtons,
            capabilities: capabilities
        )
    }

    private func controllerDisconnected(_ controller: GCController, slot: Int) {
        AppLog.gamepadManager.log("Controller \(slot) disconnected: \(controller.vendorName ?? "unknown")")
        for key in motionTimers.keys where key.slot == slot { stopMotion(key) }
        // Zero-state removal event; the roster's mask no longer has this slot.
        sendNeutral(controllerNumber: slot, activeGamepadMask: roster.activeMask)
    }

    // MARK: - Input Handling

    private func sendControllerState(_ snapshot: RAVEGamepadSnapshot, controllerNumber: Int) {
        // Another session is the one being played; this pad's state is its business.
        guard MoonlightInputFocus.owns(library.slot) else { return }
        let state = MoonlightGamepadMapping.state(snapshot, swapABXY: swapABXY)
        library.sendMultiController(
            controllerNumber: Int16(controllerNumber),
            activeGamepadMask: Int16(bitPattern: roster.activeMask),
            buttonFlags: state.buttonFlags,
            leftTrigger: state.leftTrigger,
            rightTrigger: state.rightTrigger,
            leftStickX: state.leftStickX,
            leftStickY: state.leftStickY,
            rightStickX: state.rightStickX,
            rightStickY: state.rightStickY
        )
    }

    private func sendNeutral(controllerNumber: Int, activeGamepadMask: UInt16) {
        library.sendMultiController(
            controllerNumber: Int16(controllerNumber), activeGamepadMask: Int16(bitPattern: activeGamepadMask),
            buttonFlags: 0, leftTrigger: 0, rightTrigger: 0,
            leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0
        )
    }

    // MARK: - Motion

    /// The host's `setMotionEventState` callback (off main thread): start reporting one
    /// sensor of one pad at `reportRateHz`, or stop when the rate is 0. Sunshine asks
    /// when the controller it emulates has motion (a DualShock 4 with `motion_as_ds4`)
    /// and the arrival event said the pad has the sensor.
    nonisolated func setMotionEventState(controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        Task { @MainActor [weak self] in
            self?.updateMotion(slot: Int(controllerNumber), type: motionType, rate: reportRateHz)
        }
    }

    private func updateMotion(slot: Int, type: UInt8, rate: UInt16) {
        let key = MotionKey(slot: slot, type: type)
        stopMotion(key)
        guard rate > 0, let subscription, let motion = roster.controllers[slot]?.motion else { return }
        switch Int32(type) {
        case LI_MOTION_TYPE_GYRO where motion.hasRotationRate: break
        case LI_MOTION_TYPE_ACCEL where motion.hasGravityAndUserAcceleration: break
        default: return
        }
        roster.setMotionWanted(true, slot: slot, by: subscription)
        motionTimers[key] = Timer.scheduledTimer(withTimeInterval: 1 / Double(rate), repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.sendMotion(key) }
        }
        AppLog.gamepadManager.log("Controller \(slot) motion type \(type, privacy: .public) on at \(rate, privacy: .public) Hz")
    }

    private func sendMotion(_ key: MotionKey) {
        guard MoonlightInputFocus.owns(library.slot), let snapshot = roster.snapshot(slot: key.slot) else { return }
        let sample: SIMD3<Float>?
        switch Int32(key.type) {
        case LI_MOTION_TYPE_GYRO: sample = snapshot.rotationRate.map(MoonlightGamepadMapping.gyro)
        case LI_MOTION_TYPE_ACCEL: sample = snapshot.acceleration.map(MoonlightGamepadMapping.acceleration)
        default: sample = nil
        }
        // An unchanged reading is a sensor that has not updated since the last tick.
        guard let sample, sample != lastMotionSample[key] else { return }
        lastMotionSample[key] = sample
        library.sendControllerMotion(controllerNumber: UInt8(key.slot), motionType: key.type,
                                     x: sample.x, y: sample.y, z: sample.z)
    }

    private func stopMotion(_ key: MotionKey) {
        motionTimers.removeValue(forKey: key)?.invalidate()
        lastMotionSample[key] = nil
        guard let subscription, !motionTimers.keys.contains(where: { $0.slot == key.slot }) else { return }
        roster.setMotionWanted(false, slot: key.slot, by: subscription)
    }

    private func stopAllMotion() {
        for key in Array(motionTimers.keys) { stopMotion(key) }
    }

    // MARK: - Rumble

    /// Called from the bridge rumble callback (off main thread).
    nonisolated func handleRumble(controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
        let index = Int(controllerNumber)
        Task { @MainActor in
            guard let controller = GamepadRoster.shared.controllers[index],
                  let haptics = controller.haptics else { return }

            let lowIntensity = Float(lowFreqMotor) / Float(UInt16.max)
            let highIntensity = Float(highFreqMotor) / Float(UInt16.max)
            let intensity = max(lowIntensity, highIntensity)

            guard intensity > 0 else { return }

            do {
                guard let engine = haptics.createEngine(withLocality: .default) else { return }
                try engine.start()
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: highIntensity / max(intensity, 0.001))
                    ],
                    relativeTime: 0,
                    duration: 0.1
                )
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {
                // Haptics not available on this controller
            }
        }
    }

    // MARK: - Helpers

    private func detectControllerType(_ controller: GCController) -> UInt8 {
        if let _ = controller.physicalInputProfile as? GCXboxGamepad {
            return UInt8(LI_CTYPE_XBOX)
        } else if let _ = controller.physicalInputProfile as? GCDualSenseGamepad {
            return UInt8(LI_CTYPE_PS)
        } else if let _ = controller.physicalInputProfile as? GCDualShockGamepad {
            return UInt8(LI_CTYPE_PS)
        } else {
            // Default to Nintendo for Switch Pro and other controllers
            return UInt8(LI_CTYPE_NINTENDO)
        }
    }

    private func detectCapabilities(_ controller: GCController) -> UInt16 {
        var caps: UInt16 = 0

        // All extended gamepads have analog triggers
        caps |= UInt16(LI_CCAP_ANALOG_TRIGGERS)

        // Check for haptics/rumble support
        if controller.haptics != nil {
            caps |= UInt16(LI_CCAP_RUMBLE)
        }

        // Motion sensors, reported through setMotionEventState once the host asks.
        if let motion = controller.motion {
            if motion.hasRotationRate { caps |= UInt16(LI_CCAP_GYRO) }
            if motion.hasGravityAndUserAcceleration { caps |= UInt16(LI_CCAP_ACCEL) }
        }

        return caps
    }

    private func buildSupportedButtonFlags() -> UInt32 {
        // Report all standard buttons as supported
        return UInt32(A_FLAG) | UInt32(B_FLAG) | UInt32(X_FLAG) | UInt32(Y_FLAG) |
               UInt32(UP_FLAG) | UInt32(DOWN_FLAG) | UInt32(LEFT_FLAG) | UInt32(RIGHT_FLAG) |
               UInt32(LB_FLAG) | UInt32(RB_FLAG) |
               UInt32(LS_CLK_FLAG) | UInt32(RS_CLK_FLAG) |
               UInt32(PLAY_FLAG) | UInt32(BACK_FLAG) | UInt32(SPECIAL_FLAG)
    }
}

/// A gamepad snapshot in moonlight-common-c's terms. Pure, so the mapping is pinned by
/// tests rather than by a host on the other end.
enum MoonlightGamepadMapping {

    struct State: Equatable {
        var buttonFlags: Int32
        var leftTrigger: UInt8
        var rightTrigger: UInt8
        var leftStickX: Int16
        var leftStickY: Int16
        var rightStickX: Int16
        var rightStickY: Int16
    }

    nonisolated static func state(_ pad: RAVEGamepadSnapshot, swapABXY: Bool) -> State {
        var buttonFlags: Int32 = 0
        func flag(_ button: RAVEGamepadSnapshot.Buttons, _ value: Int32) {
            if pad.buttons.contains(button) { buttonFlags |= value }
        }

        // Face buttons, swapped A↔B and X↔Y for a Nintendo layout.
        flag(swapABXY ? .b : .a, Int32(A_FLAG))
        flag(swapABXY ? .a : .b, Int32(B_FLAG))
        flag(swapABXY ? .y : .x, Int32(X_FLAG))
        flag(swapABXY ? .x : .y, Int32(Y_FLAG))

        flag(.dpadUp, Int32(UP_FLAG))
        flag(.dpadDown, Int32(DOWN_FLAG))
        flag(.dpadLeft, Int32(LEFT_FLAG))
        flag(.dpadRight, Int32(RIGHT_FLAG))
        flag(.leftShoulder, Int32(LB_FLAG))
        flag(.rightShoulder, Int32(RB_FLAG))
        flag(.leftStick, Int32(LS_CLK_FLAG))
        flag(.rightStick, Int32(RS_CLK_FLAG))
        flag(.menu, Int32(PLAY_FLAG))
        flag(.options, Int32(BACK_FLAG))
        flag(.home, Int32(SPECIAL_FLAG))

        // Sticks: −1…1 → Int16; triggers: 0…1 → UInt8.
        func axis(_ value: Float) -> Int16 { Int16(clamping: Int32(value * 0x7FFE)) }
        func trigger(_ value: Float) -> UInt8 { UInt8(clamping: Int32(value * 0xFF)) }
        return State(buttonFlags: buttonFlags,
                     leftTrigger: trigger(pad.leftTrigger), rightTrigger: trigger(pad.rightTrigger),
                     leftStickX: axis(pad.leftStick.x), leftStickY: axis(pad.leftStick.y),
                     rightStickX: axis(pad.rightStick.x), rightStickY: axis(pad.rightStick.y))
    }

    /// GameController rotation rate (rad/s) → the deg/s and axes `LiSendControllerMotionEvent`
    /// expects. The axis order is moonlight-ios's (`ControllerSupport.m`), the reference
    /// client against Sunshine.
    nonisolated static func gyro(_ radiansPerSecond: SIMD3<Float>) -> SIMD3<Float> {
        let degrees: Float = 57.2957795
        return SIMD3(radiansPerSecond.x * degrees,
                     radiansPerSecond.z * degrees,
                     radiansPerSecond.y * -degrees)
    }

    /// GameController total acceleration (g) → m/s², sign-flipped as moonlight-ios does.
    nonisolated static func acceleration(_ g: SIMD3<Float>) -> SIMD3<Float> {
        g * -9.80665
    }
}
#endif
