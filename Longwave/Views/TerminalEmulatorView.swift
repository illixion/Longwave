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
    /// Set when a grab was declined — or given up — because text entry was live,
    /// so it can be completed once that session ends instead of being lost.
    private var focusGrabDeferred = false
    private var observers: [NSObjectProtocol] = []
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

    /// Text entry started somewhere in the app — most often a text field in
    /// another window, since a hardware keyboard hands this terminal the responder
    /// automatically. Yielding matters as much as not grabbing: holding on kept
    /// the keystrokes (and, via `becomeFirstResponder`, the key window) here, so
    /// typing into that field went into the session instead.
    private func yieldToTextEntry() {
        guard isFirstResponder, keyboardFocusEnabled else { return }
        focusGrabDeferred = true
        _ = resignFirstResponder()
    }

    /// Complete a deferred grab, but not at the cost of pulling the key window
    /// away from whatever window the user is actually working in. visionOS often
    /// reports no key window at all, so only another window's claim blocks this.
    private func completeDeferredGrab() {
        guard focusGrabDeferred, keyboardFocusEnabled, let window else { return }
        if !window.isKeyWindow {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                if windowScene.windows.contains(where: { $0.isKeyWindow && $0 !== window }) { return }
            }
        }
        grabFirstResponder(deliberate: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if observers.isEmpty {
                let center = NotificationCenter.default
                observers.append(center.addObserver(
                    forName: .textEntryDidBegin, object: nil, queue: .main
                ) { [weak self] _ in
                    self?.yieldToTextEntry()
                })
                observers.append(center.addObserver(
                    forName: .textEntryDidEnd, object: nil, queue: .main
                ) { [weak self] _ in
                    self?.completeDeferredGrab()
                })
                // A deferral the rule above declined is retried when this window
                // does become the one in front.
                observers.append(center.addObserver(
                    forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
                ) { [weak self] note in
                    guard let self, (note.object as? UIWindow) === self.window else { return }
                    self.completeDeferredGrab()
                })
            }
        } else {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Scrolling

    /// Accumulated drag that hasn't yet added up to a whole scroll step.
    private var scrollRemainder: CGFloat = 0

    /// Install drag-to-scroll over the output.
    ///
    /// One recognizer serves both input styles: on visionOS a gaze-pinch-drag
    /// arrives as an ordinary touch pan, and `allowedScrollTypesMask` folds in a
    /// trackpad's two-finger scroll and a mouse wheel. Where the scroll *goes* is
    /// `scrollBySteps`' decision — scrollback, or wheel events for a full-screen
    /// program tracking the mouse.
    ///
    /// Sessions here are tmux-backed, so it's always the second case: tmux owns
    /// the history and takes the wheel events (see `mouseOption`). Without that
    /// there is nothing for a drag to move and it silently does nothing.
    ///
    /// SwiftTerm's own scroll view is turned off to make room: panning it moves
    /// `contentOffset` without moving the yDisp-based rendering, and it rewrites
    /// that offset on every line of output anyway.
    func enableScrollGesture() {
        guard scrollRecognizer == nil else { return }
        isScrollEnabled = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan))
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        addGestureRecognizer(pan)
        scrollRecognizer = pan
    }

    private var scrollRecognizer: UIPanGestureRecognizer?

    @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            scrollRemainder = 0
        case .changed:
            break
        default:
            return
        }
        // Consume the translation each time so it reads as a delta.
        let delta = pan.translation(in: self).y
        pan.setTranslation(.zero, in: self)

        let terminal = getTerminal()
        let lineHeight = bounds.height / CGFloat(max(1, terminal.rows))
        guard lineHeight > 0 else { return }

        // Measure the drag in whatever a step is worth here, so the content
        // tracks the finger: a wheel notch moves ~3 lines, so it takes ~3 lines
        // of travel to earn one.
        let stepHeight = lineHeight * CGFloat(linesPerScrollStep)
        scrollRemainder += delta
        let steps = Int(scrollRemainder / stepHeight)
        guard steps != 0 else { return }
        scrollRemainder -= CGFloat(steps) * stepHeight

        // Dragging the content down reveals earlier output, which is the positive
        // direction — the same sense as a natural-scrolling wheel.
        scrollBySteps(steps, reportingAt: cell(at: pan.location(in: self)))
    }

    /// The terminal cell under a point, for reporting a wheel event where the
    /// gesture actually happened. `location(in:)` is in content coordinates and
    /// `bounds.origin` is the scroll offset, so the difference is on-screen.
    private func cell(at point: CGPoint) -> (col: Int, row: Int) {
        let terminal = getTerminal()
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        let col = Int((point.x - bounds.minX) / (bounds.width / CGFloat(cols)))
        let row = Int((point.y - bounds.minY) / (bounds.height / CGFloat(rows)))
        return (col: min(max(col, 0), cols - 1), row: min(max(row, 0), rows - 1))
    }
}

extension VisionTerminalView: UIGestureRecognizerDelegate {
    /// SwiftTerm adds pans of its own — one for selection after a long press, one
    /// for mouse reporting whenever the remote enables tracking (inert here, since
    /// `allowMouseReporting` is off). Recognizing alongside them keeps scrolling
    /// working without taking selection away.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
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
        terminal.enableScrollGesture()
        // Opaque dark backdrop — visionOS glass washes out ANSI colors.
        let dark = UIColor(white: 0.07, alpha: 1.0)
        terminal.nativeBackgroundColor = dark
        terminal.backgroundColor = dark
        terminal.isOpaque = true
        terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Don't forward taps and drags as mouse input: pointing is the composer +
        // quick-key row's job here, and a tap is more useful as local selection.
        // Scrolling is the exception — `enableScrollGesture` sends wheel events of
        // its own when the remote is tracking the mouse, since a full-screen
        // program's viewport can't be scrolled any other way.
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
