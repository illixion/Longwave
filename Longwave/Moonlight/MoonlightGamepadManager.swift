#if MOONLIGHT_ENABLED
import Foundation
import os
import GameController
import CoreHaptics
@preconcurrency import MoonlightCommonC

/// Bridges Apple's GameController framework to Moonlight's controller input APIs.
/// Manages up to 4 controllers, mapping GCController inputs to moonlight-common-c events.
@Observable
class MoonlightGamepadManager: @unchecked Sendable {

    /// Whether A/B and X/Y buttons should be swapped (Nintendo layout).
    let swapABXY: Bool

    /// Currently connected controllers, indexed by playerIndex (0-3).
    private var controllers: [Int: GCController] = [:]

    /// Bitmask of active gamepads for LiSendMultiControllerEvent.
    @ObservationIgnored
    private var activeGamepadMask: UInt16 = 0

    /// Observers for connect/disconnect notifications.
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    init(swapABXY: Bool = false) {
        self.swapABXY = swapABXY
    }

    // MARK: - Lifecycle

    func startListening() {
        AppLog.gamepadManager.line("Starting controller listening")

        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.controllerConnected(controller)
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.controllerDisconnected(controller)
        }

        // Pick up any controllers already connected
        for controller in GCController.controllers() {
            controllerConnected(controller)
        }
    }

    func stopListening() {
        AppLog.gamepadManager.line("Stopping controller listening")

        if let obs = connectObserver {
            NotificationCenter.default.removeObserver(obs)
            connectObserver = nil
        }
        if let obs = disconnectObserver {
            NotificationCenter.default.removeObserver(obs)
            disconnectObserver = nil
        }

        // Re-enable system gestures and send zero-state for all connected controllers
        for (index, controller) in controllers {
            for element in controller.physicalInputProfile.allElements {
                element.preferredSystemGestureState = .enabled
            }
            let mask = activeGamepadMask & ~(1 << index)
            activeGamepadMask = mask
            LiSendMultiControllerEvent(
                Int16(index), Int16(bitPattern: mask),
                0, 0, 0, 0, 0, 0, 0
            )
        }
        controllers.removeAll()
        activeGamepadMask = 0
    }

    // MARK: - Controller Connect/Disconnect

    private func controllerConnected(_ controller: GCController) {
        guard controller.extendedGamepad != nil else {
            AppLog.gamepadManager.line("Ignoring non-extended gamepad: \(controller.vendorName ?? "unknown")")
            return
        }

        // Assign player index (0-3)
        let playerIndex = nextAvailableIndex()
        guard playerIndex < 4 else {
            AppLog.gamepadManager.line("Maximum 4 controllers reached, ignoring")
            return
        }

        controller.playerIndex = GCControllerPlayerIndex(rawValue: playerIndex) ?? .indexUnset
        controllers[playerIndex] = controller
        activeGamepadMask |= UInt16(1 << playerIndex)

        let controllerType = detectControllerType(controller)
        let capabilities = detectCapabilities(controller)
        let supportedButtons = buildSupportedButtonFlags()

        AppLog.gamepadManager.line("Controller \(playerIndex) connected: \(controller.vendorName ?? "unknown"), type=\(controllerType), caps=0x\(String(capabilities, radix: 16))")

        // Notify host of controller arrival
        LiSendControllerArrivalEvent(
            UInt8(playerIndex),
            activeGamepadMask,
            controllerType,
            supportedButtons,
            capabilities
        )

        // Set up input handler
        setupInputHandler(for: controller, at: playerIndex)
    }

    private func controllerDisconnected(_ controller: GCController) {
        guard let playerIndex = controllers.first(where: { $0.value === controller })?.key else { return }

        AppLog.gamepadManager.line("Controller \(playerIndex) disconnected: \(controller.vendorName ?? "unknown")")

        // Re-enable system gestures on disconnect
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .enabled
        }

        controllers.removeValue(forKey: playerIndex)
        activeGamepadMask &= ~UInt16(1 << playerIndex)

        // Send zero-state removal event
        LiSendMultiControllerEvent(
            Int16(playerIndex), Int16(bitPattern: activeGamepadMask),
            0, 0, 0, 0, 0, 0, 0
        )
    }

    // MARK: - Input Handling

    private func setupInputHandler(for controller: GCController, at playerIndex: Int) {
        guard let gamepad = controller.extendedGamepad else { return }

        // Disable system gestures on all controller elements so visionOS doesn't
        // intercept button presses for system actions (e.g. converting shoulder
        // buttons into look-and-pinch events).
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .disabled
        }

        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            guard let self else { return }
            self.sendControllerState(gamepad, controllerNumber: playerIndex)
        }
    }

    private nonisolated func sendControllerState(_ gamepad: GCExtendedGamepad, controllerNumber: Int) {
        var buttonFlags: Int32 = 0

        // Face buttons
        if gamepad.buttonA.isPressed { buttonFlags |= Int32(A_FLAG) }
        if gamepad.buttonB.isPressed { buttonFlags |= Int32(B_FLAG) }
        if gamepad.buttonX.isPressed { buttonFlags |= Int32(X_FLAG) }
        if gamepad.buttonY.isPressed { buttonFlags |= Int32(Y_FLAG) }

        // Apply A/B X/Y swap if enabled
        if swapABXY {
            buttonFlags = swapFaceButtons(buttonFlags)
        }

        // D-pad
        if gamepad.dpad.up.isPressed    { buttonFlags |= Int32(UP_FLAG) }
        if gamepad.dpad.down.isPressed  { buttonFlags |= Int32(DOWN_FLAG) }
        if gamepad.dpad.left.isPressed  { buttonFlags |= Int32(LEFT_FLAG) }
        if gamepad.dpad.right.isPressed { buttonFlags |= Int32(RIGHT_FLAG) }

        // Shoulders
        if gamepad.leftShoulder.isPressed  { buttonFlags |= Int32(LB_FLAG) }
        if gamepad.rightShoulder.isPressed { buttonFlags |= Int32(RB_FLAG) }

        // Thumbstick clicks
        if gamepad.leftThumbstickButton?.isPressed == true  { buttonFlags |= Int32(LS_CLK_FLAG) }
        if gamepad.rightThumbstickButton?.isPressed == true { buttonFlags |= Int32(RS_CLK_FLAG) }

        // Menu buttons
        if gamepad.buttonMenu.isPressed { buttonFlags |= Int32(PLAY_FLAG) }
        if gamepad.buttonOptions?.isPressed == true { buttonFlags |= Int32(BACK_FLAG) }
        if gamepad.buttonHome?.isPressed == true { buttonFlags |= Int32(SPECIAL_FLAG) }

        // Analog sticks: Float (-1.0...1.0) → Int16
        let leftStickX  = Int16(clamping: Int32(gamepad.leftThumbstick.xAxis.value * 0x7FFE))
        let leftStickY  = Int16(clamping: Int32(gamepad.leftThumbstick.yAxis.value * 0x7FFE))
        let rightStickX = Int16(clamping: Int32(gamepad.rightThumbstick.xAxis.value * 0x7FFE))
        let rightStickY = Int16(clamping: Int32(gamepad.rightThumbstick.yAxis.value * 0x7FFE))

        // Triggers: Float (0.0...1.0) → UInt8
        let leftTrigger  = UInt8(clamping: Int32(gamepad.leftTrigger.value * 0xFF))
        let rightTrigger = UInt8(clamping: Int32(gamepad.rightTrigger.value * 0xFF))

        LiSendMultiControllerEvent(
            Int16(controllerNumber),
            Int16(bitPattern: activeGamepadMask),
            buttonFlags,
            leftTrigger,
            rightTrigger,
            leftStickX,
            leftStickY,
            rightStickX,
            rightStickY
        )
    }

    // MARK: - Rumble

    /// Called from the bridge rumble callback (off main thread).
    nonisolated func handleRumble(controllerNumber: UInt16, lowFreqMotor: UInt16, highFreqMotor: UInt16) {
        let index = Int(controllerNumber)
        Task { @MainActor [weak self] in
            guard let controller = self?.controllers[index],
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

    private func nextAvailableIndex() -> Int {
        for i in 0..<4 {
            if controllers[i] == nil { return i }
        }
        return 4
    }

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

    /// Swap A↔B and X↔Y flags for Nintendo-style controllers.
    private nonisolated func swapFaceButtons(_ flags: Int32) -> Int32 {
        var result = flags & ~(Int32(A_FLAG) | Int32(B_FLAG) | Int32(X_FLAG) | Int32(Y_FLAG))

        // A ↔ B
        if flags & Int32(A_FLAG) != 0 { result |= Int32(B_FLAG) }
        if flags & Int32(B_FLAG) != 0 { result |= Int32(A_FLAG) }
        // X ↔ Y
        if flags & Int32(X_FLAG) != 0 { result |= Int32(Y_FLAG) }
        if flags & Int32(Y_FLAG) != 0 { result |= Int32(X_FLAG) }

        return result
    }
}
#endif
