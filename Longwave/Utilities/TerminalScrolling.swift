import SwiftTerm

/// A fast flick can resolve to a lot of notches at once — cap the burst so a
/// single gesture update can't dump hundreds of escape sequences into the pty.
/// Sized to clear a page on a tall terminal, which is the largest legitimate
/// single request (see `scrollPage`).
private let maxWheelEventsPerScroll = 32

/// How far one wheel notch moves. Programs that take wheel events move about
/// three lines per notch (tmux's copy-mode included), so a drag worth three
/// lines has to be *one* event — sending three would scroll three times as far
/// as the finger moved.
let linesPerWheelNotch = 3

extension TerminalView {
    /// Whether the remote program turned on mouse tracking. When it has, it owns
    /// scrolling: its screen lives in the alternate buffer, where the emulator has
    /// no scrollback to offer, and only the program can move its own viewport.
    var remoteTracksMouse: Bool {
        switch getTerminal().mouseMode {
        case .off: return false
        default: return true
        }
    }

    /// Scroll by whole lines — positive moves toward earlier output.
    ///
    /// Which of two destinations gets it depends on what the remote asked for. A
    /// plain terminal (the default agent CLI included) scrolls the emulator's own
    /// scrollback; a program that enabled mouse tracking gets real wheel events
    /// instead, reported at `cell` — the terminal cell under the gesture, or the
    /// middle of the screen when there isn't one.
    ///
    /// Returns false when neither applies: an alternate-screen program that never
    /// asked for mouse events has a viewport nothing here can move. Callers with a
    /// keyboard fallback (the paging buttons) can act on that.
    @discardableResult
    func scrollBySteps(_ steps: Int, reportingAt cell: (col: Int, row: Int)? = nil) -> Bool {
        guard steps != 0 else { return true }
        let terminal = getTerminal()

        guard remoteTracksMouse else {
            guard !terminal.isCurrentBufferAlternate else { return false }
            if steps > 0 {
                scrollUp(lines: steps)
            } else {
                scrollDown(lines: -steps)
            }
            return true
        }

        let target = cell ?? (col: terminal.cols / 2, row: terminal.rows / 2)
        // X11 wheel buttons: 4 scrolls up (toward earlier output), 5 down. They
        // are reported as presses with no matching release, as a real wheel is.
        let flags = terminal.encodeButton(button: steps > 0 ? 4 : 5, release: false,
                                          shift: false, meta: false, control: false)
        for _ in 0..<min(abs(steps), maxWheelEventsPerScroll) {
            terminal.sendEvent(buttonFlags: flags, x: target.col, y: target.row)
        }
        return true
    }

    /// How far one step moves, in lines. Locally a step is a line; a program
    /// taking wheel events moves a notch's worth. Callers that think in lines —
    /// a page, a drag across the screen — divide by this.
    var linesPerScrollStep: Int { remoteTracksMouse ? linesPerWheelNotch : 1 }

    /// A screenful, for the gaze-friendly paging buttons. Falls back to
    /// PageUp/PageDown keys (SwiftTerm's own paging) for an alternate-screen
    /// program with no mouse tracking, which is the only thing left to try.
    func scrollPage(up: Bool) {
        let steps = max(1, max(1, getTerminal().rows) / linesPerScrollStep)
        if scrollBySteps(up ? steps : -steps) { return }
        if up { pageUp() } else { pageDown() }
    }
}
