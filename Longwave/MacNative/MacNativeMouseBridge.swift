#if os(visionOS)
import DebugTrace
import GameController

/// Drives the Mac's cursor from a Bluetooth/USB mouse read raw through
/// GameController's `GCMouse`, the way a game reads one: motion deltas move
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

    /// Set while one of the ornament's menus is open; its items sit outside
    /// the ornament, so its hover doesn't cover them. Holds back presses too.
    @ObservationIgnored var menuOpen = false

    /// Mouse input counts only while the window is streaming.
    @ObservationIgnored var streaming = false {
        didSet { if !streaming { releaseHeldButtons() } }
    }

    @ObservationIgnored private let manager: MacNativeStreamManager
    @ObservationIgnored private var mice: [GCMouse] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var heldButtons: Set<UInt8> = []
    @ObservationIgnored private var scrollRemainder: (x: Float, y: Float) = (0, 0)
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
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let mouse = note.object as? GCMouse else { return }
            MainActor.assumeIsolated { self?.connected(mouse) }
        })
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let mouse = note.object as? GCMouse else { return }
            MainActor.assumeIsolated { self?.disconnected(mouse) }
        })
        for mouse in GCMouse.mice() { connected(mouse) }
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
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for mouse in mice { clearHandlers(mouse) }
        mice.removeAll()
        isConnected = false
    }

    // MARK: Devices

    private func connected(_ mouse: GCMouse) {
        guard !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        mouse.handlerQueue = .main
        setHandlers(mouse)
        isConnected = true
        AppLog.macNativeMouse.info("Mouse connected (\(self.mice.count, privacy: .public) total)")
    }

    private func disconnected(_ mouse: GCMouse) {
        clearHandlers(mouse)
        mice.removeAll { $0 === mouse }
        isConnected = !mice.isEmpty
        if mice.isEmpty { releaseHeldButtons() }
        AppLog.macNativeMouse.info("Mouse disconnected (\(self.mice.count, privacy: .public) left)")
    }

    // MARK: Input

    private func setHandlers(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            MainActor.assumeIsolated { self?.moved(dx: dx, dy: dy) }
        }
        input.leftButton.pressedChangedHandler = buttonHandler(.left)
        input.rightButton?.pressedChangedHandler = buttonHandler(.right)
        input.middleButton?.pressedChangedHandler = buttonHandler(.other)
        input.scroll.yAxis.valueChangedHandler = { [weak self] _, value in
            MainActor.assumeIsolated { self?.scrolled(x: 0, y: value) }
        }
        input.scroll.xAxis.valueChangedHandler = { [weak self] _, value in
            MainActor.assumeIsolated { self?.scrolled(x: value, y: 0) }
        }
    }

    private func clearHandlers(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil
        input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil
        input.middleButton?.pressedChangedHandler = nil
        input.scroll.xAxis.valueChangedHandler = nil
        input.scroll.yAxis.valueChangedHandler = nil
    }

    private func buttonHandler(
        _ button: MacNativeStreamProtocol.MouseButton
    ) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.buttonChanged(button, pressed: pressed) }
        }
    }

    private func moved(dx: Float, dy: Float) {
        motionEvents += 1
        guard forwarding else { return }
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
            guard sent, heldButtons.insert(button.rawValue).inserted else { return }
            manager.pressMouseAtVirtualCursor(button: button)
        } else {
            // Release only what was pressed here, so nothing sticks.
            guard heldButtons.remove(button.rawValue) != nil else { return }
            manager.releaseMouseAtVirtualCursor(button: button)
        }
    }

    /// Wheel detents arrive as whole units (a trackpad's as fractions), +Y
    /// away from the user — the host's "content moves down" sign already.
    private func scrolled(x: Float, y: Float) {
        guard forwarding else { scrollRemainder = (0, 0); return }
        scrollRemainder.x += x
        scrollRemainder.y += y
        let stepsX = Int(scrollRemainder.x)
        let stepsY = Int(scrollRemainder.y)
        guard stepsX != 0 || stepsY != 0 else { return }
        scrollRemainder.x -= Float(stepsX)
        scrollRemainder.y -= Float(stepsY)
        manager.scrollAtVirtualCursor(
            deltaX: Int16(clamping: max(-10, min(10, stepsX))),
            deltaY: Int16(clamping: max(-10, min(10, stepsY)))
        )
    }

    private func releaseHeldButtons() {
        for raw in heldButtons {
            if let button = MacNativeStreamProtocol.MouseButton(rawValue: raw) {
                manager.releaseMouseAtVirtualCursor(button: button)
            }
        }
        heldButtons.removeAll()
        scrollRemainder = (0, 0)
    }
}
#endif
