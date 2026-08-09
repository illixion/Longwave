#if MOONLIGHT_ENABLED
import SwiftUI
import UIKit
import GameController
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

/// A UIView that becomes first responder to intercept hardware keyboard press events.
final class MoonlightKeyCaptureView: UIView {

    /// Tracks active modifier state as a bitmask (MODIFIER_SHIFT | MODIFIER_CTRL | MODIFIER_ALT | MODIFIER_META).
    private var activeModifiers: Int8 = 0

    private var observers: [NSObjectProtocol] = []

    override var canBecomeFirstResponder: Bool { true }

    private var loggedFirstPress = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if observers.isEmpty {
                // Re-grab first responder whenever this window becomes key — e.g.
                // after the keyboard window closes — so hardware keyboard input
                // works without the keyboard window open, not just while focused.
                observers.append(NotificationCenter.default.addObserver(
                    forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
                ) { [weak self] note in
                    guard let self, (note.object as? UIWindow) === self.window else { return }
                    self.reclaimFirstResponder()
                })
                // And once text entry finishes, since a grab attempted during a
                // typing/dictation session is declined rather than forced.
                observers.append(NotificationCenter.default.addObserver(
                    forName: .textEntryDidEnd, object: nil, queue: .main
                ) { [weak self] _ in
                    self?.reclaimFirstResponder()
                })
            }
            reclaimFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.reclaimFirstResponder()
            }
        } else {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Become first responder unless something is presented over our window, or
    /// the user is entering text anywhere in the app — taking the responder out
    /// from under a live session ends dictation. We do NOT gate on `isKeyWindow`
    /// — on visionOS that can be false even for the window the user is looking
    /// at, which would block capture entirely.
    private func reclaimFirstResponder() {
        guard let window = self.window else { return }
        if window.rootViewController?.presentedViewController != nil { return }
        if !TextInputActivity.shared.mayTakeFirstResponder() { return }
        if isFirstResponder { return }
        let ok = becomeFirstResponder()
        AppLog.moonlightStream.line("MoonlightKeyCaptureView becomeFirstResponder -> \(ok) (isKeyWindow=\(window.isKeyWindow))")
    }

    // MARK: - Press Events

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
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
