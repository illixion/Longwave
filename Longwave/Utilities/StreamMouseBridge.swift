#if os(visionOS)
import DebugTrace
import Foundation
import Observation
import RAVEInput

/// Drives a remote desktop's cursor — VNC, Native or Moonlight, through
/// `RemotePointerTarget` — from a Bluetooth/USB mouse read raw through
/// GameController's `GCMouse` (via RAVEInput's `RAVEMouseSource`, which owns
/// the device handlers app-wide), the way a game reads one: motion deltas move
/// the cursor relative to where it is, and buttons and the wheel act there.
/// It bypasses the stream surface's touch paths entirely, flat or curved, in
/// either touch mode. This is the window's "Mouse" mode.
///
/// What the system pointer is over still matters, for two reasons:
/// - visionOS sends the pointer to whatever the gaze ray hits, and the
///   desktop needs something there for it to land on. A curved mesh turned
///   clicks into gaze pinches, and a fully transparent view is skipped.
///   `MouseHitTarget` is the faintly painted layer the pointer sits on, inside
///   the padded layout that keeps it off the window bar.
/// - `GCMouse` doesn't know about the app's UI, so a click on the controls
///   ornament would also click the remote. Presses are held back while the
///   pointer is over the ornament (`pointerOverControls`). Motion never is.
///   A first build gated motion on that as well, and the pointer, with
///   nowhere else to go, sat on the ornament, so nothing moved.
///
/// visionOS has no pointer lock for windowed apps (2026-10-07), so this layout
/// is as close to a lock as a window gets.
@MainActor
@Observable
final class StreamMouseBridge {
    /// How raw counts become cursor motion.
    enum Motion {
        /// Gain that grows with speed, for a desktop whose own acceleration
        /// never sees these deltas (VNC, Native): 1:1 took several swipes to
        /// cross a 2560-wide display.
        case accelerated
        /// Counts divided by a constant and sent as relative motion, for a
        /// host that applies its own curve and games that read raw input
        /// (Moonlight; the divisor matches moonlight-ios).
        case raw(divisor: Float)
    }

    private(set) var isConnected = false

    /// The user's choice: the mouse drives the remote, or is left to visionOS
    /// (the ornament's Mouse toggle). Persisted per connection type.
    var captureEnabled: Bool {
        didSet {
            guard captureEnabled != oldValue else { return }
            UserDefaults.standard.set(captureEnabled, forKey: captureKey)
            releaseHeldButtons()
        }
    }

    /// Mouse mode: the surface takes the mouse and its own touch paths stand aside.
    var ownsPointer: Bool { isConnected && captureEnabled }

    /// Set from the ornament's hover; holds back presses, not motion.
    @ObservationIgnored var pointerOverControls = false {
        didSet {
            guard pointerOverControls != oldValue else { return }
            AppLog.streamMouse.debug("Pointer \(self.pointerOverControls ? "on" : "off", privacy: .public) the controls")
        }
    }

    /// A popover from the controls is showing (Native's Display menu). It sits
    /// outside the controls, so their hover doesn't cover it: presses, motion
    /// and the wheel are held back, so working the menu leaves the remote
    /// cursor where it was, and the surface takes its hit target down so the
    /// popover is never behind it.
    var menuOpen = false {
        didSet { if menuOpen { resetScroll() } }
    }

    /// Mouse input counts only while the window is streaming.
    @ObservationIgnored var streaming = false {
        didSet { if !streaming { releaseHeldButtons() } }
    }

    /// Extra say over whether input goes out: Moonlight forwards only from
    /// the session that holds input focus, since `GCMouse` is app-wide.
    @ObservationIgnored var inputAllowed: () -> Bool = { true }

    @ObservationIgnored private weak var target: (any RemotePointerTarget)?
    @ObservationIgnored private let motion: Motion
    @ObservationIgnored private let captureKey: String
    @ObservationIgnored private var subscription: RAVEMouseSubscription?
    @ObservationIgnored private var heldButtons = RAVEMouseButtonGate()
    @ObservationIgnored private var scrollRemainder = (x: RAVEMouseStepAccumulator(), y: RAVEMouseStepAccumulator())
    @ObservationIgnored private var motionEvents = 0
    @ObservationIgnored private var motionLogTask: Task<Void, Never>?

    /// Desktop points per raw count at slow speeds, and how much faster
    /// quick flicks travel (`Motion.accelerated`).
    private static let baseSpeed: Float = 1.2
    private static let acceleration: Float = 0.06
    private static let maxGain: Float = 4

    init(target: any RemotePointerTarget, motion: Motion, captureKey: String) {
        self.target = target
        self.motion = motion
        self.captureKey = captureKey
        captureEnabled = UserDefaults.standard.object(forKey: captureKey) as? Bool ?? true
    }

    private var forwarding: Bool { captureEnabled && streaming && inputAllowed() }

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
                    AppLog.streamMouse.debug("Motion events in the last second: \(self.motionEvents, privacy: .public)")
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

    /// Lets go of anything pressed here — for a session losing input focus.
    func releaseHeldButtons() {
        for held in heldButtons.releaseAll() {
            target?.pointerButton(Self.button(held), pressed: false)
        }
        resetScroll()
    }

    // MARK: Input

    private func handle(_ event: RAVEMouseEvent) {
        switch event {
        case .connected(_, let count):
            isConnected = true
            AppLog.streamMouse.info("Mouse connected (\(count, privacy: .public) total)")
        case .disconnected(_, let count):
            isConnected = count > 0
            if count == 0 { releaseHeldButtons() }
            AppLog.streamMouse.info("Mouse disconnected (\(count, privacy: .public) left)")
        case .moved(let dx, let dy):
            moved(dx: dx, dy: dy)
        case .button(let button, let pressed):
            buttonChanged(button, pressed: pressed)
        case .scroll(let x, let y):
            scrolled(x: x, y: y)
        }
    }

    private func moved(dx: Float, dy: Float) {
        motionEvents += 1
        guard forwarding, !menuOpen, let target else { return }
        let scaled: (x: Float, y: Float)
        switch motion {
        case .accelerated:
            let speed = (dx * dx + dy * dy).squareRoot()
            let gain = Self.baseSpeed * min(1 + Self.acceleration * speed, Self.maxGain)
            scaled = (dx * gain, dy * gain)
        case .raw(let divisor):
            scaled = (dx / divisor, dy / divisor)
        }
        // GCMouse is +Y up; the desktop is +Y down.
        target.pointerMove(dx: CGFloat(scaled.x), dy: CGFloat(-scaled.y))
    }

    private func buttonChanged(_ button: RAVEMouseButton, pressed: Bool) {
        if case .auxiliary(let index) = button, index > 1 { return }
        if pressed {
            let onControls = pointerOverControls || menuOpen
            let sent = forwarding && !onControls
            AppLog.streamMouse.debug("Button \(String(describing: button), privacy: .public) down — \(sent ? "sent" : (onControls ? "held back: on the controls" : "held back: not streaming or not focused"), privacy: .public)")
            guard heldButtons.press(button, allowed: sent) else { return }
            target?.pointerButton(Self.button(button), pressed: true)
        } else {
            // Release only what was pressed here, so nothing sticks.
            guard heldButtons.release(button) else { return }
            target?.pointerButton(Self.button(button), pressed: false)
        }
    }

    /// Wheel detents arrive as whole units (a trackpad's as fractions), +Y
    /// away from the user — `RemotePointerTarget.pointerScroll`'s sign.
    private func scrolled(x: Float, y: Float) {
        guard forwarding, !menuOpen, let target else { resetScroll(); return }
        let stepsX = scrollRemainder.x.add(x)
        let stepsY = scrollRemainder.y.add(y)
        guard stepsX != 0 || stepsY != 0 else { return }
        target.pointerScroll(dx: max(-10, min(10, stepsX)), dy: max(-10, min(10, stepsY)))
    }

    private func resetScroll() {
        scrollRemainder.x.reset()
        scrollRemainder.y.reset()
    }

    private static func button(_ button: RAVEMouseButton) -> RemotePointerButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .middle
        case .auxiliary(0): .back
        case .auxiliary: .forward
        }
    }
}

extension StreamMouseBridge {
    private static var bridges: [ObjectIdentifier: StreamMouseBridge] = [:]

    /// The session's bridge — one per target, shared by the stream window and
    /// its controls ornament.
    static func shared(
        for target: any RemotePointerTarget,
        motion: Motion = .accelerated,
        captureKey: String
    ) -> StreamMouseBridge {
        let key = ObjectIdentifier(target)
        if let bridge = bridges[key] { return bridge }
        let bridge = StreamMouseBridge(target: target, motion: motion, captureKey: captureKey)
        bridges[key] = bridge
        return bridge
    }
}
#endif

#if os(visionOS)
extension StreamMouseBridge {
    static func shared(for manager: MacNativeStreamManager) -> StreamMouseBridge {
        shared(for: manager, captureKey: "macNativeMouseCapture")
    }

    static func shared(for manager: VNCConnectionManager) -> StreamMouseBridge {
        shared(for: manager, captureKey: "vncMouseCapture")
    }

    #if MOONLIGHT_ENABLED
    /// Raw motion, and only from the session holding input focus: several
    /// Moonlight streams can run at once and `GCMouse` is app-wide.
    static func shared(for manager: MoonlightConnectionManager) -> StreamMouseBridge {
        let bridge = shared(for: manager, motion: .raw(divisor: 1.25), captureKey: "moonlightMouseCapture")
        let slot = manager.slot
        bridge.inputAllowed = { MoonlightInputFocus.owns(slot) }
        return bridge
    }
    #endif
}
#endif
