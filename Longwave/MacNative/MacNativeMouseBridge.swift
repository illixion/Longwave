#if os(visionOS)
import DebugTrace
import GameController

/// Whether a Bluetooth/USB mouse owns the Native desktop: one is connected
/// (GameController sees every mouse the system pairs) and the user hasn't
/// handed it back to visionOS with the ornament's Mouse toggle.
///
/// While it does, the desktop reads the mouse through `MousePointerSurface`,
/// UIKit's pointer events mapped onto the picture, and stands its touch paths
/// aside. On the curved desktop the mesh stops taking input as well, or a
/// mouse click on it lands where the gaze ray hits, not under the pointer.
///
/// The mouse's input isn't read here. `GCMouse` delivers it to a windowed
/// app only while a button is held, and the pointer lock that would lift
/// that isn't granted to a window (tried 2026-10-03).
@MainActor
@Observable
final class MacNativeMouseBridge {
    private(set) var isConnected = false

    /// The user's choice; persisted.
    var captureEnabled: Bool = UserDefaults.standard.object(forKey: MacNativeMouseBridge.captureKey) as? Bool ?? true {
        didSet {
            guard captureEnabled != oldValue else { return }
            UserDefaults.standard.set(captureEnabled, forKey: Self.captureKey)
        }
    }

    /// Mouse mode: the desktop takes the mouse and nothing else.
    var ownsPointer: Bool { isConnected && captureEnabled }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let captureKey = "macNativeMouseCapture"

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.GCMouseDidConnect, .GCMouseDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func refresh() {
        let connected = !GCMouse.mice().isEmpty
        guard connected != isConnected else { return }
        isConnected = connected
        AppLog.macNativeMouse.info("Mouse \(connected ? "connected" : "disconnected", privacy: .public)")
    }
}
#endif
