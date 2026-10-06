#if MOONLIGHT_ENABLED
import DebugTrace
import Foundation
import Observation
import RAVEInput
@preconcurrency import MoonlightCommonC

/// Bridges Apple's GameController `GCMouse` to Moonlight's mouse input APIs.
/// The mice themselves are read by RAVEInput's `RAVEMouseSource`, which owns
/// the per-device handler slots for the whole app; this is the Moonlight
/// policy on top (focus, speed, button codes, high-res scroll).
///
/// `GCMouse` is the only supported way to read a Bluetooth/USB mouse on
/// visionOS — there is no `CGAssociateMouseAndMouseCursorPosition`-style
/// pointer capture. It delivers *raw* motion deltas (bypassing the system
/// mouse-sensitivity curve) plus physical button and scroll-wheel events,
/// fired on every motion regardless of whether a button is held — which is
/// exactly what relative/trackpad camera control needs.
///
/// Movement deltas are only forwarded in **relative** touch mode; in
/// **absolute** mode the view's `onContinuousHover` sends position events
/// instead (`LiSendMousePositionEvent`). Button and scroll events are
/// forwarded in both modes.
///
/// visionOS gotcha: controller (and mouse) events only flow while the user is
/// gazing at the app's window. That's fine for an active stream window.
@Observable
final class MoonlightMouseManager: @unchecked Sendable {

    /// The session's copy of moonlight-common-c. `GCMouse` events are app-wide,
    /// so they are only forwarded while this session holds input focus.
    private let library: MoonlightLibrary

    /// When true, raw motion deltas are forwarded as relative mouse moves.
    /// Set false in absolute mode where the view sends position events instead.
    @ObservationIgnored
    nonisolated(unsafe) var relativeMotionEnabled: Bool

    /// Fired (on the main queue) when a physical mouse connects/disconnects, so
    /// the view can suppress its touch-gesture click paths — visionOS otherwise
    /// double-delivers a physical click as both a `GCMouse` button event *and* a
    /// SwiftUI tap, causing double clicks and dismissed context menus.
    @ObservationIgnored var onConnectedChange: ((Bool) -> Void)?

    /// The shared GCMouse source's delivery to this session (main queue).
    @ObservationIgnored private var subscription: RAVEMouseSubscription?

    /// Divides raw motion deltas for a comfortable pointer speed (matches the
    /// reference moonlight-ios client).
    private static let speedDivisor: Float = 1.25

    /// Sub-integer remainders, carried between events so slow movement/scroll
    /// isn't truncated to zero. Touched only from the (serial) mouse handlers.
    @ObservationIgnored private nonisolated(unsafe) var accumX = RAVEMouseStepAccumulator()
    @ObservationIgnored private nonisolated(unsafe) var accumY = RAVEMouseStepAccumulator()
    @ObservationIgnored private nonisolated(unsafe) var accumScrollX = RAVEMouseStepAccumulator()
    @ObservationIgnored private nonisolated(unsafe) var accumScrollY = RAVEMouseStepAccumulator()

    /// Whether the pointer is currently over the stream content (vs the app's own
    /// toolbar/ornament controls). Driven by the view's `onContinuousHover`. We
    /// only forward physical clicks when this is true, so clicking the app's
    /// buttons (mode toggle, keyboard, …) with the mouse doesn't also click the
    /// remote — `GCMouse` events are global and otherwise UI-agnostic.
    @ObservationIgnored nonisolated(unsafe) var pointerOverContent: Bool = false

    /// Buttons whose press we actually forwarded, so the matching release is sent
    /// even if the pointer left the content mid-click (no stuck buttons). While
    /// any is held we always forward raw motion deltas — even in absolute mode —
    /// because visionOS stops delivering `onContinuousHover` updates during a
    /// button-held drag, which would otherwise freeze the cursor mid-drag in
    /// direct mode.
    @ObservationIgnored private nonisolated(unsafe) var buttons = RAVEMouseButtonGate()

    init(library: MoonlightLibrary, relativeMotionEnabled: Bool) {
        self.library = library
        self.relativeMotionEnabled = relativeMotionEnabled
    }

    private nonisolated var hasFocus: Bool { MoonlightInputFocus.owns(library.slot) }

    // MARK: - Lifecycle

    func startListening() {
        AppLog.gamepadManager.log("Starting mouse listening")
        // Picks up any mice already connected (a `.connected` for each).
        subscription = RAVEMouseSource.shared.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    func stopListening() {
        AppLog.gamepadManager.log("Stopping mouse listening")
        subscription?.cancel()
        subscription = nil
        buttons.clear()
    }

    // MARK: - Input

    private func handle(_ event: RAVEMouseEvent) {
        switch event {
        case .connected(let name, let count):
            AppLog.gamepadManager.log("Mouse connected: \(name ?? "unknown")")
            onConnectedChange?(count > 0)
        case .disconnected(let name, let count):
            buttons.clear()
            AppLog.gamepadManager.log("Mouse disconnected: \(name ?? "unknown")")
            onConnectedChange?(count > 0)
        case .moved(let deltaX, let deltaY):
            moved(deltaX: deltaX, deltaY: deltaY)
        case .button(let button, let pressed):
            let code: Int32
            switch button {
            case .left: code = BUTTON_LEFT
            case .right: code = BUTTON_RIGHT
            case .middle: code = BUTTON_MIDDLE
            // Side (back/forward) buttons, where present.
            case .auxiliary(0): code = BUTTON_X1
            case .auxiliary(1): code = BUTTON_X2
            case .auxiliary: return
            }
            buttonChanged(button, code: code, pressed: pressed)
        case .scroll(let x, let y):
            // Accumulate the raw axis value, then emit high-res ticks scaled by
            // 20 (matches moonlight-ios). +Y = up; horizontal is reversed.
            guard hasFocus else { return }
            if y != 0 {
                let ticks = accumScrollY.add(y)
                if ticks != 0 { library.sendHighResScroll(Int16(clamping: ticks * 20)) }
            }
            if x != 0 {
                let ticks = accumScrollX.add(x)
                if ticks != 0 { library.sendHighResHScroll(Int16(clamping: -ticks * 20)) }
            }
        }
    }

    private func moved(deltaX: Float, deltaY: Float) {
        // Forward deltas in relative (touchpad) mode, OR whenever a button is
        // held — even in absolute mode — so a click+drag keeps moving after
        // visionOS stops delivering hover updates mid-drag.
        guard hasFocus, relativeMotionEnabled || !buttons.held.isEmpty else { return }
        // GCMouse reports +Y as up (controller convention); Moonlight/screen
        // space is +Y down, so invert. The accumulators carry the fractional
        // remainder so a slow drag isn't repeatedly truncated to zero.
        let dx = accumX.add(deltaX / Self.speedDivisor)
        let dy = accumY.add(-deltaY / Self.speedDivisor)
        if dx != 0 || dy != 0 {
            library.sendMouseMove(dx: Int16(clamping: dx), dy: Int16(clamping: dy))
        }
    }

    /// Forwards a click *and* maintains the held set (so motion deltas flow
    /// during a button-held drag).
    private func buttonChanged(_ button: RAVEMouseButton, code: Int32, pressed: Bool) {
        if pressed {
            // Suppress clicks aimed at the app's own controls — forward only
            // when the pointer is over the stream content, and only from the
            // session that owns the physical inputs.
            guard buttons.press(button, allowed: pointerOverContent && hasFocus) else { return }
            library.sendMouseButton(BUTTON_ACTION_PRESS, code)
        } else {
            // Release only what we actually pressed (no stuck buttons if the
            // pointer left the content between press and release).
            guard buttons.release(button) else { return }
            library.sendMouseButton(BUTTON_ACTION_RELEASE, code)
            // Drop any residual delta so the next hover-driven move starts clean.
            accumX.reset()
            accumY.reset()
        }
    }
}
#endif
