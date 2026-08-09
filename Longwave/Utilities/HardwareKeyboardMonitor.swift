import Foundation
import GameController

/// Tracks whether a physical (Bluetooth/USB) keyboard is currently attached, via
/// GameController's `GCKeyboard` notifications. Lets a view that normally gates
/// keyboard focus behind a manual toggle (the SSH terminal) hand focus over
/// automatically when a hardware keyboard appears — so a Bluetooth keyboard
/// "just works" without a tap, the same reflex Moonlight/VNC already have.
///
/// Presence only: this observes connect/disconnect and never intercepts key
/// events itself (SwiftTerm's own first responder does that once focused). With
/// a hardware keyboard attached, becoming first responder does not raise the
/// software keyboard, so auto-focus stays dictation-safe.
@Observable
@MainActor
final class HardwareKeyboardMonitor {
    private(set) var isConnected = false
    private var observers: [NSObjectProtocol] = []

    /// Begin observing. Idempotent; seeds `isConnected` from the current state.
    func start() {
        guard observers.isEmpty else { return }
        isConnected = GCKeyboard.coalesced != nil
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isConnected = true }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            // Re-check `coalesced` rather than assuming zero — a second keyboard
            // may still be attached after one disconnects.
            MainActor.assumeIsolated { self?.isConnected = GCKeyboard.coalesced != nil }
        })
    }

    /// Callers must invoke this (the SSH terminal does, from `onDisappear`); the
    /// observers are `[weak self]` so a missed `stop()` leaks only inert tokens,
    /// never the monitor itself.
    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
