import Foundation
import AppKit
import ApplicationServices

/// Notices the Accessibility grant ("Device Control" since macOS 27) changing
/// while the companion runs, so nobody has to toggle a switch or press a
/// button to make the app see a permission it already has.
///
/// `AXIsProcessTrusted()` is cheap but nothing tells a process when its own
/// answer flips. Three signals cover it:
/// - `com.apple.accessibility.api`, the distributed notification System
///   Settings posts when the trusted list changes. It arrives *before* TCC has
///   committed the change, so the answer is re-read a little later as well.
/// - the app becoming active again, which is what returning from System
///   Settings looks like.
/// - a one-second poll, only while the permission is missing — the case where
///   the user is somewhere in System Settings right now.
@Observable
final class AccessibilityTrustMonitor {
    static let shared = AccessibilityTrustMonitor()

    private(set) var isTrusted = AXIsProcessTrusted()

    /// Fired on the main actor whenever `isTrusted` changes, so owners can push
    /// the new availability to live channels without observing the property.
    @ObservationIgnored private var handlers: [(Bool) -> Void] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AccessibilityTrustMonitor.shared.recheckSoon()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AccessibilityTrustMonitor.shared.recheck()
            }
        })
        updatePolling()
    }

    func onChange(_ handler: @escaping (Bool) -> Void) {
        handlers.append(handler)
    }

    /// Re-reads the grant now; returns the current answer.
    @discardableResult
    func recheck() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
            updatePolling()
            for handler in handlers { handler(trusted) }
        }
        return trusted
    }

    /// Shows the system prompt if the grant is missing, then re-reads it.
    func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        recheck()
        updatePolling()
    }

    /// The distributed notification races TCC's own write, so a read at the
    /// moment it lands can still see the old answer.
    private func recheckSoon() {
        recheck()
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.recheck()
            }
        }
    }

    private func updatePolling() {
        if isTrusted {
            pollTimer?.invalidate()
            pollTimer = nil
        } else if pollTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                Task { @MainActor in AccessibilityTrustMonitor.shared.recheck() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
    }
}
