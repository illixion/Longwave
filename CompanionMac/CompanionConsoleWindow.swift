import AppKit
import RAVEConsole
import SwiftUI

/// The standalone companion's log console: RAVEConsole in a plain AppKit
/// window, opened from the menu bar popover.
///
/// It isn't a SwiftUI `Window` scene because a menu-bar-only app can't keep
/// one from opening at launch before macOS 15 (`defaultLaunchBehavior`), and
/// the companion targets 14.2. Like the Settings window, it makes the app a
/// regular one (dock icon, Cmd-Tab) while open and returns it to menu-bar-only
/// when it closes. LongwaveMac has its own console pane and doesn't use this.
@MainActor
final class CompanionConsoleWindow: NSObject, NSWindowDelegate {
    static let shared = CompanionConsoleWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: RAVEConsoleScreen()))
            window.title = "Longwave Companion Console"
            window.setContentSize(NSSize(width: 900, height: 560))
            window.setFrameAutosaveName("CompanionConsole")
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Dropping the hosting controller ends the console's viewer
        // registration, so a closed console stops polling.
        window?.contentViewController = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
