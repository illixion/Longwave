import RAVEConsole
import SwiftUI

/// Console tab: a live view of this app's own log lines.
///
/// The viewer is RAVEConsole, which tails DebugTrace's in-memory log buffer —
/// every `DebugLogger` line, debug included (see `AppLog`). Lines from Apple
/// frameworks and packages still on `os.Logger` are not shown; a debug trace
/// carries them.
struct ConsoleTabView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RAVEConsoleScreen { openWindow(id: "console") }
    }
}

/// The console in its dedicated window. No pop-out button: this is the pop-out.
struct ConsoleWindowView: View {
    var body: some View {
        RAVEConsoleScreen()
    }
}
