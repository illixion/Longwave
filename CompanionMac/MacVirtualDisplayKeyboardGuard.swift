import AppKit
import ApplicationServices
import CoreGraphics
import DebugTrace
import notify

/// Keeps the headset's typing landing in the Mac app the user was in while
/// they use Apple's Mac Virtual Display.
///
/// The problem: to press a key on Longwave's keyboard window, or hold its
/// push-to-talk button, the user looks away from the Mac Virtual Display.
/// visionOS then hands the Mac's keyboard to Universal Control, which makes
/// itself the frontmost app and discards keys arriving through the HID event
/// system — which is exactly where `InjectionService` and
/// `MacNativeInputService` post. So every key typed from the headset would go
/// nowhere and the Mac window would lose focus.
///
/// While Universal Control reports it holds the keyboard *and* a Mac Virtual
/// Display session is up, keys are routed here instead: the first one brings
/// the remembered app back to the front, keys that arrive while it comes
/// back are held and delivered in order, and from then on events go through
/// the session event stream (which Universal Control does not swallow and
/// which global hotkeys, push-to-talk included, still see) while that app is
/// frontmost, or straight to its process when visionOS won't let it be.
/// The same approach as FocusGuard (`~/Projects/FocusGuard`), which does this
/// for the Mac's own physical keyboard; both can run at once, since that one
/// reads hardware keys and never sees these.
@Observable
final class MacVirtualDisplayKeyboardGuard {
    static let shared = MacVirtualDisplayKeyboardGuard()

    private static let log = DebugLogger(
        subsystem: Bundle.main.bundleIdentifier ?? "pro.longwave.companion",
        category: "MacVDKeyboard"
    )

    /// On by default: without it, headset typing simply doesn't work in Mac
    /// Virtual Display, and outside one the guard never acts.
    var enabled: Bool {
        get {
            access(keyPath: \.enabled)
            return UserDefaults.standard.object(forKey: "macVDKeyboardGuardEnabled") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.enabled) {
                UserDefaults.standard.set(newValue, forKey: "macVDKeyboardGuardEnabled")
            }
        }
    }

    /// Universal Control's bundle id; it becomes frontmost while it holds the keyboard.
    private static let thiefBundleID = "com.apple.universalcontrol"
    /// Marks our own events, so anything watching can tell them from hardware.
    private static let injectTag: Int64 = 0x4C57_4B42 // "LWKB"

    @ObservationIgnored private var started = false
    @ObservationIgnored private var inputStateToken: Int32 = 0
    @ObservationIgnored private var inputStateAvailable = false

    @ObservationIgnored private var lastGoodApp: NSRunningApplication?
    @ObservationIgnored private var lastGoodWindow: AXUIElement?

    // Loop protection: if visionOS keeps taking focus back, stop fighting it for a while.
    @ObservationIgnored private var restoreTimes: [Date] = []
    @ObservationIgnored private var suspendedUntil = Date.distantPast

    // Events that arrive while the app is still being brought back. An app
    // that is not active yet answers a key with the error beep and drops it.
    @ObservationIgnored private var gateActive = false
    @ObservationIgnored private var gated: [CGEvent] = []
    @ObservationIgnored private var gateTimer: Timer?

    /// Key codes whose key-down went out through the session stream, so their
    /// key-up follows the same route even if the frontmost app changed since.
    @ObservationIgnored private var sessionRouted = Set<Int64>()
    @ObservationIgnored private var guardingLogged = false

    private init() {}

    /// Starts watching Universal Control and the frontmost app. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        let name = "user.uid.\(getuid()).com.apple.universalcontrol.inputstate"
        inputStateAvailable = notify_register_check(name, &inputStateToken) == NOTIFY_STATUS_OK
        if !inputStateAvailable {
            Self.log.info("Universal Control input state unavailable — Mac Virtual Display typing guard off")
        }
        if let front = NSWorkspace.shared.frontmostApplication { noteGood(front) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.noteGood(app) }
        }
    }

    // MARK: - Posting

    /// Posts a keyboard event from the headset: to the HID stream as usual, or
    /// rerouted while Universal Control holds the keyboard for Mac Virtual
    /// Display.
    func post(_ event: CGEvent) {
        guard isGuarding else {
            if guardingLogged {
                guardingLogged = false
                Self.log.info("keyboard back on the Mac — headset keys post normally")
            }
            sessionRouted.removeAll()
            closeGate()
            event.post(tap: .cghidEventTap)
            return
        }
        if !guardingLogged {
            guardingLogged = true
            Self.log.info("Universal Control holds the keyboard in Mac Virtual Display — rerouting headset keys")
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.injectTag)
        if !gateActive, restoreIfStolen() {
            openGateWhenFrontmost()
        }
        if gateActive {
            gated.append(event)
        } else {
            deliver(event)
        }
    }

    private var isGuarding: Bool {
        guard enabled, inputStateAvailable else { return false }
        var state: UInt64 = 0
        notify_get_state(inputStateToken, &state)
        // Bit 0: the remote device holds the keyboard. The Mac VD check only
        // runs once that is set, so normal typing never pays for it.
        return state & 1 != 0 && macVirtualDisplayActive
    }

    @ObservationIgnored private var macVDCheckedAt = Date.distantPast
    @ObservationIgnored private var macVDCached = false

    /// Reads the power assertions, so cached for a second rather than read per key.
    private var macVirtualDisplayActive: Bool {
        if Date().timeIntervalSince(macVDCheckedAt) > 1 {
            macVDCached = MacNativeVirtualDisplay.macVirtualDisplaySessionActive()
            macVDCheckedAt = Date()
        }
        return macVDCached
    }

    private func deliver(_ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let isUp = event.type == .keyUp
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let target = targetPid()
        if isUp, sessionRouted.remove(code) != nil {
            event.post(tap: .cgSessionEventTap)
            return
        }
        guard let target else { return }
        if frontPid == target {
            // The session stream delivers to the frontmost app and passes the
            // global-hotkey stage, so a push-to-talk key still reaches the
            // voice app listening for it.
            if event.type == .keyDown { sessionRouted.insert(code) }
            event.post(tap: .cgSessionEventTap)
        } else {
            event.postToPid(target)
        }
    }

    // MARK: - Gate

    private func openGateWhenFrontmost() {
        gateActive = true
        let started = Date()
        gateTimer?.invalidate()
        gateTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                guard !self.frontIsThief || Date().timeIntervalSince(started) > 0.8 else { return }
                timer.invalidate()
                self.gateTimer = nil
                // Frontmost is not quite key yet: give the window a moment to take the keyboard.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    MainActor.assumeIsolated { self?.openGate() }
                }
            }
        }
    }

    private func openGate() {
        guard gateActive else { return }
        gateActive = false
        let held = gated
        gated = []
        for event in held { deliver(event) }
    }

    private func closeGate() {
        gateTimer?.invalidate()
        gateTimer = nil
        gateActive = false
        gated = []
    }

    // MARK: - Focus tracking

    private static func isThief(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier?.lowercased() == thiefBundleID
    }

    private var frontIsThief: Bool { Self.isThief(NSWorkspace.shared.frontmostApplication) }

    private func noteGood(_ app: NSRunningApplication) {
        guard !Self.isThief(app), app.processIdentifier != getpid() else { return }
        lastGoodApp = app
        // Let focus settle, then remember the focused window so the
        // Accessibility fallback can raise that one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                else { return }
                self.lastGoodWindow = Self.focusedWindow(of: app)
            }
        }
    }

    /// The app to type into: the frontmost real app, else the last one seen.
    private func targetPid() -> pid_t? {
        if let front = NSWorkspace.shared.frontmostApplication, !Self.isThief(front),
           front.processIdentifier != getpid() {
            return front.processIdentifier
        }
        if let app = lastGoodApp, !app.isTerminated { return app.processIdentifier }
        return nil
    }

    /// Re-activates the app Universal Control took the front from. Returns
    /// whether it started doing so, so the caller can hold keys meanwhile.
    private func restoreIfStolen() -> Bool {
        guard frontIsThief, let target = lastGoodApp, !target.isTerminated,
              Date() >= suspendedUntil else { return false }
        restoreTimes.append(Date())
        restoreTimes.removeAll { $0 < Date().addingTimeInterval(-10) }
        if restoreTimes.count >= 6 {
            suspendedUntil = Date().addingTimeInterval(15)
            Self.log.info("6 focus restores within 10 s — visionOS keeps taking it; backing off for 15 s")
            return false
        }
        Self.log.info("restoring focus to the app in use before Universal Control took it")
        target.activate()

        // Escalate to Accessibility if plain activation was refused.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.frontIsThief else { return }
                self.axRestore(target)
            }
        }
        return true
    }

    private func axRestore(_ target: NSRunningApplication) {
        guard AXIsProcessTrusted() else { return }
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = lastGoodWindow {
            AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    private static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
