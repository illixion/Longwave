import SwiftTerm

/// One wheel event per line is what a real mouse produces, but a fast flick can
/// resolve to a lot of lines at once — cap the burst so a single gesture update
/// can't dump hundreds of escape sequences into the pty.
private let maxWheelEventsPerScroll = 8

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
    func scrollByLines(_ lines: Int, reportingAt cell: (col: Int, row: Int)? = nil) -> Bool {
        guard lines != 0 else { return true }
        let terminal = getTerminal()

        guard remoteTracksMouse else {
            guard !terminal.isCurrentBufferAlternate else { return false }
            if lines > 0 {
                scrollUp(lines: lines)
            } else {
                scrollDown(lines: -lines)
            }
            return true
        }

        let target = cell ?? (col: terminal.cols / 2, row: terminal.rows / 2)
        // X11 wheel buttons: 4 scrolls up (toward earlier output), 5 down. They
        // are reported as presses with no matching release, as a real wheel is.
        let flags = terminal.encodeButton(button: lines > 0 ? 4 : 5, release: false,
                                          shift: false, meta: false, control: false)
        for _ in 0..<min(abs(lines), maxWheelEventsPerScroll) {
            terminal.sendEvent(buttonFlags: flags, x: target.col, y: target.row)
        }
        return true
    }

    /// A screenful, for the gaze-friendly paging buttons. Falls back to
    /// PageUp/PageDown keys (SwiftTerm's own paging) for an alternate-screen
    /// program with no mouse tracking, which is the only thing left to try.
    func scrollPage(up: Bool) {
        let lines = max(1, getTerminal().rows)
        if scrollByLines(up ? lines : -lines) { return }
        if up { pageUp() } else { pageDown() }
    }
}
