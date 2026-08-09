import Foundation

/// Raw byte sequences for the terminal quick-key row and hardware-key mapping.
/// These are the standard xterm/VT100 encodings a PTY expects; sent verbatim
/// over the SSH channel as stdin. Sufficient to drive Claude's TUI (its
/// permission prompts are arrow + enter driven).
nonisolated enum TerminalKeyEncoder {
    static let escape: [UInt8] = [0x1B]
    static let tab: [UInt8] = [0x09]
    static let shiftTab: [UInt8] = [0x1B, 0x5B, 0x5A]   // ESC [ Z
    static let up: [UInt8] = [0x1B, 0x5B, 0x41]         // ESC [ A
    static let down: [UInt8] = [0x1B, 0x5B, 0x42]       // ESC [ B
    static let right: [UInt8] = [0x1B, 0x5B, 0x43]      // ESC [ C
    static let left: [UInt8] = [0x1B, 0x5B, 0x44]       // ESC [ D
    static let ctrlA: [UInt8] = [0x01]                  // SOH (line start)
    static let ctrlC: [UInt8] = [0x03]                  // ETX (interrupt)
    static let ctrlD: [UInt8] = [0x04]                  // EOT
    static let ctrlE: [UInt8] = [0x05]                  // ENQ (line end)
    static let ctrlR: [UInt8] = [0x12]                  // DC2 (reverse search)
    static let ctrlL: [UInt8] = [0x0C]                  // FF (clear)
    static let ctrlZ: [UInt8] = [0x1A]                  // SUB (suspend)
    static let enter: [UInt8] = [0x0D]                  // CR
    static let backspace: [UInt8] = [0x7F]              // DEL
    static let pageUp: [UInt8] = [0x1B, 0x5B, 0x35, 0x7E]   // ESC [ 5 ~
    static let pageDown: [UInt8] = [0x1B, 0x5B, 0x36, 0x7E] // ESC [ 6 ~
    static let home: [UInt8] = [0x1B, 0x5B, 0x48]      // ESC [ H
    static let end: [UInt8] = [0x1B, 0x5B, 0x46]       // ESC [ F

    /// Control byte for a single-character string (the ⌃ latch): `a`/`A` →
    /// 0x01 … plus the standard `@ [ \ ] ^ _` controls. nil when the input
    /// isn't a single ASCII char with a control mapping.
    static func controlByte(for text: String) -> UInt8? {
        guard text.count == 1, let scalar = text.unicodeScalars.first,
              scalar.isASCII else { return nil }
        return controlByte(forByte: UInt8(scalar.value))
    }

    /// Control byte for a single ASCII byte: `a`/`A` → 0x01 … `@ [ \ ] ^ _`
    /// controls. Lowercase letters are folded up first. nil outside that range.
    static func controlByte(forByte byte: UInt8) -> UInt8? {
        var v = byte
        if (0x61...0x7A).contains(v) { v -= 0x20 }  // a-z → A-Z
        guard (0x40...0x5F).contains(v) else { return nil }  // @ A-Z [ \ ] ^ _
        return v & 0x1F
    }

    // MARK: - Modifier encoding (quick-key row + composer latches)

    /// A quick key's semantic identity, so latched modifiers can be turned into
    /// the correct xterm sequence rather than blindly prefixing raw bytes.
    enum ModifiableKey: Equatable {
        case csiLetter(UInt8)   // final byte of a `ESC [ … <letter>` key: A/B/C/D, H, F
        /// Numeric param of a `ESC [ <n> ~` key: 5 (PgUp), 6 (PgDn), 15 (F5)…
        case csiTilde(Int)
        case tab
        case character(UInt8)   // a printable ASCII byte (/, |, ~, -, …)
    }

    /// Encode a printable byte under the active modifiers: Ctrl → control byte,
    /// Shift → uppercase (letters only; other shifted glyphs are typed directly),
    /// Alt/Meta → ESC prefix. Combinable (e.g. ⌃⌥b → ESC 0x02).
    static func encodeCharacter(_ byte: UInt8, modifiers: TerminalModifiers) -> [UInt8] {
        var b = byte
        if modifiers.contains(.shift), (0x61...0x7A).contains(b) { b -= 0x20 }
        var seq: [UInt8]
        if modifiers.contains(.ctrl), let c = controlByte(forByte: b) {
            seq = [c]
        } else {
            seq = [b]
        }
        if modifiers.contains(.alt) { seq.insert(0x1B, at: 0) }  // Meta = ESC prefix
        return seq
    }

    /// Apply latched modifiers to a modifiable key. Special keys use the xterm
    /// `ESC [ 1 ; <param> <letter>` / `ESC [ <n> ; <param> ~` forms (param =
    /// 1 + shift + 2·alt + 4·ctrl); Tab honours Shift (back-tab) and Alt.
    static func apply(_ modifiers: TerminalModifiers, to key: ModifiableKey, base: [UInt8]) -> [UInt8] {
        guard !modifiers.isEmpty else { return base }
        let param = Array(String(modifiers.csiParameter).utf8)
        switch key {
        case .csiLetter(let final):
            return [0x1B, 0x5B, 0x31, 0x3B] + param + [final]        // ESC [ 1 ; p <final>
        case .csiTilde(let num):
            // Written out as decimal digits — the function keys are ESC [ 15 ~
            // and up, so a single-byte form wouldn't reach them.
            return [0x1B, 0x5B] + Array(String(num).utf8) + [0x3B] + param + [0x7E]
        case .tab:
            if modifiers.contains(.shift) { return shiftTab }        // ESC [ Z (back-tab)
            if modifiers.contains(.alt) { return [0x1B, 0x09] }      // Meta-Tab
            return base                                              // Ctrl-Tab: no portable seq
        case .character(let b):
            return encodeCharacter(b, modifiers: modifiers)
        }
    }

    /// Bytes for a quick-key press under the active modifiers. No modifiers, or a
    /// key with no modifiable identity → the key's own bytes unchanged.
    static func encodeQuickKey(_ key: TerminalQuickKey, modifiers: TerminalModifiers) -> [UInt8] {
        guard !modifiers.isEmpty, let target = key.modifiable else { return key.bytes }
        return apply(modifiers, to: target, base: key.bytes)
    }

    /// Bytes for a composer send under the active modifiers, treating the text as
    /// a single keypress. nil when it isn't a single ASCII char (caller then
    /// sends it as ordinary text).
    static func encodeComposerKey(_ text: String, modifiers: TerminalModifiers) -> [UInt8]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 1, let scalar = trimmed.unicodeScalars.first,
              scalar.isASCII else { return nil }
        return encodeCharacter(UInt8(scalar.value), modifiers: modifiers)
    }
}

/// The three on-screen modifier latches for the terminal quick-key row.
nonisolated struct TerminalModifiers: OptionSet {
    let rawValue: Int
    static let shift = TerminalModifiers(rawValue: 1 << 0)
    static let alt   = TerminalModifiers(rawValue: 1 << 1)
    static let ctrl  = TerminalModifiers(rawValue: 1 << 2)

    /// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4). Range 2…8 when
    /// any modifier is set (1 = "none", never emitted).
    var csiParameter: Int {
        1 + (contains(.shift) ? 1 : 0) + (contains(.alt) ? 2 : 0) + (contains(.ctrl) ? 4 : 0)
    }
}

/// A key in the terminal quick-key row. `bytes` go to the PTY verbatim (plain
/// ASCII characters are just their byte). `catalog` is the single source of
/// truth; the user's enabled subset is stored in UserDefaults as comma-joined
/// ids (see `ConnectionDefaults.Keys.terminalQuickKeys`).
nonisolated struct TerminalQuickKey: Identifiable, Equatable {
    enum Group: CaseIterable {
        case navigation, control, paging, characters, editing
    }

    let id: String
    let label: String
    /// Human-readable name for the Settings quick-key editor.
    let name: String
    let bytes: [UInt8]
    let group: Group
    /// Semantic identity for encoding latched modifiers (⌃/⌥/⇧); nil for keys
    /// that are already control combos or have no standard modified form.
    var modifiable: TerminalKeyEncoder.ModifiableKey? = nil

    static let catalog: [TerminalQuickKey] = [
        .init(id: "esc", label: "esc", name: "Escape", bytes: TerminalKeyEncoder.escape, group: .navigation),
        .init(id: "tab", label: "tab", name: "Tab", bytes: TerminalKeyEncoder.tab, group: .navigation, modifiable: .tab),
        .init(id: "shift-tab", label: "⇧⇥", name: "Shift-Tab", bytes: TerminalKeyEncoder.shiftTab, group: .navigation),
        .init(id: "up", label: "↑", name: "Up", bytes: TerminalKeyEncoder.up, group: .navigation, modifiable: .csiLetter(0x41)),
        .init(id: "down", label: "↓", name: "Down", bytes: TerminalKeyEncoder.down, group: .navigation, modifiable: .csiLetter(0x42)),
        .init(id: "left", label: "←", name: "Left", bytes: TerminalKeyEncoder.left, group: .navigation, modifiable: .csiLetter(0x44)),
        .init(id: "right", label: "→", name: "Right", bytes: TerminalKeyEncoder.right, group: .navigation, modifiable: .csiLetter(0x43)),
        .init(id: "ctrl-c", label: "⌃C", name: "Interrupt", bytes: TerminalKeyEncoder.ctrlC, group: .control),
        .init(id: "ctrl-d", label: "⌃D", name: "End of input", bytes: TerminalKeyEncoder.ctrlD, group: .control),
        .init(id: "ctrl-z", label: "⌃Z", name: "Suspend", bytes: TerminalKeyEncoder.ctrlZ, group: .control),
        .init(id: "ctrl-r", label: "⌃R", name: "History search", bytes: TerminalKeyEncoder.ctrlR, group: .control),
        .init(id: "ctrl-l", label: "⌃L", name: "Clear screen", bytes: TerminalKeyEncoder.ctrlL, group: .control),
        .init(id: "ctrl-a", label: "⌃A", name: "Line start", bytes: TerminalKeyEncoder.ctrlA, group: .control),
        .init(id: "ctrl-e", label: "⌃E", name: "Line end", bytes: TerminalKeyEncoder.ctrlE, group: .control),
        .init(id: "page-up", label: "⇞", name: "Page Up", bytes: TerminalKeyEncoder.pageUp, group: .paging, modifiable: .csiTilde(5)),
        .init(id: "page-down", label: "⇟", name: "Page Down", bytes: TerminalKeyEncoder.pageDown, group: .paging, modifiable: .csiTilde(6)),
        .init(id: "home", label: "↖", name: "Home", bytes: TerminalKeyEncoder.home, group: .paging, modifiable: .csiLetter(0x48)),
        .init(id: "end", label: "↘", name: "End", bytes: TerminalKeyEncoder.end, group: .paging, modifiable: .csiLetter(0x46)),
        .init(id: "slash", label: "/", name: "Slash", bytes: [0x2F], group: .characters, modifiable: .character(0x2F)),
        .init(id: "pipe", label: "|", name: "Pipe", bytes: [0x7C], group: .characters, modifiable: .character(0x7C)),
        .init(id: "tilde", label: "~", name: "Tilde", bytes: [0x7E], group: .characters, modifiable: .character(0x7E)),
        .init(id: "dash", label: "-", name: "Dash", bytes: [0x2D], group: .characters, modifiable: .character(0x2D)),
        .init(id: "enter", label: "⏎", name: "Enter", bytes: TerminalKeyEncoder.enter, group: .editing),
        .init(id: "backspace", label: "⌫", name: "Backspace", bytes: TerminalKeyEncoder.backspace, group: .editing),
    ]

    /// Today's row plus the most-wanted additions; used when the user has
    /// never customized the set (the @AppStorage initial value).
    static let defaultSelectionIDs: [String] = [
        "esc", "tab", "shift-tab", "up", "down", "left", "right",
        "ctrl-c", "ctrl-d", "ctrl-z", "ctrl-r", "page-up", "page-down", "enter",
    ]

    static let defaultSelectionStored: String = defaultSelectionIDs.joined(separator: ",")

    /// Decode the stored comma-joined id list. Unknown ids (removed keys) are
    /// dropped; an empty string means the user disabled everything.
    static func enabledIDs(from stored: String) -> Set<String> {
        let known = Set(catalog.map(\.id))
        return Set(stored.split(separator: ",").map(String.init)).intersection(known)
    }

    /// Encode an enabled set in stable catalog order.
    static func encodeSelection(_ enabled: Set<String>) -> String {
        catalog.map(\.id).filter(enabled.contains).joined(separator: ",")
    }
}
