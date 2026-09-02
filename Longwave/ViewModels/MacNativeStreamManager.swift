#if os(visionOS)
import Foundation
import AVFoundation
import UIKit

/// One subscribed per-window (Unity-style) stream: its own display layer and
/// renderer, plus the live metadata its visionOS scene renders from.
@Observable
final class MacNativeWindowSession: Identifiable {
    let windowID: UInt32
    let displayLayer: AVSampleBufferDisplayLayer
    let renderer: MacNativeVideoRenderer

    var id: UInt32 { windowID }
    /// Stream pixel size — the gesture-translation source of truth.
    var streamSize: CGSize = .zero
    var hasFrame = false
    /// Latest inventory entry for this window (title/app/focus updates).
    var info: MacNativeStreamProtocol.WindowInfo?
    /// Set when the host ended the stream — the scene dismisses itself.
    var closedReason: String?

    init(windowID: UInt32) {
        self.windowID = windowID
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
        layer.isOpaque = false
        self.displayLayer = layer
        self.renderer = MacNativeVideoRenderer(displayLayer: layer)
    }
}

@Observable
final class MacNativeStreamManager {
    enum State: Equatable {
        case disconnected(String?)
        case connecting
        case connected
        case streaming

        var statusText: String {
            switch self {
            case .disconnected(let message): message ?? "Disconnected"
            case .connecting: "Connecting to Mac…"
            case .connected: "Connected"
            case .streaming: "Streaming"
            }
        }
    }

    /// Whether the companion will act on mouse (or keyboard-shortcut) frames
    /// right now — mirrors `MacNativeStreamClient.Event.RemoteControlAvailability`,
    /// plus `.unknown` before the first status frame arrives (e.g. still
    /// connecting).
    enum RemoteControlAvailability: Equatable {
        case unknown
        case available
        case disabled
        case accessibilityDenied
    }

    private(set) var state: State = .disconnected(nil)
    private(set) var displayLayer: AVSampleBufferDisplayLayer?
    private(set) var streamSize: CGSize = .zero
    private(set) var title = "Native"

    // MARK: - v2 capabilities & per-window streams

    /// The server's v2 capability payload; nil while disconnected or when the
    /// server is v1.
    private(set) var serverAck: MacNativeStreamProtocol.HelloAck?
    /// The host's current streamable windows (v2 servers only).
    private(set) var windowInventory: [MacNativeStreamProtocol.WindowInfo] = []
    /// Subscribed per-window streams, keyed by host window ID. Each entry
    /// backs one ornament-free visionOS scene.
    private(set) var windowSessions: [UInt32: MacNativeWindowSession] = [:]
    /// Unity keeps the protocol session alive independently of the desktop
    /// scene and lets Unity Controls reconcile the host inventory into scenes.
    var unityEnabled = false
    private(set) var unityAutoShow = false
    private(set) var unityVisibleWindowIDs: Set<UInt32> = []
    private(set) var unityAutoShowSuppressedWindowIDs: Set<UInt32> = []

    var supportsWindowStreams: Bool { serverAck?.supportsWindowStreams ?? false }
    var keyCodeSpace: MacNativeStreamProtocol.KeyCodeSpace {
        serverAck?.keyCodeSpace ?? .macVirtual
    }
    /// "macOS"/"windows" — for display copy only.
    var serverPlatform: String { serverAck?.platform ?? "macOS" }
    /// Whether this host also serves the companion audio stream. Optimistic
    /// before the handshake lands, and for v1 hosts (which are always the
    /// macOS companion), so audio only gets pulled when a host says no.
    var hostServesAudio: Bool { serverAck?.servesAudioStream ?? true }
    private(set) var mouseAvailability: RemoteControlAvailability = .unknown
    /// Full keycode + modifier keyboard control. When this isn't `.available`,
    /// plain typing still tries the text-only fallback below — see
    /// `textInputAvailable`.
    private(set) var keyboardShortcutsAvailability: RemoteControlAvailability = .unknown

    /// Whether the always-attempted text-only fallback channel
    /// (`CompanionInjectProtocol` — the same one VNC typing uses) is
    /// currently up. Independent of `keyboardShortcutsAvailability`: this is
    /// what lets plain typing work even with shortcuts off.
    private(set) var textInputAvailable = false

    // MARK: - Touch mode & virtual cursor (mirrors VNCConnectionManager)

    var touchMode: TouchMode = .absolute
    private(set) var virtualCursorX: UInt16 = 0
    private(set) var virtualCursorY: UInt16 = 0
    private var virtualCursorInitialized = false
    private(set) var lastDesktopPointer: (x: UInt16, y: UInt16)?

    /// The Native connection this session targets — remembered independent
    /// of whether Screen is actually running, so the live Screen toggle in
    /// the Native window can start it later even if it was off when the
    /// window opened. Cleared only by `forget()` (the window's hard close),
    /// not by `disconnect()` (a live toggle-off).
    private(set) var connection: SavedConnection?

    /// True once toggled on, even mid-connect or after a drop — mirrors user
    /// intent rather than the transient handshake state, so the Screen
    /// toggle in the Native window doesn't flip itself off on a hiccup.
    var isEnabled: Bool {
        if case .disconnected = state { false } else { true }
    }

    /// The Native window's live Screen toggle, persisted separately from
    /// `state`: a transient drop or a deliberate toggle-off both leave
    /// `state` disconnected, but only this flag says whether Screen should
    /// resume after a scene reactivation or a full space-restoration
    /// relaunch (a fresh `MacNativeStreamManager` with no in-memory state).
    private static let liveEnabledKey = "nativeScreenLiveEnabled"
    var liveEnabled: Bool = UserDefaults.standard.bool(forKey: MacNativeStreamManager.liveEnabledKey) {
        didSet {
            guard liveEnabled != oldValue else { return }
            UserDefaults.standard.set(liveEnabled, forKey: Self.liveEnabledKey)
        }
    }

    private var client: MacNativeStreamClient?
    private var renderer: MacNativeVideoRenderer?
    private var activeConnectionID: UUID?
    /// Text-only typing fallback — the same channel/token VNC uses, opened
    /// alongside Screen so plain typing works even with keyboard shortcuts
    /// off (or before the user opts into them at all).
    private var injectClient: CompanionInjectClient?

    /// Remembers `connection` as this session's target without starting
    /// capture — used when opening the Native window with Screen initially
    /// off, so the live toggle has something to connect to.
    func prepare(for connection: SavedConnection) {
        self.connection = connection
        unityEnabled = connection.nativeUnityEnabled
        unityAutoShow = connection.nativeUnityAutoShow
        unityVisibleWindowIDs = []
        unityAutoShowSuppressedWindowIDs = []
    }

    func connect(to connection: SavedConnection) {
        self.connection = connection
        teardown()
        let connectionID = UUID()
        activeConnectionID = connectionID
        title = connection.displayName
        state = .connecting

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        // The desktop stream is the host's whole display, opaque edge to edge.
        // Letterboxing is the only place the layer's own color shows, and black
        // is what a screen shows there. Per-window streams are the transparent
        // ones — see `MacNativeWindowSession`.
        layer.backgroundColor = UIColor.black.cgColor
        layer.isOpaque = true
        displayLayer = layer

        let renderer = MacNativeVideoRenderer(displayLayer: layer)
        self.renderer = renderer
        let client = MacNativeStreamClient(
            config: .init(
                host: connection.hostname,
                port: MacNativeStreamProtocol.defaultPort,
                token: connection.companionToken,
                deviceName: UIDevice.current.name,
                wantsScreen: liveEnabled
            ),
            renderer: renderer
        )
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, connectionID: connectionID)
            }
        }
        self.client = client
        client.start()
        startInjectClient(hostname: connection.hostname, token: connection.companionToken)
    }

    /// Opens the text-only typing fallback channel — same host/token as
    /// Screen, independent lifecycle (its own TLS-PSK connection).
    private func startInjectClient(hostname: String, token: String) {
        injectClient?.close()
        textInputAvailable = false
        guard !token.isEmpty else {
            injectClient = nil
            return
        }
        let client = CompanionInjectClient(
            config: .init(host: hostname, port: CompanionInjectProtocol.defaultPort, token: token)
        )
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event {
                case .available(let available): self.textInputAvailable = available
                case .closed: self.textInputAvailable = false
                }
            }
        }
        injectClient = client
        client.start()
    }

    func sendInjectText(_ text: String) {
        injectClient?.sendText(text)
    }

    func sendInjectBackspace(_ count: Int) {
        injectClient?.sendBackspace(count)
    }

    /// Stops Screen but keeps `connection` remembered, so a live toggle
    /// back on (in the same Native window) can reconnect without needing
    /// the connection list again.
    func disconnect() {
        teardown()
    }

    /// Full teardown and forgets the target — called when the Native window
    /// is explicitly closed, so a stale target doesn't leak into the next
    /// session and Screen doesn't try to resume on a later relaunch.
    func forget() {
        teardown()
        for session in windowSessions.values {
            session.renderer.reset()
        }
        windowSessions = [:]
        connection = nil
        liveEnabled = false
        unityEnabled = false
        unityAutoShow = false
        unityVisibleWindowIDs = []
        unityAutoShowSuppressedWindowIDs = []
    }

    /// Connects the session if a target is known and nothing is live yet —
    /// used on the Native window's appearance so window streaming and the
    /// inventory work with the Screen (desktop) toggle off. Against a v1
    /// server with Screen off, the ack handler tears the session back down.
    func ensureSessionConnected() {
        guard !isEnabled, let connection else { return }
        connect(to: connection)
    }

    /// The Native window's Screen toggle changed. On a live v2 session this
    /// flips the desktop-stream subscription without touching the connection
    /// (per-window streams and the inventory keep running); otherwise it
    /// falls back to v1 behavior — connect or tear down the whole socket.
    func desktopToggleChanged(_ on: Bool) {
        if isEnabled, serverAck != nil {
            if on {
                client?.sendWindowStreamStart(windowID: MacNativeStreamProtocol.desktopStreamID)
            } else {
                client?.sendWindowStreamStop(windowID: MacNativeStreamProtocol.desktopStreamID)
                renderer?.reset()
            }
            if state == .streaming {
                state = .connected
            }
        } else if on {
            if let connection {
                connect(to: connection)
            }
        } else if serverAck == nil {
            disconnect()
        }
    }

    // MARK: - Per-window (Unity-style) streams

    /// Subscribes to a host window's stream, creating (or reviving) the
    /// session its visionOS scene renders from. Called by the scene's
    /// `onAppear`, so a scene that visionOS re-materializes after a transient
    /// hide re-requests its stream by itself.
    func openWindowStream(_ windowID: UInt32) {
        if let session = windowSessions[windowID] {
            session.closedReason = nil
            client?.setWindowRenderer(session.renderer, for: windowID)
            client?.sendWindowStreamStart(windowID: windowID)
            return
        }
        let session = MacNativeWindowSession(windowID: windowID)
        session.info = windowInventory.first { $0.id == windowID }
        session.renderer.onFormat = { [weak session] size in
            Task { @MainActor [weak session] in
                session?.streamSize = size
            }
        }
        session.renderer.onFirstFrame = { [weak session] in
            Task { @MainActor [weak session] in
                session?.hasFrame = true
            }
        }
        session.renderer.onError = { [weak session] message in
            Task { @MainActor [weak session] in
                session?.closedReason = message
            }
        }
        windowSessions[windowID] = session
        client?.setWindowRenderer(session.renderer, for: windowID)
        client?.sendWindowStreamStart(windowID: windowID)
    }

    /// Unsubscribes a window stream and forgets its session — called when
    /// its visionOS scene goes away.
    func closeWindowStream(_ windowID: UInt32) {
        guard let session = windowSessions.removeValue(forKey: windowID) else { return }
        client?.setWindowRenderer(nil, for: windowID)
        client?.sendWindowStreamStop(windowID: windowID)
        session.renderer.reset()
    }

    func setUnityAutoShow(_ enabled: Bool) {
        if enabled, !unityAutoShow {
            unityAutoShowSuppressedWindowIDs = []
        }
        unityAutoShow = enabled
        connection?.nativeUnityAutoShow = enabled
    }

    func markUnityWindowVisible(_ windowID: UInt32) {
        unityAutoShowSuppressedWindowIDs.remove(windowID)
        unityVisibleWindowIDs.insert(windowID)
    }

    func markUnityWindowHidden(_ windowID: UInt32, suppressAutoShow: Bool) {
        unityVisibleWindowIDs.remove(windowID)
        if suppressAutoShow {
            unityAutoShowSuppressedWindowIDs.insert(windowID)
        }
    }

    func pruneUnityWindowState(availableWindowIDs: Set<UInt32>) {
        unityVisibleWindowIDs.formIntersection(availableWindowIDs)
        unityAutoShowSuppressedWindowIDs.formIntersection(availableWindowIDs)
    }

    func unityWindowSceneDidClose(_ windowID: UInt32) {
        let wasVisible = unityVisibleWindowIDs.remove(windowID) != nil
        guard wasVisible,
              windowInventory.contains(where: { $0.id == windowID }) else { return }
        unityAutoShowSuppressedWindowIDs.insert(windowID)
    }

    func sendFocusWindow(windowID: UInt32) {
        client?.sendFocusWindow(windowID: windowID)
    }

    func sendWindowMouseMove(windowID: UInt32, x: UInt16, y: UInt16) {
        client?.sendWindowMouseMove(windowID: windowID, x: x, y: y)
    }

    func sendWindowMouseDown(
        windowID: UInt32,
        button: MacNativeStreamProtocol.MouseButton,
        x: UInt16,
        y: UInt16
    ) {
        client?.sendWindowMouseDown(windowID: windowID, button: button, x: x, y: y)
    }

    func sendWindowMouseUp(
        windowID: UInt32,
        button: MacNativeStreamProtocol.MouseButton,
        x: UInt16,
        y: UInt16
    ) {
        client?.sendWindowMouseUp(windowID: windowID, button: button, x: x, y: y)
    }

    func sendWindowScroll(windowID: UInt32, x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16) {
        client?.sendWindowScroll(windowID: windowID, x: x, y: y, deltaX: deltaX, deltaY: deltaY)
    }

    private func markAllWindowSessionsClosed(_ reason: String) {
        for session in windowSessions.values {
            session.closedReason = reason
        }
    }

    private func teardown() {
        activeConnectionID = nil
        let oldClient = client
        client = nil
        oldClient?.close()
        let oldInjectClient = injectClient
        injectClient = nil
        oldInjectClient?.close()
        displayLayer = nil
        renderer = nil
        streamSize = .zero
        serverAck = nil
        windowInventory = []
        mouseAvailability = .unknown
        keyboardShortcutsAvailability = .unknown
        textInputAvailable = false
        virtualCursorInitialized = false
        lastDesktopPointer = nil
        if case .disconnected = state {
            return
        }
        state = .disconnected(nil)
    }

    // MARK: - Remote control (mouse/keyboard)

    func sendMouseMove(x: UInt16, y: UInt16) {
        lastDesktopPointer = (x, y)
        client?.sendMouseMove(x: x, y: y)
    }

    func sendMouseDown(button: MacNativeStreamProtocol.MouseButton, x: UInt16, y: UInt16) {
        lastDesktopPointer = (x, y)
        client?.sendMouseDown(button: button, x: x, y: y)
    }

    func sendMouseUp(button: MacNativeStreamProtocol.MouseButton, x: UInt16, y: UInt16) {
        lastDesktopPointer = (x, y)
        client?.sendMouseUp(button: button, x: x, y: y)
    }

    var canRightClickDesktop: Bool {
        touchMode == .relative || lastDesktopPointer != nil
    }

    func rightClickAtDesktopCursor() {
        if touchMode == .relative {
            clickAtVirtualCursor(button: .right)
        } else if let point = lastDesktopPointer {
            sendMouseDown(button: .right, x: point.x, y: point.y)
            sendMouseUp(button: .right, x: point.x, y: point.y)
        }
    }

    func sendScroll(x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16) {
        client?.sendScroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY)
    }

    func sendKeyDown(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        client?.sendKeyDown(keyCode: keyCode, modifiers: modifiers)
    }

    func sendKeyUp(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        client?.sendKeyUp(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: - Virtual cursor (relative/touchpad mode)

    /// Lazily initializes the virtual cursor to the center of the stream.
    private func ensureVirtualCursorInitialized() {
        guard !virtualCursorInitialized, streamSize.width > 0 else { return }
        virtualCursorX = UInt16(streamSize.width / 2)
        virtualCursorY = UInt16(streamSize.height / 2)
        virtualCursorInitialized = true
    }

    /// Absolute pointer motion without a button held (Bluetooth mouse / gaze
    /// hover) — keeps the virtual cursor in sync regardless of touch mode.
    func moveCursorAbsolute(x: UInt16, y: UInt16) {
        virtualCursorX = x
        virtualCursorY = y
        virtualCursorInitialized = true
        sendMouseMove(x: x, y: y)
    }

    func moveVirtualCursor(dx: CGFloat, dy: CGFloat) {
        ensureVirtualCursorInitialized()
        let newX = CGFloat(virtualCursorX) + dx
        let newY = CGFloat(virtualCursorY) + dy
        virtualCursorX = UInt16(clamping: Int(max(0, min(newX, streamSize.width - 1))))
        virtualCursorY = UInt16(clamping: Int(max(0, min(newY, streamSize.height - 1))))
        sendMouseMove(x: virtualCursorX, y: virtualCursorY)
    }

    func clickAtVirtualCursor(button: MacNativeStreamProtocol.MouseButton) {
        ensureVirtualCursorInitialized()
        sendMouseDown(button: button, x: virtualCursorX, y: virtualCursorY)
        sendMouseUp(button: button, x: virtualCursorX, y: virtualCursorY)
    }

    /// Presses and holds a button at the virtual cursor — pairs with a gaze
    /// drag lock; pair with `releaseMouseAtVirtualCursor`.
    func pressMouseAtVirtualCursor(button: MacNativeStreamProtocol.MouseButton) {
        ensureVirtualCursorInitialized()
        sendMouseDown(button: button, x: virtualCursorX, y: virtualCursorY)
    }

    func releaseMouseAtVirtualCursor(button: MacNativeStreamProtocol.MouseButton) {
        ensureVirtualCursorInitialized()
        sendMouseUp(button: button, x: virtualCursorX, y: virtualCursorY)
    }

    func scrollAtVirtualCursor(deltaX: Int16, deltaY: Int16) {
        ensureVirtualCursorInitialized()
        sendScroll(x: virtualCursorX, y: virtualCursorY, deltaX: deltaX, deltaY: deltaY)
    }

    private func handle(_ event: MacNativeStreamClient.Event, connectionID: UUID) {
        guard activeConnectionID == connectionID else { return }
        switch event {
        case .connected(let ack):
            serverAck = ack
            state = .connected
            if let ack {
                // v2 session: streams are subscription-based. Desktop rides
                // the Screen toggle; open per-window scenes resubscribe so a
                // reconnect resumes them.
                if liveEnabled {
                    client?.sendWindowStreamStart(
                        windowID: MacNativeStreamProtocol.desktopStreamID
                    )
                }
                if ack.supportsWindowStreams {
                    for (windowID, session) in windowSessions {
                        session.closedReason = nil
                        client?.setWindowRenderer(session.renderer, for: windowID)
                        client?.sendWindowStreamStart(windowID: windowID)
                    }
                } else {
                    markAllWindowSessionsClosed("This host doesn't support per-window streaming.")
                }
            } else {
                // v1 server: it pushes the desktop stream unconditionally and
                // knows nothing of window streams. If the Screen toggle is
                // off we only connected hoping for v2 — drop the session.
                markAllWindowSessionsClosed("This host doesn't support per-window streaming.")
                if !liveEnabled {
                    teardown()
                }
            }
        case .format(let size):
            streamSize = size
        case .firstFrame:
            state = .streaming
        case .mouseAvailability(let availability):
            mouseAvailability = Self.mapAvailability(availability)
        case .keyboardAvailability(let availability):
            keyboardShortcutsAvailability = Self.mapAvailability(availability)
        case .inventory(let windows):
            windowInventory = windows
            for session in windowSessions.values {
                if let info = windows.first(where: { $0.id == session.windowID }) {
                    session.info = info
                }
            }
        case .windowClosed(let windowID, let reason):
            windowSessions[windowID]?.closedReason = reason ?? "The window closed on the host."
        case .replaced(let deviceName):
            state = .disconnected("Replaced by \(deviceName).")
            activeConnectionID = nil
            client = nil
        case .closed(let message):
            if case .disconnected(let existing) = state, existing != nil {
                return
            }
            state = .disconnected(message)
            activeConnectionID = nil
            client = nil
        }
    }

    private static func mapAvailability(
        _ availability: MacNativeStreamClient.Event.RemoteControlAvailability
    ) -> RemoteControlAvailability {
        switch availability {
        case .available: .available
        case .disabled: .disabled
        case .accessibilityDenied: .accessibilityDenied
        }
    }
}
#endif
