import Foundation
@preconcurrency import RoyalVNCKit
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// Connection state for the app UI
enum AppConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnecting
    case disconnected(error: String?)

    var isActive: Bool {
        switch self {
        case .connecting, .connected, .disconnecting: return true
        default: return false
        }
    }

    var statusText: String {
        switch self {
        case .idle: return "Not Connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        case .disconnected(let error):
            return error != nil ? "Disconnected: \(error!)" : "Disconnected"
        }
    }
}

/// Central orchestrator for VNC connections.
/// Wraps VNCConnection, implements VNCConnectionDelegate, and exposes
/// @Observable state for SwiftUI consumption.
@Observable
final class VNCConnectionManager: NSObject, VNCConnectionDelegate {

    // MARK: - Observable State

    var connectionState: AppConnectionState = .idle
    var connectionTitle: String = ""
    var framebufferImage: CGImage?
    var framebufferSize: CGSize = .zero

    // Credential prompt state
    var isCredentialPromptPresented: Bool = false
    var credentialAuthType: VNCAuthenticationType = .vnc

    /// macOS: hide the system pointer while it's over the remote view (set from
    /// the connection). Ignored on visionOS.
    var hideLocalCursor: Bool = false

    // Touch mode & virtual cursor
    var touchMode: TouchMode = .absolute
    var virtualCursorX: UInt16 = 0
    var virtualCursorY: UInt16 = 0

    // Trackpad-only mode (transparent overlay, no video)
    var isTrackpadOnly: Bool = false

    /// Modifiers currently latched sticky by a hardware-keyboard double-tap
    /// (see `KeyCaptureView`) — held down at the remote until tapped again.
    /// Purely a UI signal for the stream view's badge; the actual down/up
    /// state lives in `KeyCaptureView` itself.
    var stickyModifiers: VirtualModifiers = []

    // Optional reference to the SavedConnection driving this session,
    // used by the credential prompt's "Remember Password" toggle.
    var pendingSavedConnection: SavedConnection?

    // MARK: - Companion Audio

    /// Settings for an audio stream to start alongside this VNC session,
    /// resolved from a saved audio connection to the same host. Resolved
    /// by `ConnectionListView` and handed to `connect(...)`.
    struct AudioCompanion {
        let hostname: String
        let port: UInt16
        let token: String
        let title: String
        let lowLatency: Bool
    }

    /// Audio stream manager, wired up at app launch. When a VNC session has
    /// a resolved `AudioCompanion`, this is driven in lockstep with the VNC
    /// connection lifecycle.
    weak var audioManager: AudioStreamManager?

    private var audioCompanion: AudioCompanion?
    /// True only when *we* started the companion audio stream. An audio
    /// session the user already had open separately is never touched.
    private var startedCompanionAudio = false

    // MARK: - Companion Text Injection (keyboard bypass)

    /// Where typed text is routed. `.companion` (default) sends literal text to
    /// the Mac companion when its channel is up; `.vnc` always uses VNC key
    /// codes. Modifiers and special keys always use VNC regardless.
    enum KeyboardRoute: String, CaseIterable, Identifiable, Sendable {
        case companion, vnc
        var id: String { rawValue }
        var label: String { self == .companion ? "Companion" : "VNC keys" }
    }

    /// Host + token for the companion's text-injection channel, resolved from
    /// the same companion connection that provides audio.
    struct CompanionInject {
        let hostname: String
        let port: UInt16
        let token: String
    }

    /// User's preferred typing route. Defaults to the companion (modifier-safe,
    /// dictation-friendly) when available.
    var keyboardRoute: KeyboardRoute = .companion
    /// True when the companion inject channel is connected and the Mac will
    /// actually type (toggle on + Accessibility granted).
    private(set) var companionInputAvailable = false

    /// Whether typing is currently going through the companion.
    var usingCompanionInput: Bool { keyboardRoute == .companion && companionInputAvailable }

    /// Whether this session has a companion inject channel configured at all
    /// (drives whether the keyboard window shows a route picker).
    var hasCompanionInput: Bool { companionInject != nil }

    private var companionInject: CompanionInject?
    private var injectClient: CompanionInjectClient?

    /// True when this VNC session has a resolved audio companion (a saved
    /// audio connection to the same host). Drives the audio button in the
    /// remote desktop toolbar.
    var hasCompanionAudio: Bool { audioCompanion != nil }

    // MARK: - Private State

    private var connection: VNCConnection?
    private var framebuffer: VNCFramebuffer?
    private var storedUsername: String?
    private var storedPassword: String?
    private var credentialCompletion: (((VNCCredential?) -> Void))?

    // Throttle framebuffer rendering via CADisplayLink
    private var pendingImageUpdate: Bool = false
    private var displayLink: CADisplayLink?
    private var virtualCursorInitialized = false
    private var lastImagePublish: ContinuousClock.Instant?

    // MARK: - Connection Lifecycle

    func connect(hostname: String, port: UInt16, username: String? = nil, password: String? = nil, colorDepth: VNCConnection.Settings.ColorDepth = .depth24Bit, jpegQualityLevel: Int = 6, compressionLevel: Int = 6, touchMode: TouchMode = .absolute, trackpadOnly: Bool = false, title: String? = nil, audioCompanion: AudioCompanion? = nil, companionInject: CompanionInject? = nil) {
        disconnect()
        // Tear down any companion audio from a previous session before
        // taking on the new one (no-op if we never owned one).
        stopCompanionAudioIfStarted()
        self.audioCompanion = audioCompanion
        self.companionInject = companionInject

        self.touchMode = touchMode
        self.isTrackpadOnly = trackpadOnly
        self.virtualCursorInitialized = false

        connectionTitle = title ?? "\(hostname):\(port)"
        storedUsername = username
        storedPassword = password

        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: hostname,
            port: port,
            isShared: true,
            isScalingEnabled: false,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: true,
            colorDepth: colorDepth,
            frameEncodings: .default,
            jpegQualityLevel: jpegQualityLevel,
            compressionLevel: compressionLevel
        )

        let conn = VNCConnection(settings: settings)
        conn.delegate = self
        self.connection = conn
        self.connectionState = .connecting

        conn.connect()

        // Skip display link in trackpad-only mode — no video rendering needed
        if !trackpadOnly {
            startDisplayLink()
        }
    }

    func disconnect() {
        connection?.disconnect()
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        stopDisplayLink()

        guard let link = DisplayLinkFactory.make(target: self, selector: #selector(displayLinkFired)) else { return }
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30, maximum: 90, preferred: 60
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired() {
        guard pendingImageUpdate, let fb = framebuffer else { return }
        // Pace the desktop down while the user is entering text anywhere in the
        // app: republishing an image every tick keeps SwiftUI and UIKit busy at
        // frame rate, which is what ends a visionOS dictation session (a remote
        // desktop showing a busy terminal is the same "actively changing text"
        // case as the SSH view). Nothing is dropped — `pendingImageUpdate` holds
        // the newest frame and the next allowed tick publishes it.
        let interval = TextInputActivity.shared.minimumUpdateInterval
        let now = ContinuousClock.now
        if interval != .zero, let last = lastImagePublish, now - last < interval { return }
        pendingImageUpdate = false
        lastImagePublish = now
        framebufferImage = fb.cgImage
    }

    // MARK: - VNCConnectionDelegate

    nonisolated func connection(_ connection: VNCConnection,
                                stateDidChange connectionState: VNCConnection.ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch connectionState.status {
            case .connecting:
                self.connectionState = .connecting
            case .connected:
                self.connectionState = .connected
                self.startCompanionAudioIfNeeded()
                self.startInjectClientIfNeeded()
            case .disconnecting:
                self.connectionState = .disconnecting
            case .disconnected:
                let errorMsg = connectionState.error?.localizedDescription
                self.connectionState = .disconnected(error: errorMsg)
                self.stopDisplayLink()
                self.connection = nil
                self.framebuffer = nil
                self.framebufferImage = nil
                self.isTrackpadOnly = false
                self.stopCompanionAudioIfStarted()
                self.stopInjectClient()
            }
        }
    }

    // MARK: - Companion Audio Lifecycle

    /// Starts the resolved companion audio stream alongside the VNC session.
    /// Only acts when the audio manager is idle — if the user already has an
    /// audio session open (to this host or any other), it's left untouched
    /// and we don't take over its lifecycle.
    private func startCompanionAudioIfNeeded() {
        guard !startedCompanionAudio,
              let audioManager,
              let companion = audioCompanion else { return }

        switch audioManager.state {
        case .idle, .error:
            audioManager.connect(
                hostname: companion.hostname,
                port: companion.port,
                token: companion.token,
                title: companion.title,
                lowLatency: companion.lowLatency
            )
            startedCompanionAudio = true
        case .connecting, .streaming:
            // A separately-opened audio session is already live — don't
            // displace it, and don't manage its lifecycle.
            break
        }
    }

    /// Tears down the companion audio stream, but only if we started it.
    private func stopCompanionAudioIfStarted() {
        guard startedCompanionAudio else { return }
        startedCompanionAudio = false
        audioManager?.userDisconnect()
    }

    // MARK: - Companion Inject Lifecycle

    /// Opens the text-injection channel to the companion (if one is configured).
    /// Availability is reported asynchronously via the channel handshake.
    private func startInjectClientIfNeeded() {
        injectClient?.close()
        injectClient = nil
        companionInputAvailable = false
        guard let inject = companionInject, !inject.token.isEmpty else { return }

        let client = CompanionInjectClient(
            config: .init(host: inject.hostname, port: inject.port, token: inject.token)
        )
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event {
                case .available(let ok): self.companionInputAvailable = ok
                case .closed: self.companionInputAvailable = false
                }
            }
        }
        injectClient = client
        client.start()
    }

    private func stopInjectClient() {
        injectClient?.close()
        injectClient = nil
        companionInputAvailable = false
    }

    nonisolated func connection(_ connection: VNCConnection,
                                credentialFor authenticationType: VNCAuthenticationType,
                                completion: @escaping (VNCCredential?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(nil)
                return
            }

            // Auto-submit stored credentials if available
            if let password = self.storedPassword, !password.isEmpty {
                self.storedPassword = nil
                if authenticationType.requiresUsername, let username = self.storedUsername, !username.isEmpty {
                    self.storedUsername = nil
                    completion(VNCUsernamePasswordCredential(username: username, password: password))
                    return
                } else if !authenticationType.requiresUsername {
                    completion(VNCPasswordCredential(password: password))
                    return
                }
                // If username required but not provided, fall through to prompt
            }

            // Present credential prompt
            self.credentialCompletion = completion
            self.credentialAuthType = authenticationType
            self.isCredentialPromptPresented = true
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didCreateFramebuffer framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.framebuffer = framebuffer
            self.framebufferSize = size
            if !self.isTrackpadOnly {
                self.framebufferImage = framebuffer.cgImage
            }

            // Trackpad-only: stop requesting updates — we only needed the size
            if self.isTrackpadOnly {
                connection.pauseFramebufferUpdates()
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didResizeFramebuffer framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.framebuffer = framebuffer
            self.framebufferSize = size
            if !self.isTrackpadOnly {
                self.framebufferImage = framebuffer.cgImage
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didUpdateFramebuffer framebuffer: VNCFramebuffer,
                                x: UInt16, y: UInt16,
                                width: UInt16, height: UInt16) {
        Task { @MainActor [weak self] in
            self?.pendingImageUpdate = true
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                didUpdateCursor cursor: VNCCursor) {
        // visionOS has no custom cursor; skip for now
    }

    // MARK: - Credential Submission

    func submitCredential(username: String?, password: String, remember: Bool = false) {
        let credential: VNCCredential
        if let username, credentialAuthType.requiresUsername {
            credential = VNCUsernamePasswordCredential(username: username, password: password)
        } else {
            credential = VNCPasswordCredential(password: password)
        }
        if remember, let saved = pendingSavedConnection {
            saved.savedUsername = (credentialAuthType.requiresUsername ? (username ?? "") : "")
            saved.savedPassword = password
            saved.autoLogin = true
        }
        credentialCompletion?(credential)
        credentialCompletion = nil
        isCredentialPromptPresented = false
    }

    func cancelCredential() {
        credentialCompletion?(nil)
        credentialCompletion = nil
        isCredentialPromptPresented = false
    }

    // MARK: - Input Forwarding

    func sendMouseMove(x: UInt16, y: UInt16) {
        connection?.mouseMove(x: x, y: y)
    }

    func sendMouseDown(button: VNCMouseButton, x: UInt16, y: UInt16) {
        connection?.mouseButtonDown(button, x: x, y: y)
    }

    func sendMouseUp(button: VNCMouseButton, x: UInt16, y: UInt16) {
        connection?.mouseButtonUp(button, x: x, y: y)
    }

    func sendScroll(wheel: VNCMouseWheel, x: UInt16, y: UInt16, steps: UInt32 = 3) {
        connection?.mouseWheel(wheel, x: x, y: y, steps: steps)
    }

    func sendKeyDown(_ key: VNCKeyCode) {
        connection?.keyDown(key)
    }

    func sendKeyUp(_ key: VNCKeyCode) {
        connection?.keyUp(key)
    }

    // MARK: - Keyboard Text Routing

    /// Type literal text. When the companion route is active the text is sent
    /// to the Mac companion for Unicode injection (modifier-safe, dictation-
    /// friendly); otherwise it's typed into VNC one character at a time
    /// (newlines → Return, non-printables dropped by `VNCKeyCode.withCharacter`).
    /// Special keys and modifiers always use VNC, never this path.
    func routeInsertText(_ text: String) {
        if usingCompanionInput {
            injectClient?.sendText(text)
            return
        }
        for char in text {
            if char.isNewline {
                sendKeyDown(.return)
                sendKeyUp(.return)
            } else {
                for code in VNCKeyCode.withCharacter(char) {
                    sendKeyDown(code)
                    sendKeyUp(code)
                }
            }
        }
    }

    /// Emit `count` backspaces — via the companion when active, else via VNC.
    /// Note the RoyalVNCKit naming trap: `VNCKeyCode.delete` is `XK_BackSpace`
    /// (backspace), while `.forwardDelete` is the forward Delete key.
    func routeDeleteBackward(_ count: Int) {
        guard count > 0 else { return }
        if usingCompanionInput {
            injectClient?.sendBackspace(count)
            return
        }
        for _ in 0..<count {
            sendKeyDown(.delete)
            sendKeyUp(.delete)
        }
    }

    // MARK: - Virtual Cursor (Relative/Touchpad Mode)

    /// Lazily initializes the virtual cursor to the center of the framebuffer.
    private func initializeVirtualCursorIfNeeded() {
        guard !virtualCursorInitialized, framebufferSize.width > 0 else { return }
        virtualCursorX = UInt16(framebufferSize.width / 2)
        virtualCursorY = UInt16(framebufferSize.height / 2)
        virtualCursorInitialized = true
    }

    /// Move the virtual cursor by framebuffer-space deltas, clamped to bounds.
    func moveVirtualCursor(dx: CGFloat, dy: CGFloat) {
        initializeVirtualCursorIfNeeded()

        let newX = CGFloat(virtualCursorX) + dx
        let newY = CGFloat(virtualCursorY) + dy

        virtualCursorX = UInt16(clamping: Int(max(0, min(newX, framebufferSize.width - 1))))
        virtualCursorY = UInt16(clamping: Int(max(0, min(newY, framebufferSize.height - 1))))

        sendMouseMove(x: virtualCursorX, y: virtualCursorY)
    }

    /// Send a click at the current virtual cursor position.
    func clickAtVirtualCursor(button: VNCMouseButton) {
        initializeVirtualCursorIfNeeded()
        sendMouseDown(button: button, x: virtualCursorX, y: virtualCursorY)
        sendMouseUp(button: button, x: virtualCursorX, y: virtualCursorY)
    }

    /// Send scroll at the current virtual cursor position.
    func scrollAtVirtualCursor(wheel: VNCMouseWheel, steps: UInt32 = 3) {
        initializeVirtualCursorIfNeeded()
        sendScroll(wheel: wheel, x: virtualCursorX, y: virtualCursorY, steps: steps)
    }

    /// Press (and hold) a button at the current virtual cursor — used to begin a
    /// gaze drag lock; pair with `releaseMouseAtVirtualCursor`.
    func pressMouseAtVirtualCursor(button: VNCMouseButton) {
        initializeVirtualCursorIfNeeded()
        sendMouseDown(button: button, x: virtualCursorX, y: virtualCursorY)
    }

    /// Release a held button at the current virtual cursor (ends a drag lock).
    func releaseMouseAtVirtualCursor(button: VNCMouseButton) {
        initializeVirtualCursorIfNeeded()
        sendMouseUp(button: button, x: virtualCursorX, y: virtualCursorY)
    }

    /// Move the cursor to an absolute framebuffer position — used for pointer
    /// hover from a Bluetooth mouse (`onContinuousHover`), which fires without a
    /// button held (unlike a drag gesture). The virtual cursor is kept in sync
    /// so a subsequent relative-mode click lands where the pointer is.
    func moveCursorAbsolute(x: UInt16, y: UInt16) {
        virtualCursorX = x
        virtualCursorY = y
        virtualCursorInitialized = true
        sendMouseMove(x: x, y: y)
    }
}
