#if os(visionOS)
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

final class MacNativeKeyCaptureView: UIView {
    var screenManager: MacNativeStreamManager?

    private var observers: [NSObjectProtocol] = []

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if observers.isEmpty {
                observers.append(NotificationCenter.default.addObserver(
                    forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
                ) { [weak self] note in
                    guard let self, (note.object as? UIWindow) === self.window else { return }
                    self.reclaimFirstResponder()
                })
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

    private func reclaimFirstResponder() {
        guard let window = self.window else { return }
        if window.rootViewController?.presentedViewController != nil { return }
        if !TextInputActivity.shared.mayTakeFirstResponder() { return }
        if isFirstResponder { return }
        _ = becomeFirstResponder()
    }

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
        guard let macCode = MacKeyCodeMap.keyCode(for: key.keyCode) else { return nil }
        switch space {
        case .macVirtual: return macCode
        case .hidUsage: return UInt16(exactly: key.keyCode.rawValue)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Treat cancellation as key up to avoid stuck keys.
        pressesEnded(presses, with: event)
    }
}
#endif
