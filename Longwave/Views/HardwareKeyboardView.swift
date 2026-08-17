import SwiftUI
import UIKit
import RoyalVNCKit

/// A UIViewRepresentable that captures hardware/Bluetooth keyboard events
/// and forwards them as VNC key events.
struct HardwareKeyboardView: UIViewRepresentable {
    let connectionManager: VNCConnectionManager

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.connectionManager = connectionManager
        return view
    }

    func updateUIView(_ uiView: KeyCaptureView, context: Context) {
        uiView.connectionManager = connectionManager
    }
}

/// A UIView that becomes first responder to intercept hardware keyboard press
/// events. `KeyCaptureResponderView` owns when it may hold the responder at all.
final class KeyCaptureView: KeyCaptureResponderView {
    var connectionManager: VNCConnectionManager?

    private var loggedFirstPress = false

    // MARK: - Sticky Modifiers

    /// Time of each modifier's most recent press, for double-tap detection.
    /// Cleared once a double-tap is recognized so a third press starts fresh.
    private var modifierLastPressAt: [UIKeyboardHIDUsage: Date] = [:]
    /// Modifiers currently latched sticky — held down at the remote past
    /// their physical key's release, until the same key is pressed again.
    private var stickyModifiers: Set<UIKeyboardHIDUsage> = []
    /// Keys whose sticky release was already sent by `pressesBegan` (the
    /// unlatching tap), so the matching `pressesEnded` doesn't send it again.
    private var pendingUnlatchRelease: Set<UIKeyboardHIDUsage> = []
    /// Window under which two presses of the same modifier count as a
    /// double-tap. Matches `DoubleClickCadence`'s pointer double-click window.
    private let doubleTapInterval: TimeInterval = 0.4

    /// Leaving the window can't strand a latched modifier down at the remote.
    override func keyCaptureViewDidLeaveWindow() {
        releaseStickyModifiers()
    }

    // MARK: - Press Events

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard mayCaptureKeys else {
            super.pressesBegan(presses, with: event)
            return
        }
        if !loggedFirstPress {
            loggedFirstPress = true
            AppLog.app.line("KeyCaptureView received first hardware key press")
        }
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }

            if isStickyEligibleModifier(key.keyCode), let vncKey = vncKeyCode(for: key) {
                handleModifierPressBegan(key.keyCode, vncKey: vncKey)
                handled = true
                continue
            }

            // Handle modifier flags that changed
            sendModifierChanges(for: key, isDown: true)

            // Map the key to a VNC key code and send it
            if let vncKey = vncKeyCode(for: key) {
                connectionManager?.sendKeyDown(vncKey)
                handled = true
            } else {
                // Printable character — send each character
                let characters = key.characters
                if !characters.isEmpty {
                    for char in characters {
                        let keyCodes = VNCKeyCode.withCharacter(char)
                        for keyCode in keyCodes {
                            connectionManager?.sendKeyDown(keyCode)
                        }
                    }
                    handled = true
                }
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    /// Deliberately not gated on `mayCaptureKeys`: text entry can start between a
    /// key going down and coming up, and swallowing that release would leave the
    /// key held at the remote. A release for a key we never pressed is harmless.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }

            if isStickyEligibleModifier(key.keyCode), let vncKey = vncKeyCode(for: key) {
                handleModifierPressEnded(key.keyCode, vncKey: vncKey)
                handled = true
                continue
            }

            // Handle modifier flags that changed
            sendModifierChanges(for: key, isDown: false)

            if let vncKey = vncKeyCode(for: key) {
                connectionManager?.sendKeyUp(vncKey)
                handled = true
            } else {
                let characters = key.characters
                if !characters.isEmpty {
                    for char in characters {
                        let keyCodes = VNCKeyCode.withCharacter(char)
                        for keyCode in keyCodes {
                            connectionManager?.sendKeyUp(keyCode)
                        }
                    }
                    handled = true
                }
            }
        }

        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Treat cancellation as key up to avoid stuck keys
        pressesEnded(presses, with: event)
    }

    // MARK: - Sticky Modifiers

    /// Shift/Ctrl/Alt/Cmd (both sides) — the modifiers a double-tap can latch.
    /// Caps Lock is excluded: it's already a hardware toggle, not a held key.
    private func isStickyEligibleModifier(_ keyCode: UIKeyboardHIDUsage) -> Bool {
        switch keyCode {
        case .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftGUI, .keyboardRightGUI:
            return true
        default:
            return false
        }
    }

    private func virtualModifier(for keyCode: UIKeyboardHIDUsage) -> VirtualModifiers? {
        switch keyCode {
        case .keyboardLeftShift, .keyboardRightShift:     return .shift
        case .keyboardLeftControl, .keyboardRightControl: return .control
        case .keyboardLeftAlt, .keyboardRightAlt:         return .option
        case .keyboardLeftGUI, .keyboardRightGUI:         return .command
        default: return nil
        }
    }

    /// A normal press/release of a modifier passes straight through (down on
    /// press, up on release), so held combos like Ctrl+C keep working. A
    /// second press within `doubleTapInterval` latches it sticky instead:
    /// it stays down at the remote — applying to whatever is typed next —
    /// until the same modifier key is pressed a third time.
    private func handleModifierPressBegan(_ keyCode: UIKeyboardHIDUsage, vncKey: VNCKeyCode) {
        if stickyModifiers.contains(keyCode) {
            connectionManager?.sendKeyUp(vncKey)
            stickyModifiers.remove(keyCode)
            pendingUnlatchRelease.insert(keyCode)
            modifierLastPressAt[keyCode] = nil
            if let modifier = virtualModifier(for: keyCode) {
                connectionManager?.stickyModifiers.remove(modifier)
            }
            return
        }

        connectionManager?.sendKeyDown(vncKey)

        if let lastPress = modifierLastPressAt[keyCode],
           Date().timeIntervalSince(lastPress) < doubleTapInterval {
            stickyModifiers.insert(keyCode)
            modifierLastPressAt[keyCode] = nil
            if let modifier = virtualModifier(for: keyCode) {
                connectionManager?.stickyModifiers.insert(modifier)
            }
        } else {
            modifierLastPressAt[keyCode] = Date()
        }
    }

    private func handleModifierPressEnded(_ keyCode: UIKeyboardHIDUsage, vncKey: VNCKeyCode) {
        if pendingUnlatchRelease.remove(keyCode) != nil {
            // Already released when the unlatching press began.
            return
        }
        if stickyModifiers.contains(keyCode) {
            // Stays down at the remote until the next press unlatches it.
            return
        }
        connectionManager?.sendKeyUp(vncKey)
    }

    /// Force-releases any modifier still latched sticky, so tearing down this
    /// view (disconnect, window close) can't leave it stuck down remotely.
    private func releaseStickyModifiers() {
        guard !stickyModifiers.isEmpty else { return }
        for keyCode in stickyModifiers {
            if let vncKey = vncKeyCode(forHIDUsage: keyCode) {
                connectionManager?.sendKeyUp(vncKey)
            }
            if let modifier = virtualModifier(for: keyCode) {
                connectionManager?.stickyModifiers.remove(modifier)
            }
        }
        stickyModifiers.removeAll()
        modifierLastPressAt.removeAll()
        pendingUnlatchRelease.removeAll()
    }

    // MARK: - Modifier Handling

    /// Send modifier key down/up when they change.
    /// Modifier-only presses (e.g. pressing just Shift) have a keyCode but no characters.
    private func sendModifierChanges(for key: UIKey, isDown: Bool) {
        let modifiers = key.modifierFlags

        // We only send modifier events for standalone modifier presses.
        // For combined presses (e.g. Ctrl+C), the modifier is part of the HID key code
        // and handled by the server.
        if isModifierOnlyKey(key.keyCode) {
            // Already handled by vncKeyCode mapping below
            return
        }

        // For non-modifier keys pressed with modifiers, the modifier state is
        // implicitly tracked by the server from prior modifier key events.
        _ = modifiers // suppress unused warning
    }

    private func isModifierOnlyKey(_ keyCode: UIKeyboardHIDUsage) -> Bool {
        switch keyCode {
        case .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftGUI, .keyboardRightGUI,
             .keyboardCapsLock:
            return true
        default:
            return false
        }
    }

    // MARK: - HID to VNC Key Code Mapping

    /// Maps UIKeyboardHIDUsage to VNCKeyCode for non-printable/special keys.
    /// Returns nil for printable characters (handled via UIKey.characters).
    private func vncKeyCode(for key: UIKey) -> VNCKeyCode? {
        vncKeyCode(forHIDUsage: key.keyCode)
    }

    private func vncKeyCode(forHIDUsage keyCode: UIKeyboardHIDUsage) -> VNCKeyCode? {
        switch keyCode {
        // Modifier keys
        case .keyboardLeftShift:     return .shift
        case .keyboardRightShift:    return .rightShift
        case .keyboardLeftControl:   return .control
        case .keyboardRightControl:  return .rightControl
        case .keyboardLeftAlt:       return .option
        case .keyboardRightAlt:      return .rightOption
        case .keyboardLeftGUI:       return .command
        case .keyboardRightGUI:      return .rightCommand
        case .keyboardCapsLock:      return VNCKeyCode(0xffe5) // XK_Caps_Lock

        // Navigation
        case .keyboardReturnOrEnter: return .return
        case .keyboardEscape:        return .escape
        case .keyboardDeleteOrBackspace: return .delete
        case .keyboardDeleteForward: return .forwardDelete
        case .keyboardTab:           return .tab
        case .keyboardSpacebar:      return .space
        case .keyboardInsert:        return .insert
        case .keyboardHome:          return .home
        case .keyboardEnd:           return .end
        case .keyboardPageUp:        return .pageUp
        case .keyboardPageDown:      return .pageDown

        // Arrow keys
        case .keyboardLeftArrow:     return .leftArrow
        case .keyboardRightArrow:    return .rightArrow
        case .keyboardUpArrow:       return .upArrow
        case .keyboardDownArrow:     return .downArrow

        // Function keys
        case .keyboardF1:            return .f1
        case .keyboardF2:            return .f2
        case .keyboardF3:            return .f3
        case .keyboardF4:            return .f4
        case .keyboardF5:            return .f5
        case .keyboardF6:            return .f6
        case .keyboardF7:            return .f7
        case .keyboardF8:            return .f8
        case .keyboardF9:            return .f9
        case .keyboardF10:           return .f10
        case .keyboardF11:           return .f11
        case .keyboardF12:           return .f12
        case .keyboardF13:           return .f13
        case .keyboardF14:           return .f14
        case .keyboardF15:           return .f15
        case .keyboardF16:           return .f16
        case .keyboardF17:           return .f17
        case .keyboardF18:           return .f18
        case .keyboardF19:           return .f19

        // Misc
        case .keyboardPrintScreen:   return VNCKeyCode(0xff61) // XK_Print
        case .keyboardScrollLock:    return VNCKeyCode(0xff14) // XK_Scroll_Lock
        case .keyboardPause:         return VNCKeyCode(0xff13) // XK_Pause
        case .keyboardLockingNumLock: return VNCKeyCode(0xff7f) // XK_Num_Lock

        // Keypad
        case .keypadEnter:           return VNCKeyCode(0xff8d) // XK_KP_Enter
        case .keypad0:               return VNCKeyCode(0xffb0) // XK_KP_0
        case .keypad1:               return VNCKeyCode(0xffb1)
        case .keypad2:               return VNCKeyCode(0xffb2)
        case .keypad3:               return VNCKeyCode(0xffb3)
        case .keypad4:               return VNCKeyCode(0xffb4)
        case .keypad5:               return VNCKeyCode(0xffb5)
        case .keypad6:               return VNCKeyCode(0xffb6)
        case .keypad7:               return VNCKeyCode(0xffb7)
        case .keypad8:               return VNCKeyCode(0xffb8)
        case .keypad9:               return VNCKeyCode(0xffb9)
        case .keypadPeriod:          return VNCKeyCode(0xffae) // XK_KP_Decimal
        case .keypadPlus:            return VNCKeyCode(0xffab) // XK_KP_Add
        case .keypadHyphen:          return VNCKeyCode(0xffad) // XK_KP_Subtract
        case .keypadAsterisk:        return VNCKeyCode(0xffaa) // XK_KP_Multiply
        case .keypadSlash:           return VNCKeyCode(0xffaf) // XK_KP_Divide
        case .keypadEqualSign:       return VNCKeyCode(0xffbd) // XK_KP_Equal
        case .keypadNumLock:         return VNCKeyCode(0xff7f) // XK_Num_Lock

        default:
            // Printable characters: return nil so we fall through to UIKey.characters.
            return nil
        }
    }
}
