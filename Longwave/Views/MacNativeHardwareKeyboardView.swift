#if canImport(UIKit)
import SwiftUI
import UIKit

/// A UIViewRepresentable that captures hardware/Bluetooth keyboard events
/// and forwards them as Native remote-control key events. Mirrors
/// `HardwareKeyboardView` (the VNC path), but every physical key maps to a
/// macOS virtual keycode via `MacKeyCodeMap` instead of a VNC key code —
/// there's no printable-character fallback because HID usage covers letters
/// and symbols too (see `MacKeyCodeMap`'s doc comment).
struct MacNativeHardwareKeyboardView: UIViewRepresentable {
    let screenManager: MacNativeStreamManager

    func makeUIView(context: Context) -> MacNativeKeyCaptureView {
        let view = MacNativeKeyCaptureView()
        view.screenManager = screenManager
        return view
    }

    func updateUIView(_ uiView: MacNativeKeyCaptureView, context: Context) {
        uiView.screenManager = screenManager
    }
}

/// `KeyCaptureResponderView` owns when this may hold first responder at all.
final class MacNativeKeyCaptureView: KeyCaptureResponderView {
    var screenManager: MacNativeStreamManager?

    override var captureLogName: String { "MacNativeKeyCaptureView" }

    // MARK: - Press Events

    /// When keyboard shortcuts are available, every mapped key goes through
    /// the full keycode+modifier channel (`sendKeyDown`/`sendKeyUp`) as
    /// before. When they're not, only printable characters get through, and
    /// only as a fire-and-forget text insertion over the always-attempted
    /// text-only channel — mirroring the restriction VNC's companion-inject
    /// route already applies to typing (no modifiers, no special keys ever
    /// leave this device as a "shortcut"). Modifier-only presses and
    /// non-printable specials (arrows, F-keys, Escape, …) are simply dropped
    /// in that case — there's no way to express them as plain text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard mayCaptureKeys else {
            super.pressesBegan(presses, with: event)
            return
        }
        var handled = false
        for press in presses {
            guard let key = press.key, let screenManager,
                  let keyCode = Self.wireKeyCode(for: key, space: screenManager.keyCodeSpace) else { continue }
            handled = true
            if screenManager.keyboardShortcutsAvailability == .available {
                screenManager.sendKeyDown(keyCode: keyCode, modifiers: MacKeyCodeMap.modifiers(for: key.modifierFlags))
            } else if key.keyCode == .keyboardDeleteOrBackspace {
                screenManager.sendInjectBackspace(1)
            } else if !MacKeyCodeMap.isModifierOnly(key.keyCode), !key.characters.isEmpty {
                screenManager.sendInjectText(key.characters)
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    /// Only the full-shortcuts path needs a matching key-up — the text-only
    /// fallback above is a one-shot insertion on press, nothing to release.
    ///
    /// Deliberately not gated on `mayCaptureKeys`: text entry can start between a
    /// key going down and coming up, and swallowing that release would leave the
    /// key held on the Mac.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key, let screenManager,
                  let keyCode = Self.wireKeyCode(for: key, space: screenManager.keyCodeSpace) else { continue }
            handled = true
            guard screenManager.keyboardShortcutsAvailability == .available else { continue }
            screenManager.sendKeyUp(keyCode: keyCode, modifiers: MacKeyCodeMap.modifiers(for: key.modifierFlags))
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    /// The keycode to put on the wire for this physical key, in the
    /// server-negotiated key-code space: the kVK mapping for macOS hosts,
    /// the raw HID usage for hosts that asked for `hidUsage` (the map lookup
    /// still gates which physical keys we forward at all).
    private static func wireKeyCode(
        for key: UIKey,
        space: MacNativeStreamProtocol.KeyCodeSpace
    ) -> UInt16? {
        MacKeyCodeMap.wireKeyCode(forHIDUsage: Int(key.keyCode.rawValue), space: space)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Treat cancellation as key up to avoid stuck keys.
        pressesEnded(presses, with: event)
    }
}
#endif
