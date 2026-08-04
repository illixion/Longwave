import RoyalVNCKit

/// One thing to put on the wire for a keystroke. Splitting the decision out from
/// the sending makes the part that was broken — which events a modified key
/// produces — testable without a live connection.
nonisolated enum VNCKeyEvent: Equatable {
    case down(VNCKeyCode)
    case up(VNCKeyCode)
    /// Literal text, which may take the companion's Unicode route.
    case text(String)
    case backspace(Int)
}

/// Turns our on-screen keyboard's key events into VNC keysyms.
///
/// The important rule lives in `events`: as soon as any modifier is active the
/// keystroke goes out as real keysyms, never as text. The companion's injection
/// protocol carries Unicode and nothing else — routing a modified key through it
/// is what silently turned Ctrl+G into a plain "g".
@MainActor
struct VNCKeyboardSink: VirtualKeyboardSink {
    let manager: VNCConnectionManager

    func press(_ key: VirtualKey, modifiers: VirtualModifiers, held: VirtualModifiers) {
        for event in Self.events(for: key, modifiers: modifiers, held: held) {
            switch event {
            case .down(let code): manager.sendKeyDown(code)
            case .up(let code): manager.sendKeyUp(code)
            case .text(let text): manager.routeInsertText(text)
            case .backspace(let count): manager.routeDeleteBackward(count)
            }
        }
    }

    func setHeld(_ modifier: VirtualModifiers, held: Bool, allHeld: VirtualModifiers) {
        let code = Self.keyCode(for: modifier)
        if held {
            manager.sendKeyDown(code)
        } else {
            manager.sendKeyUp(code)
        }
    }

    func insertText(_ text: String) {
        manager.routeInsertText(text)
    }

    // MARK: - Event Sequence

    /// `held` modifiers are already down on the remote (a locked latch), so only
    /// the rest get pressed and released around the key.
    static func events(for key: VirtualKey,
                       modifiers: VirtualModifiers,
                       held: VirtualModifiers) -> [VNCKeyEvent] {
        if modifiers.isEmpty {
            // Unmodified typing can still take the companion's Unicode route,
            // which gets layouts and accents right in a way keysyms can't.
            if let character = key.character(shifted: false) {
                return [.text(String(character))]
            }
            if key == .backspace {
                return [.backspace(1)]
            }
        }

        let wrap = modifiers.subtracting(held).ordered
        var events = wrap.map { VNCKeyEvent.down(keyCode(for: $0)) }
        for code in keyCodes(for: key, shifted: modifiers.contains(.shift)) {
            events.append(.down(code))
            events.append(.up(code))
        }
        events.append(contentsOf: wrap.reversed().map { VNCKeyEvent.up(keyCode(for: $0)) })
        return events
    }

    // MARK: - Key Codes

    /// X11 `XK_Caps_Lock` — RoyalVNCKit has no constant for it.
    static let capsLock = VNCKeyCode(0xFFE5)

    private static let functionKeys: [VNCKeyCode] = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
    ]

    static func keyCode(for modifier: VirtualModifiers) -> VNCKeyCode {
        switch modifier {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        default: return .shift
        }
    }

    static func keyCodes(for key: VirtualKey, shifted: Bool) -> [VNCKeyCode] {
        switch key {
        case .character:
            // The shifted glyph carries its own keysym (XK_G, XK_exclam); Shift
            // is still pressed around it, exactly as a real keyboard does it.
            guard let character = key.character(shifted: shifted) else { return [] }
            return VNCKeyCode.withCharacter(character)
        case .return: return [.return]
        case .tab: return [.tab]
        case .escape: return [.escape]
        // RoyalVNCKit naming trap: `.delete` is XK_BackSpace, `.forwardDelete`
        // is the forward Delete key.
        case .backspace: return [.delete]
        case .forwardDelete: return [.forwardDelete]
        case .capsLock: return [capsLock]
        case .up: return [.upArrow]
        case .down: return [.downArrow]
        case .left: return [.leftArrow]
        case .right: return [.rightArrow]
        case .home: return [.home]
        case .end: return [.end]
        case .pageUp: return [.pageUp]
        case .pageDown: return [.pageDown]
        case .insert: return [.insert]
        case .function(let number):
            guard functionKeys.indices.contains(number - 1) else { return [] }
            return [functionKeys[number - 1]]
        }
    }
}
