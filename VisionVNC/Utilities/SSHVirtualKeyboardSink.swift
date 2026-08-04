import Foundation

/// Turns our on-screen keyboard's key events into the byte sequences a PTY
/// expects, so ⌃G reaches the shell as 0x07 rather than as the letter "g".
///
/// A terminal has no modifier *state* to hold — there is no "Ctrl is down" on
/// the wire, only bytes that already mean Ctrl+something. So `setHeld` does
/// nothing: a locked latch here just keeps applying itself to each keystroke,
/// which is the same thing a user means by locking it.
@MainActor
struct SSHKeyboardSink: VirtualKeyboardSink {
    let session: SSHSession

    func press(_ key: VirtualKey, modifiers: VirtualModifiers, held: VirtualModifiers) {
        let bytes = Self.bytes(for: key, modifiers: modifiers)
        guard !bytes.isEmpty else { return }
        session.sendBytes(bytes)
    }

    /// Nothing to do: see the type's note — a PTY has no held-modifier concept.
    func setHeld(_ modifier: VirtualModifiers, held: Bool, allHeld: VirtualModifiers) {}

    func insertText(_ text: String) {
        // A pasted newline has to arrive as CR: that's what a terminal reads as
        // Return, and 0x0A on its own would only move the cursor down.
        session.sendText(text.replacingOccurrences(of: "\n", with: "\r"))
    }

    func supports(_ action: VirtualKeyCap.Action) -> Bool { Self.supports(action) }

    static func supports(_ action: VirtualKeyCap.Action) -> Bool {
        switch action {
        // No ⌘ and no Caps Lock over a PTY — nothing to encode them as.
        case .modifier(let modifier): return modifier != .command
        case .key(.capsLock): return false
        default: return true
        }
    }

    // MARK: - Byte Sequences

    static func bytes(for key: VirtualKey, modifiers: VirtualModifiers) -> [UInt8] {
        switch key {
        case .character:
            // Shift is already spent picking the glyph ("!" not "1"), so only
            // Ctrl and Alt are left to encode — passing Shift on would just
            // upper-case a letter that is already upper-cased.
            guard let character = key.character(shifted: modifiers.contains(.shift)),
                  let ascii = character.asciiValue else { return [] }
            return TerminalKeyEncoder.encodeCharacter(
                ascii, modifiers: terminalModifiers(modifiers.subtracting(.shift)))

        case .return: return TerminalKeyEncoder.enter
        case .escape: return TerminalKeyEncoder.escape
        case .backspace: return TerminalKeyEncoder.backspace
        case .capsLock: return []

        case .tab:
            return modified(.tab, base: TerminalKeyEncoder.tab, modifiers)
        case .up:
            return modified(.csiLetter(0x41), base: TerminalKeyEncoder.up, modifiers)
        case .down:
            return modified(.csiLetter(0x42), base: TerminalKeyEncoder.down, modifiers)
        case .right:
            return modified(.csiLetter(0x43), base: TerminalKeyEncoder.right, modifiers)
        case .left:
            return modified(.csiLetter(0x44), base: TerminalKeyEncoder.left, modifiers)
        case .home:
            return modified(.csiLetter(0x48), base: TerminalKeyEncoder.home, modifiers)
        case .end:
            return modified(.csiLetter(0x46), base: TerminalKeyEncoder.end, modifiers)
        case .pageUp:
            return modified(.csiTilde(5), base: TerminalKeyEncoder.pageUp, modifiers)
        case .pageDown:
            return modified(.csiTilde(6), base: TerminalKeyEncoder.pageDown, modifiers)
        case .insert:
            return modified(.csiTilde(2), base: tilde(2), modifiers)
        case .forwardDelete:
            return modified(.csiTilde(3), base: tilde(3), modifiers)

        case .function(let number):
            guard (1...12).contains(number) else { return [] }
            // F1–F4 are SS3 sequences; F5 up are ESC [ <n> ~ with a gap at 16.
            if number <= 4 {
                let final = UInt8(0x50 + number - 1)  // P Q R S
                return modified(.csiLetter(final), base: [0x1B, 0x4F, final], modifiers)
            }
            let numbers = [15, 17, 18, 19, 20, 21, 23, 24]
            let param = numbers[number - 5]
            return modified(.csiTilde(param), base: tilde(param), modifiers)
        }
    }

    private static func tilde(_ number: Int) -> [UInt8] {
        [0x1B, 0x5B] + Array(String(number).utf8) + [0x7E]
    }

    private static func modified(_ key: TerminalKeyEncoder.ModifiableKey,
                                 base: [UInt8],
                                 _ modifiers: VirtualModifiers) -> [UInt8] {
        TerminalKeyEncoder.apply(terminalModifiers(modifiers), to: key, base: base)
    }

    /// ⌘ has no PTY encoding and is dropped (the cap is disabled anyway).
    static func terminalModifiers(_ modifiers: VirtualModifiers) -> TerminalModifiers {
        var result: TerminalModifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.ctrl) }
        if modifiers.contains(.option) { result.insert(.alt) }
        return result
    }
}
