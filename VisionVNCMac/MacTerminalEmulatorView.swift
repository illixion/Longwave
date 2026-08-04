import SwiftUI
import SwiftTerm
import AppKit

/// Hosts a SwiftTerm `TerminalView` (AppKit `NSView`) for an `SSHSession`.
///
/// Deliberately named `TerminalEmulatorView` with the same parameters as the
/// visionOS type, so the shared `SSHTerminalView` constructs it identically on
/// both platforms. On macOS a clicked terminal becomes first responder naturally,
/// so the focus request just nudges first responder to follow the SwiftUI toggle,
/// and `keyboardFocusIsDeliberate` has nothing to protect: macOS dictation isn't
/// hosted in a sibling window the way visionOS's is.
struct TerminalEmulatorView: NSViewRepresentable {
    let session: SSHSession
    var fontSize: Double = ConnectionDefaults.terminalFontSizeDefault
    var keyboardFocusEnabled: Bool = false
    var keyboardFocusRequest: Int = 0
    var keyboardFocusIsDeliberate: Bool = false
    var onKeyboardFocusChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        let dark = NSColor(white: 0.07, alpha: 1.0)
        terminal.nativeBackgroundColor = dark
        terminal.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Input comes from the composer + quick-key row; keep taps as local
        // selection rather than forwarded mouse reporting.
        terminal.allowMouseReporting = false
        session.attach(terminal)
        applyFocus(to: terminal)
        return terminal
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        if nsView.font.pointSize != fontSize {
            nsView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        applyFocus(to: nsView)
    }

    /// Keep first responder and the reported focus state in step, so the toggle
    /// button in the shared header reflects reality on macOS too. The report is
    /// deferred a turn: it lands in SwiftUI state, and this runs inside a view
    /// update.
    private func applyFocus(to terminal: TerminalView) {
        let isFocused = terminal.window?.firstResponder === terminal
        if keyboardFocusEnabled {
            guard !isFocused else { return }
            if terminal.window?.makeFirstResponder(terminal) == true {
                report(true)
            }
        } else if isFocused {
            terminal.window?.makeFirstResponder(nil)
            report(false)
        }
    }

    private func report(_ focused: Bool) {
        let notify = onKeyboardFocusChanged
        DispatchQueue.main.async { notify(focused) }
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    /// SwiftTerm delegate. `TerminalViewDelegate` isn't `@MainActor`, but
    /// SwiftTerm invokes it on the main thread, so we assume isolation to reach
    /// the MainActor `SSHSession` without an async hop (preserving keystroke order).
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: SSHSession
        init(session: SSHSession) { self.session = session }

        func detach() { MainActor.assumeIsolated { session.detach() } }

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
