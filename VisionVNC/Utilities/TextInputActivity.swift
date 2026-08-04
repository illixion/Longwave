import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// How much text entry is happening app-wide, ordered by how much protection an
/// active session needs from the rest of the app.
nonisolated enum TextEntryLevel: Sendable {
    /// Nothing is being edited — the app is free to drive UIKit as hard as it likes.
    case idle
    /// A text field somewhere holds first responder (typing, or just opened).
    case editing
    /// That field's input mode is dictation — the fragile case.
    case dictating
}

/// A UITextInput-conforming view that is a *display* surface rather than a
/// composition target (the SSH terminal). It can hold first responder without
/// the user entering text there, so it must not register as text entry — else
/// handing the keyboard to the terminal would make the app throttle itself.
protocol PassiveTextInputSurface: AnyObject {}

/// Minimum spacing between UI-driving updates from a streaming producer (SSH
/// terminal output, VNC framebuffer) while text entry is live.
///
/// visionOS ends a dictation session when the app keeps driving UIKit at frame
/// rate — this is the "dictation stops while a window has actively changing
/// text" failure, and it happens with the responder chain left untouched:
/// SwiftTerm rewrites its scroll offset and repaints per output chunk, VNC
/// republishes a `CGImage` every display-link tick. Pacing those producers down
/// while a session is live removes the pressure without freezing anything —
/// output keeps flowing, at 2–4 Hz instead of 60+, and returns to full rate the
/// moment the session ends.
nonisolated enum TextEntryPacing {
    static func minimumUpdateInterval(for level: TextEntryLevel) -> Duration {
        switch level {
        case .idle: return .zero
        case .editing: return .milliseconds(250)
        case .dictating: return .milliseconds(500)
        }
    }
}

extension Notification.Name {
    /// Posted when app-wide text entry ends, i.e. the level returns to `.idle`.
    /// Lets a caller that yielded first responder to a text session take it back.
    static let textEntryDidEnd = Notification.Name("VisionVNC.textEntryDidEnd")
}

/// App-wide answer to "is the user entering text right now, and is it dictation?"
///
/// Two classes of consumer, both serving the same bug:
///
/// - Hardware-keyboard capture views (VNC, Moonlight) and the SSH terminal grab
///   first responder on window/keyboard events. Taking it out from under a live
///   input session ends dictation, so they ask here first and retry on
///   `textEntryDidEnd` — a refused grab used to be dropped for good, which meant
///   capture never came back either.
/// - Streaming producers pace themselves against `minimumUpdateInterval` (see
///   `TextEntryPacing`).
///
/// State is derived by polling the responder chain rather than by subscribing to
/// begin/end-editing notifications: it assumes nothing about which private view
/// backs a SwiftUI `TextField`, and the dictation input mode is only visible this
/// way — it starts and stops without a notification of its own.
@MainActor
@Observable
final class TextInputActivity {
    static let shared = TextInputActivity()

    private(set) var level: TextEntryLevel = .idle

    var isEntering: Bool { level != .idle }

    /// Pacing for streaming producers. Reads the polled level: the gates it
    /// feeds are longer than the poll interval, so a slightly stale value is fine
    /// and a hierarchy walk per rendered frame is not.
    var minimumUpdateInterval: Duration {
        TextEntryPacing.minimumUpdateInterval(for: level)
    }

    private var pollTask: Task<Void, Never>?
    private static let pollInterval: Duration = .milliseconds(200)

    /// Begin polling. Idempotent; called once from the app delegate.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Whether a caller may take first responder without cutting off a live text
    /// session. Rescans rather than trusting the polled value — a grab decided on
    /// a stale reading is exactly the race that kills dictation.
    func mayTakeFirstResponder() -> Bool {
        refresh()
        return !isEntering
    }

    func refresh() {
        let next = Self.currentLevel()
        guard next != level else { return }
        let wasEntering = isEntering
        level = next
        if wasEntering, !isEntering {
            NotificationCenter.default.post(name: .textEntryDidEnd, object: nil)
        }
    }

    #if canImport(UIKit)
    private static func currentLevel() -> TextEntryLevel {
        guard let responder = activeTextInputResponder() else { return .idle }
        // The one public signal that the mic is live: while dictating, the
        // responder's input mode reports "dictation" as its primary language.
        if responder.textInputMode?.primaryLanguage == "dictation" { return .dictating }
        return .editing
    }

    private static func activeTextInputResponder() -> UIResponder? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let responder = window.activeTextInputDescendant() { return responder }
            }
        }
        return nil
    }
    #else
    private static func currentLevel() -> TextEntryLevel { .idle }
    #endif
}

#if canImport(UIKit)
private extension UIView {
    /// The focused text input in this subtree, if any. Display surfaces
    /// (`PassiveTextInputSurface`) are skipped — they conform to `UITextInput`
    /// without being somewhere the user enters text.
    func activeTextInputDescendant() -> UIResponder? {
        if isFirstResponder, self is UITextInput, !(self is PassiveTextInputSurface) {
            return self
        }
        for subview in subviews {
            if let responder = subview.activeTextInputDescendant() { return responder }
        }
        return nil
    }
}
#endif
