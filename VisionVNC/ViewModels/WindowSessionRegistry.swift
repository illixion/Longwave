import SwiftUI

/// The main ("Connections") window is value-typed with a single constant
/// identity. Every request to surface it opens with `MainWindowID.shared`, so
/// visionOS reactivates the one existing main window instead of minting a
/// duplicate — even when that window is buried in a `pushWindow` back-stack
/// (the case that let the Home button spawn extra main windows). Value-matching
/// enforces the one-window limit structurally, so no after-the-fact culling of
/// stale instances is needed.
enum MainWindowID: Int, Codable, Hashable {
    case shared = 0
}

/// Tracks which of the app's windows are currently open and whether each is
/// in the user's current room, so the Sessions tab can "summon" a window back
/// to the user. On visionOS a window can be snapped in another room and become
/// unreachable until you physically return there; calling `openWindow(id:)` on
/// an already-open window brings it to the user's current position — the same
/// mechanic SpatialStash uses.
@Observable
@MainActor
final class WindowSessionRegistry {
    static let shared = WindowSessionRegistry()

    /// Open window ids → `true` when the window is in the user's current room
    /// (its scene phase is `.active`), `false` when snapped in another room.
    private(set) var sessions: [String: Bool] = [:]

    /// Number of currently-open "main" windows. When this is zero the user has
    /// no way to navigate the app, so a home-screen re-launch must summon one.
    private(set) var mainWindowCount: Int = 0

    /// Most recently captured `openWindow` action from a SwiftUI view. Every
    /// window's root refreshes this on appear so a lifecycle hook can summon
    /// the main window even when only pop-out scenes are connected (the main
    /// window's own action disappears with it).
    var openWindow: OpenWindowAction?

    private init() {}

    // MARK: - Main window lifecycle

    func registerMainWindow() {
        mainWindowCount += 1
    }

    func unregisterMainWindow() {
        mainWindowCount = max(0, mainWindowCount - 1)
    }

    /// Summons a main window if none is currently open. Safe to call from
    /// app/scene lifecycle hooks; no-ops when a main window already exists.
    ///
    /// This is the home-screen re-invoke fix: on visionOS, tapping the app
    /// icon while the only open window is a pop-out snapped in another room
    /// merely reactivates that far-away scene — no main window appears and the
    /// app looks dead. Re-opening "main" brings a usable window to the user.
    func ensureMainWindowVisible() {
        guard mainWindowCount == 0 else { return }
        guard let openWindow else {
            AppLog.app.line("ensureMainWindowVisible: no openWindow action captured")
            return
        }
        AppLog.app.line("ensureMainWindowVisible: summoning main window")
        openWindow(id: "main", value: MainWindowID.shared)
    }

    /// Window ids the user can summon, in display order. Excludes "main"
    /// (the Sessions list itself lives there) and any window not open.
    var summonableIDs: [String] {
        WindowSessionRegistry.catalog
            .map(\.id)
            .filter { sessions[$0] != nil }
    }

    func register(_ id: String) {
        sessions[id] = true
    }

    func unregister(_ id: String) {
        sessions[id] = nil
    }

    func setActiveRoom(_ id: String, _ active: Bool) {
        guard sessions[id] != nil else { return }
        sessions[id] = active
    }

    func isInActiveRoom(_ id: String) -> Bool {
        sessions[id] ?? true
    }

    // MARK: - Display catalog

    /// Static description of each summonable window: id, label, and SF Symbol.
    /// Subtitles (connection names) are resolved live by the Sessions view.
    struct WindowKind: Identifiable {
        let id: String
        let title: String
        let systemImage: String
    }

    static let catalog: [WindowKind] = {
        var kinds: [WindowKind] = [
            WindowKind(id: "remote-desktop", title: "Remote Desktop", systemImage: "display"),
        ]
        #if MOONLIGHT_ENABLED
        kinds.append(WindowKind(id: "moonlight-stream", title: "Game Stream", systemImage: "gamecontroller"))
        #endif
        kinds.append(WindowKind(id: "audio-stream", title: "Audio Stream", systemImage: "hifispeaker"))
        kinds.append(WindowKind(id: "keyboard", title: "Keyboard", systemImage: "keyboard"))
        #if MOONLIGHT_ENABLED
        kinds.append(WindowKind(id: "moonlight-keyboard", title: "Game Keyboard", systemImage: "keyboard"))
        #endif
        kinds.append(WindowKind(id: "console", title: "Console", systemImage: "terminal"))
        return kinds
    }()

    static func kind(for id: String) -> WindowKind? {
        catalog.first { $0.id == id }
    }
}

/// Registers a window with `WindowSessionRegistry` for its lifetime and keeps
/// its room status (scene phase) up to date. Apply to each window's root view.
private struct TrackWindowSession: ViewModifier {
    let id: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                WindowSessionRegistry.shared.register(id)
                // Keep a live openWindow reference from whichever scene is
                // rendered, so the main window can be summoned even when only
                // pop-outs remain connected.
                WindowSessionRegistry.shared.openWindow = openWindow
            }
            .onDisappear {
                WindowSessionRegistry.shared.unregister(id)
            }
            .onChange(of: scenePhase) { _, phase in
                WindowSessionRegistry.shared.setActiveRoom(id, phase == .active)
            }
    }
}

/// Tracks the main window's presence (and refreshes the captured `openWindow`
/// action) so `ensureMainWindowVisible()` knows when to summon one.
private struct TrackMainWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                WindowSessionRegistry.shared.registerMainWindow()
                WindowSessionRegistry.shared.openWindow = openWindow
            }
            .onDisappear {
                WindowSessionRegistry.shared.unregisterMainWindow()
            }
    }
}

extension View {
    /// Tracks this window in `WindowSessionRegistry` so it can be summoned
    /// from the Sessions tab.
    func trackWindowSession(id: String) -> some View {
        modifier(TrackWindowSession(id: id))
    }

    /// Tracks the main window so a home-screen re-launch can re-summon it when
    /// only pop-out windows are connected.
    func trackMainWindow() -> some View {
        modifier(TrackMainWindow())
    }
}
