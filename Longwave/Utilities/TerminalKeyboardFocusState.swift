/// Keyboard-focus policy for the SSH terminal, kept apart from the platform
/// terminal views (which differ per OS) so both targets and the tests share one
/// definition.
///
/// `isEnabled` expresses intent — "the terminal should be taking keystrokes" —
/// while `hasFocus` mirrors what the platform actually made first responder. The
/// two are deliberately separate: dictation can make an input view resign
/// transiently, and treating that as "the user turned direct input off" is what
/// used to leave the toggle out of sync and abort dictation on the way back.
nonisolated struct TerminalKeyboardFocusState: Equatable {
    private(set) var isEnabled = false
    private(set) var requestID = 0
    private(set) var hasFocus = false
    /// Whether the outstanding request came from the user tapping the keyboard
    /// toggle. Deliberate requests may cut off text entry; automatic ones
    /// (window appeared, keyboard paired) must yield to it so dictation lives.
    private(set) var requestIsDeliberate = false

    /// Automatic request — yields to any live text entry.
    mutating func request() {
        isEnabled = true
        requestID &+= 1
        requestIsDeliberate = false
    }

    /// User-driven request — takes the keyboard even from a focused composer.
    mutating func requestDeliberately() {
        isEnabled = true
        requestID &+= 1
        requestIsDeliberate = true
    }

    mutating func release() {
        isEnabled = false
        hasFocus = false
        requestIsDeliberate = false
    }

    mutating func firstResponderChanged(_ focused: Bool) {
        hasFocus = focused
    }

    mutating func composerFocusChanged(_ focused: Bool) {
        if focused {
            release()
        }
    }
}
