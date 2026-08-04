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
final class VisionTerminalView: TerminalView, PassiveTextInputSurface {
    private var keyboardFocusEnabled = false
    private var appliedFocusRequest = -1
    /// Set when a grab was declined because text entry was live, so it can be
    /// completed once that session ends instead of being lost.
    private var focusGrabDeferred = false
    private var textEntryObserver: NSObjectProtocol?
    var onFirstResponderChange: ((Bool) -> Void)?

    override var canBecomeFirstResponder: Bool { keyboardFocusEnabled }

    /// Mirror it into the focus system too: a display-only terminal shouldn't be
    /// a keyboard-navigation destination in a window that also hosts a composer.
    override var canBecomeFocused: Bool { keyboardFocusEnabled }

    /// Focus requests are edge-triggered so a single tap can re-open the
    /// keyboard after a system-driven resignation. Losing first responder does
    /// not disable future focus: dictation itself may resign transiently.
    ///
    /// An *automatic* request (window appeared, keyboard paired) yields to any
    /// live text entry — this view lives in a sibling window of whatever composer
    /// is being dictated into, and taking the responder ends that dictation. The
    /// grab is retried when text entry ends. A *deliberate* request (the user
    /// tapped the keyboard toggle) is honoured immediately: cutting the composer
    /// off is exactly what the tap asked for.
    func updateKeyboardFocus(enabled: Bool, request: Int, deliberate: Bool) {
        keyboardFocusEnabled = enabled
        if !enabled {
            focusGrabDeferred = false
            if isFirstResponder {
                _ = resignFirstResponder()
            }
        } else if request != appliedFocusRequest {
            appliedFocusRequest = request
            grabFirstResponder(deliberate: deliberate)
        }
    }

    private func grabFirstResponder(deliberate: Bool) {
        guard !isFirstResponder else { return }
        if !deliberate, !TextInputActivity.shared.mayTakeFirstResponder() {
            focusGrabDeferred = true
            return
        }
        focusGrabDeferred = false
        _ = becomeFirstResponder()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if textEntryObserver == nil {
                textEntryObserver = NotificationCenter.default.addObserver(
                    forName: .textEntryDidEnd, object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self, self.focusGrabDeferred, self.keyboardFocusEnabled else { return }
                    self.grabFirstResponder(deliberate: false)
                }
            }
        } else if let observer = textEntryObserver {
            NotificationCenter.default.removeObserver(observer)
            textEntryObserver = nil
        }
    }

    deinit {
        if let textEntryObserver {
            NotificationCenter.default.removeObserver(textEntryObserver)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            onFirstResponderChange?(true)
        }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            onFirstResponderChange?(false)
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
    let keyboardFocusEnabled: Bool
    let keyboardFocusRequest: Int
    /// See `TerminalKeyboardFocusState.requestIsDeliberate`.
    let keyboardFocusIsDeliberate: Bool
    let onKeyboardFocusChanged: (Bool) -> Void

    func makeUIView(context: Context) -> TerminalView {
        let terminal = VisionTerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        context.coordinator.onKeyboardFocusChanged = onKeyboardFocusChanged
        terminal.onFirstResponderChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.keyboardFocusChanged(focused)
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
        terminal.updateKeyboardFocus(enabled: keyboardFocusEnabled,
                                     request: keyboardFocusRequest,
                                     deliberate: keyboardFocusIsDeliberate)
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
        context.coordinator.onKeyboardFocusChanged = onKeyboardFocusChanged
        (uiView as? VisionTerminalView)?.updateKeyboardFocus(
            enabled: keyboardFocusEnabled,
            request: keyboardFocusRequest,
            deliberate: keyboardFocusIsDeliberate
        )
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
        var onKeyboardFocusChanged: ((Bool) -> Void)?
        private var reportedKeyboardFocus: Bool?
        init(session: SSHSession) { self.session = session }

        func detach() { MainActor.assumeIsolated { session.detach() } }

        func keyboardFocusChanged(_ focused: Bool) {
            guard reportedKeyboardFocus != focused else { return }
            reportedKeyboardFocus = focused
            DispatchQueue.main.async { [weak self] in
                self?.onKeyboardFocusChanged?(focused)
            }
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
