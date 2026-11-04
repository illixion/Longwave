import SwiftUI
#if os(visionOS)
import RAVEUI
#endif

/// Opening a session window from the main (Connections) window.
///
/// On visionOS a session window takes the main window's place: RAVEUI's
/// window push opens it and hides the main window behind it, and closing the
/// session window by any route (its own Disconnect, the system close button,
/// a teardown) brings the main window back where it was. Home buttons reveal
/// the main window *beside* a session that keeps running
/// (`WindowSessionRegistry.surface("main", using:)`), which is why a push here
/// never tears a session down — the failure that made the app drop SwiftUI's
/// `pushWindow` in July 2026, before visionOS 27 broke that API outright.
///
/// Companion windows a session opens for itself (keyboards, audio pop-outs,
/// Unity window streams) stay ordinary sibling windows: they exist to be used
/// next to the stream, not instead of it.
///
/// macOS and iOS have no such push, so there it is a plain `openWindow`.
@MainActor
struct SessionWindowPushAction {
    #if os(visionOS)
    let push: RAVEPushWindowAction

    func callAsFunction(id: String) { push(id: id) }
    func callAsFunction<V: Codable & Hashable>(id: String, value: V) { push(id: id, value: value) }
    #else
    let open: OpenWindowAction

    func callAsFunction(id: String) { open(id: id) }
    func callAsFunction<V: Codable & Hashable>(id: String, value: V) { open(id: id, value: value) }
    #endif
}

/// Declare as `@PushSessionWindow private var pushSessionWindow`.
@propertyWrapper
struct PushSessionWindow: DynamicProperty {
    #if os(visionOS)
    @Environment(\.ravePushWindow) private var push
    var wrappedValue: SessionWindowPushAction { SessionWindowPushAction(push: push) }
    #else
    @Environment(\.openWindow) private var open
    var wrappedValue: SessionWindowPushAction { SessionWindowPushAction(open: open) }
    #endif

    init() {}
}

extension View {
    /// Take part in session window pushes: the main window hides behind the
    /// session window it pushed, and a session window claims the push meant
    /// for it. `sceneID` and `value` are what the scene was opened with.
    @ViewBuilder
    func sessionWindowPushHost(sceneID: String, value: (any Hashable)? = nil) -> some View {
        #if os(visionOS)
        raveWindowPushHost(sceneID: sceneID, value: value)
        #else
        self
        #endif
    }
}
