#if os(visionOS)
import DebugTrace
import GameController
import ObjectiveC
import UIKit

/// Drives the Mac's cursor from a Bluetooth/USB mouse through GameController's
/// `GCMouse`, so the mouse never goes through the desktop's touch paths.
///
/// Through SwiftUI, a mouse on the curved desktop was a gaze pointer in all but
/// name. Hover doesn't reach the RealityKit mesh, so Direct mode clicked
/// wherever the gaze ray hit it, and Touchpad mode had no drag to read. `GCMouse`
/// gives raw motion deltas and physical button and wheel events whatever is
/// under the system pointer. Those move the Mac's cursor relative to where it
/// is, the way the mouse would on the Mac itself, flat or curved and in either
/// touch mode.
///
/// The system pointer is still there, and visionOS also delivers a physical
/// click to SwiftUI as a tap. So while a mouse is connected:
/// - the view drops its own taps and drags (`isActive`), as Moonlight does;
/// - the bridge asks for pointer lock (`MacNativePointerLock`). That hides the
///   system pointer and keeps it from wandering onto the ornament, where its
///   clicks would also reach the Mac;
/// - clicks are held back while the pointer is over the controls ornament
///   (`pointerOverControls`) or another window has focus.
@MainActor
@Observable
final class MacNativeMouseBridge {
    /// Whether a mouse is connected and the bridge is listening — the view's
    /// cue to stand its own pointer paths aside.
    private(set) var isActive = false
    /// Whether the system has actually locked the pointer to this window.
    private(set) var isPointerLocked = false

    /// The user's choice: capture the mouse for the Mac, or leave it to
    /// visionOS (the ornament's Mouse toggle). Persisted.
    var captureEnabled: Bool = UserDefaults.standard.object(forKey: MacNativeMouseBridge.captureKey) as? Bool ?? true {
        didSet {
            guard captureEnabled != oldValue else { return }
            UserDefaults.standard.set(captureEnabled, forKey: Self.captureKey)
            releaseHeldButtons()
            refresh()
        }
    }

    /// Set from the ornament's hover, so clicking the window's own buttons
    /// with the mouse doesn't click the Mac too. Only matters unlocked.
    @ObservationIgnored var pointerOverControls = false {
        didSet { if pointerOverControls { releaseHeldButtons() } }
    }

    @ObservationIgnored private let manager: MacNativeStreamManager
    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private var mice: [GCMouse] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var windowIsKey = true
    @ObservationIgnored private var heldButtons: Set<UInt8> = []
    @ObservationIgnored private var scrollRemainder: (x: Float, y: Float) = (0, 0)

    private static let captureKey = "macNativeMouseCapture"

    /// Desktop points per raw count at slow speeds, and how much faster
    /// quick flicks travel. A raw count is about a point on most mice;
    /// straight 1:1 on a 2560-wide virtual display took several swipes to
    /// cross it, and the Mac's own acceleration never sees these deltas.
    private static let baseSpeed: Float = 1.2
    private static let acceleration: Float = 0.06
    private static let maxGain: Float = 4

    init(manager: MacNativeStreamManager) {
        self.manager = manager
    }

    /// Mouse input counts only while this is true: the window is streaming.
    var streaming = false {
        didSet {
            guard streaming != oldValue else { return }
            if !streaming { releaseHeldButtons() }
            refresh()
        }
    }

    /// Whether physical clicks and motion go to the Mac right now.
    private var forwarding: Bool {
        guard isActive, captureEnabled, streaming else { return false }
        if isPointerLocked { return true }
        return windowIsKey && !pointerOverControls
    }

    // MARK: Lifecycle

    func start(scene: UIWindowScene?) {
        if let scene, scene !== self.scene {
            self.scene = scene
            observeScene(scene)
        }
        guard !listening else { refresh(); return }
        listening = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let mouse = note.object as? GCMouse else { return }
            MainActor.assumeIsolated { self?.connected(mouse) }
        })
        observers.append(center.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let mouse = note.object as? GCMouse else { return }
            MainActor.assumeIsolated { self?.disconnected(mouse) }
        })
        observers.append(center.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLockState() }
        })
        for mouse in GCMouse.mice() { connected(mouse) }
        refresh()
    }

    func stop() {
        releaseHeldButtons()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        sceneObservers.removeAll()
        for mouse in mice { clearHandlers(mouse) }
        mice.removeAll()
        listening = false
        isActive = false
        if let scene { MacNativePointerLock.set(false, for: scene) }
        isPointerLocked = false
    }

    @ObservationIgnored private var sceneObservers: [NSObjectProtocol] = []

    /// Key-window changes tell this window apart from the app's others:
    /// `GCMouse` events are app-wide, so a click on the connection list would
    /// otherwise click the Mac as well.
    private func observeScene(_ scene: UIWindowScene) {
        for observer in sceneObservers { NotificationCenter.default.removeObserver(observer) }
        sceneObservers.removeAll()
        // The window was just put up or interacted with; key notifications
        // take it from here.
        windowIsKey = true
        let center = NotificationCenter.default
        sceneObservers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? UIWindow
            MainActor.assumeIsolated { self?.keyChanged(window, becameKey: true) }
        })
        sceneObservers.append(center.addObserver(forName: UIWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? UIWindow
            MainActor.assumeIsolated { self?.keyChanged(window, becameKey: false) }
        })
    }

    private func keyChanged(_ window: UIWindow?, becameKey: Bool) {
        guard let window, window.windowScene === scene else { return }
        windowIsKey = becameKey
        AppLog.macNativeMouse.debug("Desktop window \(becameKey ? "became" : "resigned", privacy: .public) key")
        if !becameKey { releaseHeldButtons() }
        refresh()
    }

    // MARK: Devices

    private func connected(_ mouse: GCMouse) {
        guard !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        mouse.handlerQueue = .main
        setHandlers(mouse)
        AppLog.macNativeMouse.info("Mouse connected (\(self.mice.count, privacy: .public) total)")
        refresh()
    }

    private func disconnected(_ mouse: GCMouse) {
        clearHandlers(mouse)
        mice.removeAll { $0 === mouse }
        AppLog.macNativeMouse.info("Mouse disconnected (\(self.mice.count, privacy: .public) left)")
        if mice.isEmpty { releaseHeldButtons() }
        refresh()
    }

    /// Recomputes `isActive` and the pointer-lock request from the current
    /// devices, choice and stream state.
    private func refresh() {
        isActive = listening && !mice.isEmpty
        guard let scene else { return }
        MacNativePointerLock.set(isActive && captureEnabled && streaming, for: scene)
        readLockState()
    }

    private func readLockState() {
        let locked = scene?.pointerLockState?.isLocked ?? false
        guard locked != isPointerLocked else { return }
        isPointerLocked = locked
        AppLog.macNativeMouse.info("Pointer lock \(locked ? "granted" : "released", privacy: .public)")
        if !locked { releaseHeldButtons() }
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
        // A held button keeps the drag going even if focus moved mid-drag;
        // the release still has to land where the drag ended.
        guard forwarding || !heldButtons.isEmpty else { return }
        let speed = (dx * dx + dy * dy).squareRoot()
        let gain = Self.baseSpeed * min(1 + Self.acceleration * speed, Self.maxGain)
        // GCMouse is +Y up; the desktop is +Y down.
        manager.moveVirtualCursor(dx: CGFloat(dx * gain), dy: CGFloat(-dy * gain))
    }

    private func buttonChanged(_ button: MacNativeStreamProtocol.MouseButton, pressed: Bool) {
        if pressed {
            guard forwarding, heldButtons.insert(button.rawValue).inserted else { return }
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

/// Pointer lock for a SwiftUI window. UIKit asks the scene's root view
/// controller (`prefersPointerLocked`), which here is SwiftUI's hosting
/// controller; there is no SwiftUI modifier for it. So the getter on
/// `UIViewController` is swapped once for one that answers true for the root
/// controller of a scene that asked, and defers to the original otherwise.
///
/// The system may still decline: `UIPointerLockState.isLocked` says what it
/// did, and the bridge works unlocked too.
@MainActor
enum MacNativePointerLock {
    private static var lockedScenes: [ObjectIdentifier: Bool] = [:]
    private static var installed = false

    static func set(_ wanted: Bool, for scene: UIWindowScene) {
        install()
        let key = ObjectIdentifier(scene)
        guard (lockedScenes[key] ?? false) != wanted else { return }
        lockedScenes[key] = wanted ? true : nil
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    fileprivate static func wantsLock(_ controller: UIViewController) -> Bool {
        guard let window = controller.viewIfLoaded?.window,
              window.rootViewController === controller,
              let scene = window.windowScene else { return false }
        return lockedScenes[ObjectIdentifier(scene)] ?? false
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        let selector = #selector(getter: UIViewController.prefersPointerLocked)
        guard let method = class_getInstanceMethod(UIViewController.self, selector) else { return }
        typealias Getter = @convention(c) (UIViewController, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (UIViewController) -> Bool = { controller in
            MainActor.assumeIsolated { wantsLock(controller) } || original(controller, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
#endif
