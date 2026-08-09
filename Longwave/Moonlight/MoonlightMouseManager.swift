#if MOONLIGHT_ENABLED
import Foundation
import os
import GameController
@preconcurrency import MoonlightCommonC

/// Bridges Apple's GameController `GCMouse` to Moonlight's mouse input APIs.
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

    /// When true, raw motion deltas are forwarded as relative mouse moves.
    /// Set false in absolute mode where the view sends position events instead.
    @ObservationIgnored
    nonisolated(unsafe) var relativeMotionEnabled: Bool

    /// Fired (on the main queue) when a physical mouse connects/disconnects, so
    /// the view can suppress its touch-gesture click paths — visionOS otherwise
    /// double-delivers a physical click as both a `GCMouse` button event *and* a
    /// SwiftUI tap, causing double clicks and dismissed context menus.
    @ObservationIgnored var onConnectedChange: ((Bool) -> Void)?

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private var mice: [GCMouse] = []

    /// Divides raw motion deltas for a comfortable pointer speed (matches the
    /// reference moonlight-ios client).
    private static let speedDivisor: Float = 1.25

    /// Sub-integer remainders, carried between events so slow movement/scroll
    /// isn't truncated to zero. Touched only from the (serial) mouse handlers.
    @ObservationIgnored private nonisolated(unsafe) var accumX: Float = 0
    @ObservationIgnored private nonisolated(unsafe) var accumY: Float = 0
    @ObservationIgnored private nonisolated(unsafe) var accumScrollX: Float = 0
    @ObservationIgnored private nonisolated(unsafe) var accumScrollY: Float = 0

    /// Count of currently-held mouse buttons. While any button is held we always
    /// forward raw motion deltas — even in absolute mode — because visionOS stops
    /// delivering `onContinuousHover` updates during a button-held drag, which
    /// would otherwise freeze the cursor mid-drag in direct mode.
    @ObservationIgnored private nonisolated(unsafe) var heldButtons: Int = 0

    /// Whether the pointer is currently over the stream content (vs the app's own
    /// toolbar/ornament controls). Driven by the view's `onContinuousHover`. We
    /// only forward physical clicks when this is true, so clicking the app's
    /// buttons (mode toggle, keyboard, …) with the mouse doesn't also click the
    /// remote — `GCMouse` events are global and otherwise UI-agnostic.
    @ObservationIgnored nonisolated(unsafe) var pointerOverContent: Bool = false

    /// Buttons whose press we actually forwarded, so the matching release is sent
    /// even if the pointer left the content mid-click (no stuck buttons).
    @ObservationIgnored private nonisolated(unsafe) var forwardedButtons: Set<Int32> = []

    init(relativeMotionEnabled: Bool) {
        self.relativeMotionEnabled = relativeMotionEnabled
    }

    // MARK: - Lifecycle

    func startListening() {
        AppLog.gamepadManager.line("Starting mouse listening")

        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mouse = notification.object as? GCMouse else { return }
            self?.mouseConnected(mouse)
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mouse = notification.object as? GCMouse else { return }
            self?.mouseDisconnected(mouse)
        }

        // Pick up any mice already connected.
        for mouse in GCMouse.mice() {
            mouseConnected(mouse)
        }
    }

    func stopListening() {
        AppLog.gamepadManager.line("Stopping mouse listening")

        if let obs = connectObserver {
            NotificationCenter.default.removeObserver(obs)
            connectObserver = nil
        }
        if let obs = disconnectObserver {
            NotificationCenter.default.removeObserver(obs)
            disconnectObserver = nil
        }

        for mouse in mice { clearHandlers(mouse) }
        mice.removeAll()
    }

    // MARK: - Connect/Disconnect

    private func mouseConnected(_ mouse: GCMouse) {
        guard !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        AppLog.gamepadManager.line("Mouse connected: \(mouse.vendorName ?? "unknown")")
        setupHandlers(mouse)
        onConnectedChange?(!mice.isEmpty)
    }

    private func mouseDisconnected(_ mouse: GCMouse) {
        clearHandlers(mouse)
        mice.removeAll { $0 === mouse }
        AppLog.gamepadManager.line("Mouse disconnected: \(mouse.vendorName ?? "unknown")")
        onConnectedChange?(!mice.isEmpty)
    }

    // MARK: - Input Handlers

    private func setupHandlers(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }

        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            guard let self else { return }
            // Forward deltas in relative (touchpad) mode, OR whenever a button is
            // held — even in absolute mode — so a click+drag keeps moving after
            // visionOS stops delivering hover updates mid-drag.
            guard self.relativeMotionEnabled || self.heldButtons > 0 else { return }
            // GCMouse reports +Y as up (controller convention); Moonlight/screen
            // space is +Y down, so invert. Carry the fractional remainder so a
            // slow drag isn't repeatedly truncated to zero.
            self.accumX += deltaX / Self.speedDivisor
            self.accumY += -deltaY / Self.speedDivisor
            let dx = Int(self.accumX)
            let dy = Int(self.accumY)
            if dx != 0 || dy != 0 {
                LiSendMouseMoveEvent(Int16(clamping: dx), Int16(clamping: dy))
                self.accumX -= Float(dx)
                self.accumY -= Float(dy)
            }
        }

        input.leftButton.pressedChangedHandler = button(BUTTON_LEFT)
        input.rightButton?.pressedChangedHandler = button(BUTTON_RIGHT)
        input.middleButton?.pressedChangedHandler = button(BUTTON_MIDDLE)

        // Side (back/forward) buttons, where present.
        if let aux = input.auxiliaryButtons {
            if aux.count >= 1 { aux[0].pressedChangedHandler = button(BUTTON_X1) }
            if aux.count >= 2 { aux[1].pressedChangedHandler = button(BUTTON_X2) }
        }

        // Scroll wheel. Accumulate the raw axis value, then emit high-res ticks
        // scaled by 20 (matches moonlight-ios). +Y = up; horizontal is reversed.
        input.scroll.yAxis.valueChangedHandler = { [weak self] _, value in
            guard let self else { return }
            self.accumScrollY += value
            let ticks = Int(self.accumScrollY)
            if ticks != 0 {
                LiSendHighResScrollEvent(Int16(clamping: ticks * 20))
                self.accumScrollY -= Float(ticks)
            }
        }
        input.scroll.xAxis.valueChangedHandler = { [weak self] _, value in
            guard let self else { return }
            self.accumScrollX += value
            let ticks = Int(self.accumScrollX)
            if ticks != 0 {
                LiSendHighResHScrollEvent(Int16(clamping: -ticks * 20))
                self.accumScrollX -= Float(ticks)
            }
        }
    }

    /// Builds a pressed-changed handler that forwards the click *and* maintains
    /// the held-button count (so motion deltas flow during a button-held drag).
    private func button(_ button: Int32) -> (GCControllerButtonInput, Float, Bool) -> Void {
        { [weak self] _, _, pressed in
            guard let self else { return }
            if pressed {
                // Suppress clicks aimed at the app's own controls — forward only
                // when the pointer is over the stream content.
                guard self.pointerOverContent else { return }
                LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), button)
                self.forwardedButtons.insert(button)
                self.heldButtons += 1
            } else {
                // Release only what we actually pressed (no stuck buttons if the
                // pointer left the content between press and release).
                guard self.forwardedButtons.remove(button) != nil else { return }
                LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), button)
                self.heldButtons = max(0, self.heldButtons - 1)
                // Drop any residual delta so the next hover-driven move starts clean.
                self.accumX = 0
                self.accumY = 0
            }
        }
    }

    private func clearHandlers(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = nil
        input.leftButton.pressedChangedHandler = nil
        input.rightButton?.pressedChangedHandler = nil
        input.middleButton?.pressedChangedHandler = nil
        if let aux = input.auxiliaryButtons {
            for button in aux { button.pressedChangedHandler = nil }
        }
        input.scroll.xAxis.valueChangedHandler = nil
        input.scroll.yAxis.valueChangedHandler = nil
        heldButtons = 0
        forwardedButtons.removeAll()
    }
}
#endif
