import Foundation
import AppKit
import ApplicationServices

/// Types literal text into the frontmost Mac app on behalf of the Vision Pro,
/// using **only** two operations — Unicode insertion and backspace. There is no
/// way to express modifier flags or arbitrary key codes here, so a compromised
/// inject channel cannot synthesize Cmd+Space / Run-dialog "DuckyScript"
/// payloads. Posting requires the Accessibility (AXIsProcessTrusted)
/// permission; a master toggle (default off) gates it independently of TCC.
@Observable
final class InjectionService {

    /// Master switch, persisted. Off by default — the user opts in.
    var injectionEnabled: Bool {
        get {
            access(keyPath: \.injectionEnabled)
            return UserDefaults.standard.bool(forKey: "companionInjectEnabled")
        }
        set {
            withMutation(keyPath: \.injectionEnabled) {
                UserDefaults.standard.set(newValue, forKey: "companionInjectEnabled")
            }
        }
    }

    /// Whether this process holds the Accessibility permission.
    /// Read through `AccessibilityTrustMonitor`, which notices the grant
    /// changing on its own — a stored copy here only refreshed when some
    /// button asked it to.
    var accessibilityTrusted: Bool { AccessibilityTrustMonitor.shared.isTrusted }

    /// Fired after each injection — used by the menu bar for an activity glyph.
    var onInject: (() -> Void)?

    var isAvailable: Bool { injectionEnabled && accessibilityTrusted }

    /// Current availability as the wire `Status` byte for the inject protocol.
    var statusByte: UInt8 {
        if !injectionEnabled { return CompanionInjectProtocol.Status.disabled.rawValue }
        return (accessibilityTrusted ? CompanionInjectProtocol.Status.available
                                     : CompanionInjectProtocol.Status.accessibilityDenied).rawValue
    }

    func refreshAccessibility() {
        AccessibilityTrustMonitor.shared.recheck()
    }

    /// Re-checks Accessibility, prompting the user to grant it if missing.
    func promptAccessibility() {
        AccessibilityTrustMonitor.shared.prompt()
    }

    // MARK: - Injection (the only two operations)

    /// Inserts `string` verbatim. Chunks by grapheme so a surrogate pair or
    /// combining sequence is never split across CGEvents, keeping each event's
    /// unicode string within the ~20 UTF-16-unit comfort zone.
    func insertText(_ string: String) {
        guard isAvailable, !string.isEmpty else { return }
        var chunk: [UTF16.CodeUnit] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            postUnicode(chunk)
            chunk.removeAll(keepingCapacity: true)
        }
        for character in string {
            let units = Array(String(character).utf16)
            if !chunk.isEmpty, chunk.count + units.count > 20 { flush() }
            chunk.append(contentsOf: units)
            if chunk.count >= 20 { flush() }
        }
        flush()
        onInject?()
    }

    /// Emits `count` backspaces via the Delete (kVK_Delete = 0x33) key.
    func deleteBackward(_ count: Int) {
        guard isAvailable, count > 0 else { return }
        for _ in 0..<count {
            postKey(0x33, down: true)
            postKey(0x33, down: false)
        }
        onInject?()
    }

    // MARK: - CGEvent posting

    private func postUnicode(_ units: [UTF16.CodeUnit]) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        var buffer = units
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postKey(_ virtualKey: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: down) else { return }
        event.post(tap: .cghidEventTap)
    }
}
