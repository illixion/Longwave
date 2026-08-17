#if canImport(UIKit)
import UIKit
import os

/// The first-responder etiquette shared by every hardware-keyboard capture view
/// (VNC, Moonlight, Native). Each transport subclasses this and only implements
/// `pressesBegan`/`pressesEnded`.
///
/// One invariant, in one place: **a capture view may hold first responder only
/// while nothing in the app is entering text.** Asking `TextInputActivity` before
/// *taking* the responder — which is all these views used to do — is only half of
/// it. A capture view that already had it kept it when a text field in another
/// window started editing, and since `becomeFirstResponder()` also makes a view's
/// window the key window, the stream window went on receiving every hardware key
/// press. That is why typing into "Add Connection" with a Bluetooth keyboard went
/// nowhere while a stream or terminal window was open: the keys were being
/// forwarded to the remote instead. So text entry is now announced on both edges
/// (`.textEntryDidBegin` / `.textEntryDidEnd`) and this view yields and reclaims.
class KeyCaptureResponderView: UIView {
    override var canBecomeFirstResponder: Bool { true }

    private var observers: [NSObjectProtocol] = []

    /// Whether a press should be forwarded to the remote at all. Text entry is
    /// polled, so a keystroke can still arrive in the window between a text field
    /// becoming first responder and our yielding to it — those must fall through
    /// to the responder chain rather than being eaten.
    var mayCaptureKeys: Bool { !TextInputActivity.shared.isEntering }

    /// Which log category this transport's grab attempts are recorded under.
    var captureLog: Logger { AppLog.app }

    /// Name used in those log lines.
    var captureLogName: String { "KeyCaptureView" }

    /// Called when the view leaves its window, after the observers are torn down
    /// — VNC releases its sticky modifiers here.
    func keyCaptureViewDidLeaveWindow() {}

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            keyCaptureViewDidLeaveWindow()
            return
        }
        if observers.isEmpty {
            let center = NotificationCenter.default
            // Re-grab first responder whenever this window becomes key — e.g.
            // after the keyboard window closes — so hardware keyboard input
            // works without the keyboard window open, not just while focused.
            observers.append(center.addObserver(
                forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, (note.object as? UIWindow) === self.window else { return }
                self.reclaimFirstResponder()
            })
            observers.append(center.addObserver(
                forName: .textEntryDidBegin, object: nil, queue: .main
            ) { [weak self] _ in
                self?.yieldToTextEntry()
            })
            // And once text entry finishes, since a grab attempted during a
            // typing/dictation session is declined rather than forced.
            observers.append(center.addObserver(
                forName: .textEntryDidEnd, object: nil, queue: .main
            ) { [weak self] _ in
                self?.reclaimFirstResponder(afterTextEntry: true)
            })
        }
        reclaimFirstResponder()
        // Retry shortly after — the window/scene may not accept first
        // responder at the instant the view is attached.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reclaimFirstResponder()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Become first responder unless something is presented over our window
    /// (don't steal focus from the credential prompt sheet's text field) or the
    /// user is entering text anywhere in the app — taking the responder out from
    /// under a live session ends dictation. We do NOT gate on `isKeyWindow` — on
    /// visionOS that can be false even for the window the user is looking at,
    /// which would block capture entirely.
    ///
    /// `afterTextEntry` marks the reclaim that follows a text session ending.
    /// That one *does* consult the key window: the session may well have been in
    /// another window the user is still working in, and grabbing the responder
    /// back would drag the key window over with it.
    private func reclaimFirstResponder(afterTextEntry: Bool = false) {
        guard let window = self.window else { return }
        if window.rootViewController?.presentedViewController != nil { return }
        if !TextInputActivity.shared.mayTakeFirstResponder() { return }
        if isFirstResponder { return }
        if afterTextEntry, !mayTakeKeyFocus(from: window) { return }
        let ok = becomeFirstResponder()
        captureLog.line("\(captureLogName) becomeFirstResponder -> \(ok) (isKeyWindow=\(window.isKeyWindow))")
    }

    /// Hand the keyboard to the text session that just started. The responder
    /// comes back via `.textEntryDidEnd`.
    private func yieldToTextEntry() {
        guard isFirstResponder else { return }
        _ = resignFirstResponder()
        captureLog.line("\(captureLogName) yielded first responder to text entry")
    }

    /// visionOS frequently reports *no* key window at all, so a plain
    /// `isKeyWindow` test would leave capture off for good. Stand down only when
    /// some other window has actually claimed it.
    private func mayTakeKeyFocus(from window: UIWindow) -> Bool {
        if window.isKeyWindow { return true }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if windowScene.windows.contains(where: { $0.isKeyWindow && $0 !== window }) {
                return false
            }
        }
        return true
    }
}
#endif
