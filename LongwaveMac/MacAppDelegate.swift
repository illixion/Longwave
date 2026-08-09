import AppKit

/// Gives the full macOS app companion-style menu-bar behavior: a Dock icon
/// while any real window is open (`.regular`), but menu-bar-only with no Dock
/// presence when all windows are closed (`.accessory`). The `MenuBarExtra`
/// keeps the process alive in that state. Reopening from Finder/Dock while
/// running headless summons the main window again.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Posted when the app is reopened with no visible windows; the MenuBarExtra
    /// content view (always alive) observes it and calls `openWindow("main")`,
    /// since `openWindow` isn't reachable from an AppKit delegate.
    static let summonMainWindow = Notification.Name("LongwaveMac.summonMainWindow")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification] {
            nc.addObserver(self, selector: #selector(refreshActivationPolicy), name: name, object: nil)
        }
        refreshActivationPolicy()
    }

    /// `.regular` (Dock icon) iff at least one real app window is open, else
    /// `.accessory` (menu-bar only). Deferred so a `willClose` window is gone
    /// from `NSApp.windows` before we count.
    @objc private func refreshActivationPolicy() {
        DispatchQueue.main.async {
            let hasWindow = NSApp.windows.contains { $0.isVisible && Self.isRealAppWindow($0) }
            let desired: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
            if NSApp.activationPolicy() != desired {
                NSApp.setActivationPolicy(desired)
                if desired == .regular { NSApp.activate(ignoringOtherApps: true) }
            }
        }
    }

    /// Excludes the MenuBarExtra status-item window, popovers, and panels —
    /// only real document/WindowGroup windows should keep the Dock icon.
    private static func isRealAppWindow(_ w: NSWindow) -> Bool {
        guard w.canBecomeMain else { return false }
        let cls = String(describing: type(of: w))
        if cls.contains("StatusBar") || cls.contains("MenuBarExtra") || cls.contains("Popover") {
            return false
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NotificationCenter.default.post(name: Self.summonMainWindow, object: nil)
        }
        return true
    }
}
