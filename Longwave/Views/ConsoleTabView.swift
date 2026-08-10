import RAVEConsole
import SwiftUI

/// Console tab: a live view of this app's os_log output.
///
/// The viewer itself is RAVEConsole now — it was one of three independent
/// implementations of the same OSLogStore-polling screen across these apps.
/// Its level and category filters and its clipboard export are new here; this
/// copy had auto-scroll and a level picker only.
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
