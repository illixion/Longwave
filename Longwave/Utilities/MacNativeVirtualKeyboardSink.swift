#if os(visionOS)
import UIKit

/// Turns our on-screen keyboard's key events into Native remote-control key
/// frames, so the Native window has the same keyboard the VNC and Moonlight
/// windows do.
///
/// Native is the one transport with *two* input channels, and which one a cap can
/// use depends on what the Mac companion allows (see `MacNativeKeyCaptureView`,
/// which applies the same split to the hardware keyboard):
///
/// - "Allow keyboard control" on → every cap goes out as a keycode plus a
///   modifier mask, exactly like a physical key at that position.
/// - Off → only the always-available text-only channel remains
///   (`CompanionInjectProtocol`, the same one VNC typing uses). It carries
///   Unicode and nothing else, so the modifier caps and the special keys report
///   themselves unsupported rather than silently doing nothing.
///
/// Keys reach the wire through `MacKeyCodeMap` in both cases, so the keycode
/// space the server negotiated (`macVirtual` or `hidUsage`) is honoured here too.
@MainActor
struct MacNativeKeyboardSink: VirtualKeyboardSink {
    let manager: MacNativeStreamManager

    private var shortcutsAvailable: Bool {
        manager.keyboardShortcutsAvailability == .available
    }

    func press(_ key: VirtualKey, modifiers: VirtualModifiers, held: VirtualModifiers) {
        guard shortcutsAvailable else {
            typeAsText(key, shifted: modifiers.contains(.shift))
            return
        }
        guard let code = wireKeyCode(for: key) else { return }

        // `held` modifiers are already down on the Mac (a locked latch), so only
        // the rest are pressed and released around the key. The mask grows and
        // shrinks alongside them, so the Mac never sees an event that claims a
        // modifier is down before it was pressed.
        let wrap = modifiers.subtracting(held).ordered
        var applied = held
        for modifier in wrap {
            applied.insert(modifier)
            if let modifierCode = wireKeyCode(for: modifier) {
                manager.sendKeyDown(keyCode: modifierCode, modifiers: Self.mask(applied))
            }
        }

        let mask = Self.mask(modifiers)
        manager.sendKeyDown(keyCode: code, modifiers: mask)
        manager.sendKeyUp(keyCode: code, modifiers: mask)

        var remaining = modifiers
        for modifier in wrap.reversed() {
            remaining.remove(modifier)
            if let modifierCode = wireKeyCode(for: modifier) {
                manager.sendKeyUp(keyCode: modifierCode, modifiers: Self.mask(remaining))
            }
        }
    }

    func setHeld(_ modifier: VirtualModifiers, held: Bool, allHeld: VirtualModifiers) {
        guard shortcutsAvailable, let code = wireKeyCode(for: modifier) else { return }
        if held {
            manager.sendKeyDown(keyCode: code, modifiers: Self.mask(allHeld))
        } else {
            manager.sendKeyUp(keyCode: code, modifiers: Self.mask(allHeld))
        }
    }

    /// Clipboard paste and dictation. The text channel gets layouts and accents
    /// right in a way a keycode can't, so it wins whenever it's up.
    func insertText(_ text: String) {
        if manager.textInputAvailable {
            manager.sendInjectText(text)
            return
        }
        guard shortcutsAvailable else { return }
        for character in text {
            if character.isNewline {
                press(.return, modifiers: [], held: [])
            } else if let stroke = VirtualKeyboardLayout.stroke(typing: character) {
                press(stroke.key, modifiers: stroke.shift ? .shift : [], held: [])
            }
        }
    }

    func supports(_ action: VirtualKeyCap.Action) -> Bool {
        if shortcutsAvailable { return true }
        switch action {
        case .paste:
            return manager.textInputAvailable
        case .modifier(let modifier):
            // Shift is fine without the shortcut channel — latching it just picks
            // the shifted glyph, which is still plain text. The others exist only
            // to make a shortcut, which is precisely what's unavailable.
            return modifier == .shift
        case .key(let key):
            guard manager.textInputAvailable else { return false }
            return key.character(shifted: false) != nil || key == .backspace
        }
    }

    // MARK: - Text-only fallback

    private func typeAsText(_ key: VirtualKey, shifted: Bool) {
        if let character = key.character(shifted: shifted) {
            manager.sendInjectText(String(character))
        } else if key == .backspace {
            manager.sendInjectBackspace(1)
        }
    }

    // MARK: - Key Codes

    static func mask(_ modifiers: VirtualModifiers) -> MacNativeKeyModifiers {
        var mask: MacNativeKeyModifiers = []
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.command) { mask.insert(.command) }
        return mask
    }

    private func wireKeyCode(for key: VirtualKey) -> UInt16? {
        Self.hidUsage(for: key).flatMap(wireKeyCode(forHIDUsage:))
    }

    private func wireKeyCode(for modifier: VirtualModifiers) -> UInt16? {
        wireKeyCode(forHIDUsage: Self.hidUsage(for: modifier))
    }

    /// Same rule as the hardware capture view: the kVK code for macOS hosts, the
    /// raw HID usage for hosts that asked for `hidUsage`, and the map lookup still
    /// gates which keys we forward at all.
    private func wireKeyCode(forHIDUsage usage: UIKeyboardHIDUsage) -> UInt16? {
        guard let macCode = MacKeyCodeMap.keyCode(for: usage) else { return nil }
        switch manager.keyCodeSpace {
        case .macVirtual: return macCode
        case .hidUsage: return UInt16(exactly: usage.rawValue)
        }
    }

    /// The left-hand key for each modifier, matching what a Mac keyboard sends.
    private static func hidUsage(for modifier: VirtualModifiers) -> UIKeyboardHIDUsage {
        switch modifier {
        case .control: return .keyboardLeftControl
        case .option: return .keyboardLeftAlt
        case .command: return .keyboardLeftGUI
        default: return .keyboardLeftShift
        }
    }

    private static func hidUsage(for key: VirtualKey) -> UIKeyboardHIDUsage? {
        switch key {
        // Always the unshifted glyph — the mask's shift bit does the rest, and the
        // Mac's own layout resolves what that position types.
        case .character(let base, _): return MacKeyCodeMap.hidUsage(typing: base)
        case .return: return .keyboardReturnOrEnter
        case .tab: return .keyboardTab
        case .escape: return .keyboardEscape
        case .backspace: return .keyboardDeleteOrBackspace
        case .forwardDelete: return .keyboardDeleteForward
        case .capsLock: return .keyboardCapsLock
        case .up: return .keyboardUpArrow
        case .down: return .keyboardDownArrow
        case .left: return .keyboardLeftArrow
        case .right: return .keyboardRightArrow
        case .home: return .keyboardHome
        case .end: return .keyboardEnd
        case .pageUp: return .keyboardPageUp
        case .pageDown: return .keyboardPageDown
        case .insert: return .keyboardInsert
        case .function(let number):
            guard functionUsages.indices.contains(number - 1) else { return nil }
            return functionUsages[number - 1]
        }
    }

    private static let functionUsages: [UIKeyboardHIDUsage] = [
        .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5,
        .keyboardF6, .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10,
        .keyboardF11, .keyboardF12,
    ]
}
#endif
