import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Network
import UserNotifications

/// Every macOS grant the Companion's features depend on, read in one place so
/// the setup assistant can ask for them up front instead of letting each one
/// surprise the user later — Screen Recording in particular used to prompt on
/// the Mac the first time a headset subscribed, while its wearer couldn't see
/// the Mac.
///
/// Status is re-read when the app becomes active (what returning from System
/// Settings looks like) and every two seconds while someone is watching, i.e.
/// while the setup window is open. Accessibility keeps its own live monitor.
@Observable
@MainActor
final class PermissionCenter {
    enum Kind: String, CaseIterable, Identifiable {
        case localNetwork, screenRecording, systemAudio, accessibility, notifications, musicAutomation
        case sandboxInstalled, fullDiskAccess, remoteLogin, screenSharing
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case granted
        /// Asked and refused, or switched off since: only System Settings can
        /// turn it back on.
        case denied
        /// Not asked yet — the button shows the system prompt.
        case notDetermined
        /// Can't be checked right now (e.g. Music isn't running).
        case unknown
    }

    static let shared = PermissionCenter()
    static let setupURL = URL(string: "longwave-companion://setup")!

    private(set) var statuses: [Kind: Status] = [:]
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var presence: CompanionPresence?
    @ObservationIgnored private weak var sandbox: LocalSandboxController?

    private static let systemAudioKey = "setup.systemAudioAllowed"

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PermissionCenter.shared.refresh() }
        }
    }

    func attach(presence: CompanionPresence, sandbox: LocalSandboxController) {
        self.presence = presence
        self.sandbox = sandbox
        refresh()
    }

    func status(_ kind: Kind) -> Status { statuses[kind] ?? .unknown }

    /// Starts the two-second refresh while at least one view is watching.
    func beginWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in PermissionCenter.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    func refresh() {
        statuses[.localNetwork] = presence?.localNetworkDenied == true ? .denied : .granted
        statuses[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        statuses[.systemAudio] = switch UserDefaults.standard.object(forKey: Self.systemAudioKey) as? Bool {
        case true?: .granted
        case false?: .denied
        case nil: .notDetermined
        }
        statuses[.accessibility] = AccessibilityTrustMonitor.shared.recheck() ? .granted : .notDetermined
        if let sandbox {
            statuses[.sandboxInstalled] = sandbox.availability == .ready ? .granted : .notDetermined
            statuses[.fullDiskAccess] = sandbox.hasFullDiskAccess ? .granted : .notDetermined
        }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            statuses[.notifications] = switch settings.authorizationStatus {
            case .authorized, .provisional: .granted
            case .denied: .denied
            default: .notDetermined
            }
            statuses[.musicAutomation] = await Self.musicAutomationStatus(ask: false)
            statuses[.remoteLogin] = await Self.loopbackPortOpen(UInt16(LocalSandbox.sshPort)) ? .granted : .notDetermined
            statuses[.screenSharing] = await Self.loopbackPortOpen(LocalSandbox.vncPort) ? .granted : .notDetermined
        }
    }

    // MARK: - Asking

    /// Shows the system prompt where macOS has one, otherwise opens the
    /// System Settings pane where the user switches it on.
    func request(_ kind: Kind) {
        switch kind {
        case .localNetwork:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        case .screenRecording:
            // Only the first call prompts; once answered it returns at once,
            // and only System Settings can change the answer.
            if !CGRequestScreenCaptureAccess() {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        case .systemAudio:
            if status(.systemAudio) == .denied {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            } else {
                probeSystemAudio()
            }
        case .accessibility:
            AccessibilityTrustMonitor.shared.prompt()
        case .notifications:
            if status(.notifications) == .denied {
                open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
            } else {
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    refresh()
                }
            }
        case .musicAutomation:
            if status(.musicAutomation) == .denied {
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            } else {
                Task {
                    statuses[.musicAutomation] = await Self.musicAutomationStatus(ask: true)
                }
            }
        case .sandboxInstalled:
            break // SetupAssistantView runs the installer itself.
        case .fullDiskAccess:
            sandbox?.openFullDiskAccessSettings()
        case .remoteLogin, .screenSharing:
            open("x-apple.systempreferences:com.apple.Sharing-Settings.extension")
        }
        refresh()
    }

    /// Recorded by the audio server whenever it creates or fails to create the
    /// tap, so the row reflects real use as well as the assistant's probe.
    func recordSystemAudio(allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: Self.systemAudioKey)
        statuses[.systemAudio] = allowed ? .granted : .denied
    }

    /// No API reads the system-audio grant, so the assistant creates a tap
    /// briefly: that raises the prompt here, at the Mac, and its outcome is the
    /// answer.
    private func probeSystemAudio() {
        let tap = SystemAudioTap()
        do {
            _ = try tap.start(muteSystemOutput: false)
            recordSystemAudio(allowed: true)
            Task {
                try? await Task.sleep(for: .seconds(1))
                tap.stop()
            }
        } catch {
            tap.stop()
            recordSystemAudio(allowed: false)
        }
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Probes

    /// Music.app has to be running for macOS to answer. Asking launches it in
    /// the background first, since the prompt is the point.
    private nonisolated static func musicAutomationStatus(ask: Bool) async -> Status {
        let bundleID = "com.apple.Music"
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if !running {
            guard ask, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return .unknown }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            try? await Task.sleep(for: .seconds(1))
        }
        return await Task.detached {
            var target = AEAddressDesc()
            let data = Array(bundleID.utf8)
            guard AECreateDesc(DescType(typeApplicationBundleID), data, data.count, &target) == noErr else { return Status.unknown }
            defer { AEDisposeDesc(&target) }
            let result = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
            switch result {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
            default: return .unknown
            }
        }.value
    }

    /// Remote Login and Screen Sharing have no API an app may read; whether
    /// their port answers on loopback is what the sandbox actually needs.
    private nonisolated static func loopbackPortOpen(_ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = OnceFlag()
            let finish: @Sendable (Bool) -> Void = { open in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { finish(false) }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
