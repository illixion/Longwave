import SwiftUI

/// The main ("Connections") window is value-typed with a single constant
/// identity. Every request to surface it opens with `MainWindowID.shared`, so
/// visionOS reactivates the one existing main window instead of minting a
/// duplicate when a Home button is tapped repeatedly. Value-matching enforces
/// the one-window limit structurally, so no after-the-fact culling of stale
/// instances is needed.
enum MainWindowID: Int, Codable, Hashable {
    case shared = 0
}

/// The PCVR controls window, same trick. It was reachable from three places — the
/// connection list, the wrist HUD, and the Sessions tab — and each plain
/// `openWindow(id:)` minted another copy, so a session could end up with several
/// stacked control panels arguing over one connection.
enum PCVRWindowID: Int, Codable, Hashable {
    case shared = 0
}

enum MacNativeWindowID: Int, Codable, Hashable {
    case shared = 0
}

/// Value key for the per-window (Unity-style) Native scenes — one visionOS
/// window per streamed host window, keyed by the host's window ID so
/// repeated opens of the same host window reactivate its one scene.
struct MacNativeWindowStreamID: Codable, Hashable {
    let windowID: UInt32
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

    /// Surfaces the main window and runs `close` only once main is actually on
    /// screen.
    ///
    /// visionOS refuses to let an app close its own last window, so every
    /// session-teardown path has to open a main window first. But `openWindow`
    /// is asynchronous — the scene is created a turn or more later — so a
    /// `dismissWindow` issued in the same turn can still be evaluated while
    /// the closing window *is* the last one, and the close is silently
    /// dropped: the session window stays up (and, with the pushWindow
    /// back-stack gone, nothing else pops it). Waiting for the main window
    /// root's `onAppear` (i.e. `registerMainWindow()`) makes the handoff
    /// ordered instead of racy.
    ///
    /// When main is already open this closes synchronously, so the common case
    /// keeps its current single-turn behavior.
    func closeAfterSurfacingMain(
        using openWindow: OpenWindowAction,
        _ close: @escaping @MainActor () -> Void
    ) {
        openWindow(id: "main", value: MainWindowID.shared)
        guard mainWindowCount == 0 else {
            close()
            return
        }
        Task { @MainActor in
            // Bounded wait: if the main window never materializes, close
            // anyway rather than leaving the user stuck in a dead session.
            var waitedMS = 0
            while mainWindowCount == 0, waitedMS < Self.mainWindowWaitTimeoutMS {
                try? await Task.sleep(for: .milliseconds(Self.mainWindowPollMS))
                waitedMS += Self.mainWindowPollMS
            }
            if mainWindowCount == 0 {
                AppLog.app.line("closeAfterSurfacingMain: main window never appeared; closing anyway")
            }
            close()
        }
    }

    private static let mainWindowPollMS = 50
    private static let mainWindowWaitTimeoutMS = 3_000

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
    /// Opens a window by id, using the value form for the ones whose `WindowGroup` is
    /// value-matched to a single identity. Callers that only know an id string (the
    /// Sessions tab iterates the catalog) must go through this: `openWindow(id:)` alone
    /// against a `WindowGroup(for:)` does nothing at all, and a plain id against a
    /// value-matched group is exactly the duplicate-window bug this exists to prevent.
    static func surface(_ id: String, using openWindow: OpenWindowAction) {
        switch id {
        case "main": openWindow(id: id, value: MainWindowID.shared)
        case "foveated-controls": openWindow(id: id, value: PCVRWindowID.shared)
        default: openWindow(id: id)
        }
    }

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
        #if FOVEATED_ENABLED
        kinds.append(WindowKind(id: "foveated-controls", title: "PCVR Controls", systemImage: "visionpro"))
        #endif
        #if os(visionOS)
        kinds.append(WindowKind(id: "mac-native-stream", title: "Native", systemImage: "macwindow.on.rectangle"))
        #endif
        // On visionOS this only opens via the Native window's pop-out
        // button; on macOS (no Screen receiver) a Native connection opens
        // it directly.
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
