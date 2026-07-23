import SwiftUI
import SwiftTerm
import UIKit

/// SwiftTerm's `TerminalView` makes itself the first responder on tap to capture
/// hardware-keyboard input and start text selection. That's wanted for a
/// Bluetooth keyboard / shortcuts — but on visionOS an *accidental* gaze-pinch on
/// the output while dictating into the composer would resign the composer and
/// abort dictation mid-sentence. So first-responder is gated behind an explicit
/// toggle (`keyboardFocusEnabled`): off by default (display-only, dictation-safe),
/// flipped on deliberately when the user wants to drive the terminal directly.
final class VisionTerminalView: TerminalView {
    var keyboardFocusEnabled = false

    /// Fired when the view loses first responder for a reason *other* than an
    /// app-initiated toggle — i.e. the user dismissed the software keyboard. Lets
    /// the owning view reset its `keyboardFocused` state so the toggle button
    /// reflects reality; without it the button's first tap is wasted "turning off"
    /// an already-dismissed keyboard, forcing a double-tap to re-summon.
    var onExternalFocusRelease: (() -> Void)?

    /// Set while we resign first responder ourselves (`setKeyboardFocus(false)`)
    /// so the resign override can tell an app-initiated release from a user one.
    private var suppressReleaseCallback = false

    override var canBecomeFirstResponder: Bool { keyboardFocusEnabled }

    /// Apply the desired keyboard-focus state, grabbing or releasing first
    /// responder to match. Idempotent.
    func setKeyboardFocus(_ on: Bool) {
        guard on != keyboardFocusEnabled else { return }
        keyboardFocusEnabled = on
        if on {
            _ = becomeFirstResponder()
        } else if isFirstResponder {
            suppressReleaseCallback = true
            _ = resignFirstResponder()
            suppressReleaseCallback = false
        }
    }

    /// The OS resigns us when the user dismisses the keyboard. Mirror that into
    /// `keyboardFocusEnabled` (so `canBecomeFirstResponder` stays truthful) and,
    /// unless we triggered the resign ourselves, notify the owner to reconcile.
    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            keyboardFocusEnabled = false
            if !suppressReleaseCallback { onExternalFocusRelease?() }
        }
        return didResign
    }
}

/// Hosts a SwiftTerm `TerminalView` for an `SSHSession`. The view renders the
/// PTY stream and reports size changes (→ SIGWINCH) and any first-responder
/// keystrokes back to the session. Input primarily comes from the composer +
/// quick-key row in `SSHTerminalView`; this view is the display surface.
struct TerminalEmulatorView: UIViewRepresentable {
    let session: SSHSession
    var fontSize: Double = ConnectionDefaults.terminalFontSizeDefault
    /// When true, the terminal grabs first responder for direct hardware-keyboard
    /// input and text selection; when false it's display-only (dictation-safe).
    /// Two-way so a user-driven keyboard dismissal flows back and resets it.
    @Binding var keyboardFocused: Bool

    func makeUIView(context: Context) -> TerminalView {
        let terminal = VisionTerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        context.coordinator.focusBinding = $keyboardFocused
        terminal.onExternalFocusRelease = { [weak coordinator = context.coordinator] in
            coordinator?.focusReleasedExternally()
        }
        // Opaque dark backdrop — visionOS glass washes out ANSI colors.
        let dark = UIColor(white: 0.07, alpha: 1.0)
        terminal.nativeBackgroundColor = dark
        terminal.backgroundColor = dark
        terminal.isOpaque = true
        terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Ignore the agent's mouse-mode requests: VisionVNC sends no mouse input
        // to the agent (input is the composer + quick-key row), and this keeps
        // taps as local selection rather than forwarded mouse clicks. Scrollback
        // is driven by the Scroll ▲▼ controls (SwiftTerm's public pageUp/Down),
        // not the UIScrollView drag, which doesn't move the yDisp-based view.
        terminal.allowMouseReporting = false
        terminal.setKeyboardFocus(keyboardFocused)
        session.attach(terminal)
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // SwiftTerm's font setter recomputes cell metrics, resizes the grid,
        // and re-fires sizeChanged → PTY resize — live font changes propagate
        // end-to-end with no extra plumbing.
        if uiView.font.pointSize != fontSize {
            uiView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        context.coordinator.focusBinding = $keyboardFocused
        (uiView as? VisionTerminalView)?.setKeyboardFocus(keyboardFocused)
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    /// SwiftTerm delegate. `TerminalViewDelegate` is not `@MainActor`, but
    /// SwiftTerm always invokes it on the main thread, so we assume isolation
    /// to reach the MainActor `SSHSession` without an async hop (preserving
    /// keystroke ordering).
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: SSHSession
        /// Source of truth for the keyboard toggle, refreshed each update so a
        /// user-driven dismissal can reset it. Held here (not on the struct,
        /// which is recreated per update) so the UIView callback stays valid.
        var focusBinding: Binding<Bool>?
        init(session: SSHSession) { self.session = session }

        func detach() { MainActor.assumeIsolated { session.detach() } }

        /// User dismissed the software keyboard — clear the toggle so the next
        /// button tap re-summons it (rather than being spent re-syncing state).
        func focusReleasedExternally() {
            guard focusBinding?.wrappedValue == true else { return }
            focusBinding?.wrappedValue = false
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(cols: newCols, rows: newRows) }
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { session.sendBytes(Array(data)) }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        nonisolated func bell(source: TerminalView) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
