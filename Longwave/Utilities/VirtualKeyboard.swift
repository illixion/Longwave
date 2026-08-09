#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The transport-independent model behind our own on-screen keyboard.
///
/// The system software keyboard can't express modifiers: it hands us text, and
/// text is all we could forward — so a latched Ctrl plus a typed "g" arrived at
/// the remote as a plain "g" (worse with the Mac companion, whose Unicode
/// injection has no modifier field at all). Owning the key caps means every tap
/// is a *key*, not a character, and the modifiers latched here are wrapped
/// around it as real key events by the per-transport sinks.

/// Modifiers our on-screen keyboard can apply, independent of VNC keysyms and
/// Moonlight virtual-key codes.
nonisolated struct VirtualModifiers: OptionSet, Sendable, Hashable {
    let rawValue: Int

    static let shift   = VirtualModifiers(rawValue: 1 << 0)
    static let control = VirtualModifiers(rawValue: 1 << 1)
    static let option  = VirtualModifiers(rawValue: 1 << 2)
    static let command = VirtualModifiers(rawValue: 1 << 3)

    /// Press/release order for wrapping a keystroke — released in reverse, so a
    /// combo unwinds the way a physical keyboard does.
    static let pressOrder: [VirtualModifiers] = [.control, .option, .shift, .command]

    /// The individual modifiers in this set, in `pressOrder`.
    var ordered: [VirtualModifiers] { Self.pressOrder.filter(contains) }
}

/// A key on the on-screen keyboard, named by what it does rather than by any
/// one protocol's code for it.
nonisolated enum VirtualKey: Hashable, Sendable {
    /// A character-producing key, identified by the glyph it types unshifted and
    /// the glyph it types with Shift. Both are kept: VNC wants the *shifted*
    /// keysym (`XK_G` for "G"), Moonlight wants the *unshifted* physical key
    /// (`VK_G`) plus a shift bit.
    case character(base: Character, shifted: Character)
    case `return`, tab, escape, backspace, forwardDelete, capsLock
    case up, down, left, right
    case home, end, pageUp, pageDown, insert
    case function(Int)

    /// The glyph this key types under the given modifier state, or nil for keys
    /// that don't produce text.
    func character(shifted: Bool) -> Character? {
        guard case .character(let base, let shift) = self else { return nil }
        return shifted ? shift : base
    }
}

/// One key cap in a layout row: what it does, how it's labelled, and how wide it
/// is in key units (1 = a letter key).
nonisolated struct VirtualKeyCap: Identifiable, Sendable {
    enum Action: Hashable, Sendable {
        case key(VirtualKey)
        case modifier(VirtualModifiers)
        /// Types the clipboard's contents — the one thing the text field we
        /// replaced could do that a grid of keys can't.
        case paste
    }

    let id: String
    let action: Action
    let label: String
    /// Label shown while Shift is active — letters go uppercase, the number row
    /// shows its punctuation, so the keyboard reads the way it will type.
    let shiftedLabel: String?
    let width: Double

    init(id: String, action: Action, label: String, shiftedLabel: String? = nil, width: Double = 1) {
        self.id = id
        self.action = action
        self.label = label
        self.shiftedLabel = shiftedLabel
        self.width = width
    }

    /// A character key, labelled with the glyphs it types.
    static func char(_ base: Character, _ shifted: Character, width: Double = 1) -> VirtualKeyCap {
        .init(id: "char-\(base)",
              action: .key(.character(base: base, shifted: shifted)),
              label: String(base),
              shiftedLabel: String(shifted),
              width: width)
    }

    /// A letter key — shifted glyph is just its uppercase form.
    static func letter(_ base: Character) -> VirtualKeyCap {
        char(base, Character(base.uppercased()))
    }

    func displayLabel(shifted: Bool) -> String {
        shifted ? (shiftedLabel ?? label) : label
    }

    var modifier: VirtualModifiers? {
        if case .modifier(let m) = action { return m }
        return nil
    }
}

/// A key plus whether Shift is needed to make it type a particular glyph.
nonisolated struct VirtualKeyStroke: Hashable, Sendable {
    let key: VirtualKey
    let shift: Bool
}

/// US ANSI layout, split into the main block and the navigation cluster that
/// sits to its right. Rows are rendered at fixed key metrics, so every row of
/// the main block is the same 15 units wide.
nonisolated enum VirtualKeyboardLayout {
    /// Width of every main-block row, in key units.
    static let mainRowUnits: Double = 15
    /// Width of the navigation cluster, in key units.
    static let navRowUnits: Double = 3

    static let mainRows: [[VirtualKeyCap]] = [
        [
            .init(id: "esc", action: .key(.escape), label: "esc", width: 1.5),
            .init(id: "f1", action: .key(.function(1)), label: "F1"),
            .init(id: "f2", action: .key(.function(2)), label: "F2"),
            .init(id: "f3", action: .key(.function(3)), label: "F3"),
            .init(id: "f4", action: .key(.function(4)), label: "F4"),
            .init(id: "f5", action: .key(.function(5)), label: "F5"),
            .init(id: "f6", action: .key(.function(6)), label: "F6"),
            .init(id: "f7", action: .key(.function(7)), label: "F7"),
            .init(id: "f8", action: .key(.function(8)), label: "F8"),
            .init(id: "f9", action: .key(.function(9)), label: "F9"),
            .init(id: "f10", action: .key(.function(10)), label: "F10"),
            .init(id: "f11", action: .key(.function(11)), label: "F11"),
            .init(id: "f12", action: .key(.function(12)), label: "F12"),
            .init(id: "paste", action: .paste, label: "paste", width: 1.5),
        ],
        [
            .char("`", "~"), .char("1", "!"), .char("2", "@"), .char("3", "#"),
            .char("4", "$"), .char("5", "%"), .char("6", "^"), .char("7", "&"),
            .char("8", "*"), .char("9", "("), .char("0", ")"), .char("-", "_"),
            .char("=", "+"),
            .init(id: "backspace", action: .key(.backspace), label: "⌫", width: 2),
        ],
        [
            .init(id: "tab", action: .key(.tab), label: "⇥", width: 1.5),
            .letter("q"), .letter("w"), .letter("e"), .letter("r"), .letter("t"),
            .letter("y"), .letter("u"), .letter("i"), .letter("o"), .letter("p"),
            .char("[", "{"), .char("]", "}"),
            .char("\\", "|", width: 1.5),
        ],
        [
            .init(id: "caps", action: .key(.capsLock), label: "⇪", width: 1.75),
            .letter("a"), .letter("s"), .letter("d"), .letter("f"), .letter("g"),
            .letter("h"), .letter("j"), .letter("k"), .letter("l"),
            .char(";", ":"), .char("'", "\""),
            .init(id: "return", action: .key(.return), label: "⏎", width: 2.25),
        ],
        [
            .init(id: "shift", action: .modifier(.shift), label: "⇧", width: 2.25),
            .letter("z"), .letter("x"), .letter("c"), .letter("v"), .letter("b"),
            .letter("n"), .letter("m"),
            .char(",", "<"), .char(".", ">"), .char("/", "?"),
            .init(id: "shift-r", action: .modifier(.shift), label: "⇧", width: 2.75),
        ],
        [
            .init(id: "ctrl-l", action: .modifier(.control), label: "ctrl", width: 1.75),
            .init(id: "opt", action: .modifier(.option), label: "⌥", width: 1.5),
            .init(id: "cmd", action: .modifier(.command), label: "⌘", width: 1.5),
            .char(" ", " ", width: 6),
            .init(id: "cmd-r", action: .modifier(.command), label: "⌘", width: 1.5),
            .init(id: "opt-r", action: .modifier(.option), label: "⌥", width: 1.5),
            .init(id: "ctrl-r", action: .modifier(.control), label: "ctrl", width: 1.25),
        ],
    ]

    /// The cluster beside the main block. `nil` is a gap, keeping the rows
    /// aligned with the main block's rows.
    static let navRows: [[VirtualKeyCap?]] = [
        // Spelled out rather than ⇞/⇟/↖/↘: at key size those glyphs are near
        // impossible to tell apart.
        [
            .init(id: "insert", action: .key(.insert), label: "ins"),
            .init(id: "home", action: .key(.home), label: "home"),
            .init(id: "pageup", action: .key(.pageUp), label: "pg↑"),
        ],
        [
            .init(id: "fwddel", action: .key(.forwardDelete), label: "⌦"),
            .init(id: "end", action: .key(.end), label: "end"),
            .init(id: "pagedown", action: .key(.pageDown), label: "pg↓"),
        ],
        [nil, nil, nil],
        [nil, nil, nil],
        [nil, .init(id: "up", action: .key(.up), label: "↑"), nil],
        [
            .init(id: "left", action: .key(.left), label: "←"),
            .init(id: "down", action: .key(.down), label: "↓"),
            .init(id: "right", action: .key(.right), label: "→"),
        ],
    ]

    /// Which key types a given glyph, and whether it needs Shift. Lets a
    /// transport that only speaks physical keys (Moonlight's VK codes) type
    /// literal text — "!" is the 1 key with Shift, not a key of its own.
    static func stroke(typing character: Character) -> VirtualKeyStroke? {
        strokeIndex[character]
    }

    private static let strokeIndex: [Character: VirtualKeyStroke] = {
        var index = [Character: VirtualKeyStroke]()
        for cap in mainRows.flatMap({ $0 }) {
            guard case .key(let key) = cap.action,
                  case .character(let base, let shifted) = key else { continue }
            index[base] = VirtualKeyStroke(key: key, shift: false)
            if shifted != base {
                index[shifted] = VirtualKeyStroke(key: key, shift: true)
            }
        }
        return index
    }()
}

/// Three-state modifier latches, like a soft keyboard's Shift: off → one-shot →
/// locked → off.
///
/// One-shot arming is purely local — the modifier is pressed and released around
/// the next keystroke, so it can never get stuck down on the remote. Locking
/// genuinely holds the key down there, which is what makes ⌃-click and ⌥-drag in
/// the stream window work while the keyboard window is open.
nonisolated struct VirtualModifierLatch: Equatable, Sendable {
    private(set) var oneShot: VirtualModifiers = []
    private(set) var locked: VirtualModifiers = []

    /// Everything that applies to the next keystroke.
    var active: VirtualModifiers { oneShot.union(locked) }

    /// What the remote must be told after a tap.
    enum Effect: Equatable, Sendable {
        case none
        case hold(VirtualModifiers)
        case release(VirtualModifiers)
    }

    init() {}

    mutating func tap(_ modifier: VirtualModifiers) -> Effect {
        if locked.contains(modifier) {
            locked.remove(modifier)
            return .release(modifier)
        }
        if oneShot.contains(modifier) {
            oneShot.remove(modifier)
            locked.insert(modifier)
            return .hold(modifier)
        }
        oneShot.insert(modifier)
        return .none
    }

    func state(of modifier: VirtualModifiers) -> State {
        if locked.contains(modifier) { return .locked }
        if oneShot.contains(modifier) { return .oneShot }
        return .off
    }

    enum State: Sendable { case off, oneShot, locked }

    /// Take the one-shot modifiers for a keystroke, clearing them. Locked ones
    /// stay — they're already down on the remote.
    mutating func consumeOneShot() -> VirtualModifiers {
        defer { oneShot = [] }
        return oneShot
    }

    /// Clear every latch, returning the locked set the caller must release on
    /// the remote.
    mutating func reset() -> VirtualModifiers {
        defer {
            oneShot = []
            locked = []
        }
        return locked
    }
}
