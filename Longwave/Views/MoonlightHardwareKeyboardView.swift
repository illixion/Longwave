#if MOONLIGHT_ENABLED
import SwiftUI
import UIKit
import GameController
import os
@preconcurrency import MoonlightCommonC

/// A UIViewRepresentable that captures hardware/Bluetooth keyboard events
/// and forwards them as Moonlight keyboard events via LiSendKeyboardEvent().
struct MoonlightHardwareKeyboardView: UIViewRepresentable {

    func makeUIView(context: Context) -> MoonlightKeyCaptureView {
        let view = MoonlightKeyCaptureView()
        return view
    }

    func updateUIView(_ uiView: MoonlightKeyCaptureView, context: Context) {}
}

/// A UIView that becomes first responder to intercept hardware keyboard press
/// events. `KeyCaptureResponderView` owns when it may hold the responder at all.
final class MoonlightKeyCaptureView: KeyCaptureResponderView {

    /// Tracks active modifier state as a bitmask (MODIFIER_SHIFT | MODIFIER_CTRL | MODIFIER_ALT | MODIFIER_META).
    private var activeModifiers: Int8 = 0

    private var loggedFirstPress = false

    override var captureLog: Logger { AppLog.moonlightStream }
    override var captureLogName: String { "MoonlightKeyCaptureView" }

    // MARK: - Press Events

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard mayCaptureKeys else {
            super.pressesBegan(presses, with: event)
            return
        }
        // When a GCKeyboard is present, MoonlightKeyboardManager owns key input
        // (GameController captures the keyboard while streaming). Defer to it to
        // avoid double keystrokes; this UIPress path is only a fallback.
        if GCKeyboard.coalesced != nil {
            super.pressesBegan(presses, with: event)
            return
        }
        if !loggedFirstPress {
            loggedFirstPress = true
            AppLog.moonlightStream.line("MoonlightKeyCaptureView received first hardware key press")
        }
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }
            let usage = key.keyCode

            // Update modifier state if this is a modifier key
            let modFlag = MoonlightKeyCodes.modifierFlag(for: usage)
            if modFlag != 0 {
                activeModifiers |= modFlag
            }

            // Map HID usage to Windows VK code
            if let vkCode = MoonlightKeyCodes.windowsKeyCode(for: usage) {
                LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_DOWN), activeModifiers)
                handled = true
            } else {
                // Try character-based mapping for printable keys
                let chars = key.charactersIgnoringModifiers
                if let char = chars.first,
                   let vkCode = MoonlightKeyCodes.windowsKeyCode(for: char) {
                    LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_DOWN), activeModifiers)
                    handled = true
                }
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if GCKeyboard.coalesced != nil {
            super.pressesEnded(presses, with: event)
            return
        }
        var handled = false

        for press in presses {
            guard let key = press.key else { continue }
            let usage = key.keyCode

            // Map HID usage to Windows VK code
            if let vkCode = MoonlightKeyCodes.windowsKeyCode(for: usage) {
                LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_UP), activeModifiers)
                handled = true
            } else {
                let chars = key.charactersIgnoringModifiers
                if let char = chars.first,
                   let vkCode = MoonlightKeyCodes.windowsKeyCode(for: char) {
                    LiSendKeyboardEvent(vkCode, Int8(KEY_ACTION_UP), activeModifiers)
                    handled = true
                }
            }

            // Update modifier state after sending the key up
            let modFlag = MoonlightKeyCodes.modifierFlag(for: usage)
            if modFlag != 0 {
                activeModifiers &= ~modFlag
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
}
#endif
