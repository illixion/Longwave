#if os(visionOS)
import DebugTrace
import Foundation
import Observation
import RAVEInput

/// Drives the Mac's cursor from a Bluetooth/USB mouse read raw through
/// GameController's `GCMouse` (via RAVEInput's `RAVEMouseSource`, which owns
/// the device handlers app-wide), the way a game reads one: motion deltas move
/// the cursor relative to where it is, and buttons and the wheel act there.
/// It bypasses the desktop's touch paths entirely, flat or curved, in either
/// touch mode.
///
/// What the system pointer is over still matters, for two reasons:
/// - visionOS sends the pointer to whatever the gaze ray hits, and the
///   desktop needs something there for it to land on. The curved mesh
///   turned clicks into gaze pinches, and a fully transparent view is
///   skipped. `MouseHitTarget` is the faintly painted layer the pointer
///   sits on instead.
/// - `GCMouse` doesn't know about the app's UI, so a click on the controls
///   ornament would also click the Mac. Presses are held back while the
///   pointer is over the ornament (`pointerOverControls`). Motion never is.
///   A first build gated motion on that as well, and the pointer, with
///   nowhere else to go, sat on the ornament, so nothing moved.
@MainActor
@Observable
final class MacNativeMouseBridge {
    private(set) var isConnected = false

    /// The user's choice: the mouse drives the Mac, or is left to visionOS
    /// (the ornament's Mouse toggle). Persisted.
    var captureEnabled: Bool = UserDefaults.standard.object(forKey: MacNativeMouseBridge.captureKey) as? Bool ?? true {
        didSet {
            guard captureEnabled != oldValue else { return }
            UserDefaults.standard.set(captureEnabled, forKey: Self.captureKey)
            releaseHeldButtons()
        }
    }

    /// Mouse mode: the desktop takes the mouse and its own touch paths stand aside.
    var ownsPointer: Bool { isConnected && captureEnabled }

    /// Set from the ornament's hover; holds back presses, not motion.
    @ObservationIgnored var pointerOverControls = false {
        didSet {
            guard pointerOverControls != oldValue else { return }
            AppLog.macNativeMouse.debug("Pointer \(self.pointerOverControls ? "on" : "off", privacy: .public) the controls")
        }
    }

    /// The Display popover is showing. It sits outside the controls, so
    /// their hover doesn't cover it: presses, motion and the wheel are held
    /// back, so working the menu leaves the Mac's cursor where it was, and
    /// the desktop takes its hit target down so the popover is never behind it.
    var menuOpen = false {
        didSet { if menuOpen { resetScroll() } }
    }

    /// Mouse input counts only while the window is streaming.
    @ObservationIgnored var streaming = false {
        didSet { if !streaming { releaseHeldButtons() } }
    }

    @ObservationIgnored private let manager: MacNativeStreamManager
    @ObservationIgnored private var subscription: RAVEMouseSubscription?
    @ObservationIgnored private var heldButtons = RAVEMouseButtonGate()
    @ObservationIgnored private var scrollRemainder = (x: RAVEMouseStepAccumulator(), y: RAVEMouseStepAccumulator())
    @ObservationIgnored private var motionEvents = 0
    @ObservationIgnored private var motionLogTask: Task<Void, Never>?

    private static let captureKey = "macNativeMouseCapture"

    /// Desktop points per raw count at slow speeds, and how much faster
    /// quick flicks travel. The Mac's own acceleration never sees these
    /// deltas, and 1:1 took several swipes to cross a 2560-wide display.
    private static let baseSpeed: Float = 1.2
    private static let acceleration: Float = 0.06
    private static let maxGain: Float = 4

    init(manager: MacNativeStreamManager) {
        self.manager = manager
    }

    private var forwarding: Bool { captureEnabled && streaming }

    // MARK: Lifecycle

    func start() {
        guard subscription == nil else { return }
        // Delivered on the main queue; picks up mice already connected.
        subscription = RAVEMouseSource.shared.subscribe { [weak self] event in
            self?.handle(event)
        }
        // How much motion actually arrives, for on-device checks: a line a
        // second while the mouse moves.
        motionLogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.motionEvents > 0 {
                    AppLog.macNativeMouse.debug("Motion events in the last second: \(self.motionEvents, privacy: .public)")
                    self.motionEvents = 0
                }
            }
        }
    }

    func stop() {
        releaseHeldButtons()
        motionLogTask?.cancel()
        motionLogTask = nil
        subscription?.cancel()
        subscription = nil
        isConnected = false
    }

    // MARK: Input

    private func handle(_ event: RAVEMouseEvent) {
        switch event {
        case .connected(_, let count):
            isConnected = true
            AppLog.macNativeMouse.info("Mouse connected (\(count, privacy: .public) total)")
        case .disconnected(_, let count):
            isConnected = count > 0
            if count == 0 { releaseHeldButtons() }
            AppLog.macNativeMouse.info("Mouse disconnected (\(count, privacy: .public) left)")
        case .moved(let dx, let dy):
            moved(dx: dx, dy: dy)
        case .button(.left, let pressed):
            buttonChanged(.left, pressed: pressed)
        case .button(.right, let pressed):
            buttonChanged(.right, pressed: pressed)
        case .button(.middle, let pressed):
            buttonChanged(.other, pressed: pressed)
        case .button(.auxiliary, _):
            break
        case .scroll(let x, let y):
            scrolled(x: x, y: y)
        }
    }

    private func moved(dx: Float, dy: Float) {
        motionEvents += 1
        guard forwarding, !menuOpen else { return }
        let speed = (dx * dx + dy * dy).squareRoot()
        let gain = Self.baseSpeed * min(1 + Self.acceleration * speed, Self.maxGain)
        // GCMouse is +Y up; the desktop is +Y down.
        manager.moveVirtualCursor(dx: CGFloat(dx * gain), dy: CGFloat(-dy * gain))
    }

    private func buttonChanged(_ button: MacNativeStreamProtocol.MouseButton, pressed: Bool) {
        if pressed {
            let onControls = pointerOverControls || menuOpen
            let sent = forwarding && !onControls
            AppLog.macNativeMouse.debug("Button \(button.rawValue, privacy: .public) down — \(sent ? "sent" : (onControls ? "held back: on the controls" : "held back: not streaming"), privacy: .public)")
            guard heldButtons.press(Self.key(button), allowed: sent) else { return }
            manager.pressMouseAtVirtualCursor(button: button)
        } else {
            // Release only what was pressed here, so nothing sticks.
            guard heldButtons.release(Self.key(button)) else { return }
            manager.releaseMouseAtVirtualCursor(button: button)
        }
    }

    /// Wheel detents arrive as whole units (a trackpad's as fractions), +Y
    /// away from the user — the host's "content moves down" sign already.
    private func scrolled(x: Float, y: Float) {
        guard forwarding, !menuOpen else { resetScroll(); return }
        let stepsX = scrollRemainder.x.add(x)
        let stepsY = scrollRemainder.y.add(y)
        guard stepsX != 0 || stepsY != 0 else { return }
        manager.scrollAtVirtualCursor(
            deltaX: Int16(clamping: max(-10, min(10, stepsX))),
            deltaY: Int16(clamping: max(-10, min(10, stepsY)))
        )
    }

    private func releaseHeldButtons() {
        for held in heldButtons.releaseAll() {
            switch held {
            case .left: manager.releaseMouseAtVirtualCursor(button: .left)
            case .right: manager.releaseMouseAtVirtualCursor(button: .right)
            case .middle: manager.releaseMouseAtVirtualCursor(button: .other)
            case .auxiliary: break
            }
        }
        resetScroll()
    }

    private func resetScroll() {
        scrollRemainder.x.reset()
        scrollRemainder.y.reset()
    }

    private static func key(_ button: MacNativeStreamProtocol.MouseButton) -> RAVEMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .other: .middle
        }
    }
}
extension MacNativeMouseBridge {
    private static var bridges: [ObjectIdentifier: MacNativeMouseBridge] = [:]

    /// The session's bridge — one per manager, shared by the desktop window
    /// and its controls, which may be in a window of their own.
    static func shared(for manager: MacNativeStreamManager) -> MacNativeMouseBridge {
        let key = ObjectIdentifier(manager)
        if let bridge = bridges[key] { return bridge }
        let bridge = MacNativeMouseBridge(manager: manager)
        bridges[key] = bridge
        return bridge
    }
}
#endif
