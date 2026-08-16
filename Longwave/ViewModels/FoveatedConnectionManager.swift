//  FoveatedConnectionManager.swift
//
//  Thin @Observable wrapper around Apple's `FoveatedStreamingSession`
//  (visionOS 26.4+), the receiver for immersive PCVR content streamed from an
//  NVIDIA CloudXR host. Unlike the Moonlight manager, Apple owns the entire
//  media pipeline, so this is mostly lifecycle + endpoint mapping + app-state
//  glue, plus optionally driving the Switch Pro / hand-tracking controller
//  bridge while a session is live.
//
//  Gated behind FOVEATED_ENABLED. The whole feature requires the
//  `com.apple.developer.foveated-streaming-session` entitlement and a 26.4
//  deployment target — see CLAUDE.md and the PCVR design notes in
//  Longwave-PCVR-Host/docs/. On the
//  simulator the session is the in-module mock (FoveatedStreamingMock.swift);
//  on device it is the real framework type.

#if FOVEATED_ENABLED
import SwiftUI
import Network
import os

#if !targetEnvironment(simulator)
import FoveatedStreaming
#endif

@MainActor
@Observable
final class FoveatedConnectionManager {

    /// The single streaming session. The `ImmersiveSpace(foveatedStreaming:)`
    /// scene binds to this exact instance, so it lives for the app's lifetime.
    let session = FoveatedStreamingSession()

    /// Connection the user last asked to open; seeds the connect form on retry
    /// and supplies the controller-bridge host.
    var pendingConnection: SavedConnection?

    /// Surfaced in the control window when a connect attempt fails.
    var lastError: String?

    /// True when the last connect could not reach the PC's info endpoint and fell back to
    /// progressive. Worth surfacing: the fallback is indistinguishable from the PC actually
    /// wanting progressive, and a session that quietly opened in the wrong style with no
    /// explanation is how an evening gets lost.
    private(set) var immersionUnanswered = false

    /// Immersion style the immersive space runs in, bound by the scene in
    /// `LongwaveApp`.
    ///
    /// Not a preference, and deliberately not persisted. It is answered once per
    /// session, before connecting, by asking the PC (`FoveatedHostInfo`) — the PC
    /// decides whether an alpha channel is encoded at all, and `.mixed` is worth
    /// being in only when there is transparency to composite.
    ///
    /// Settled *before* the space exists because it cannot be settled after.
    /// Restyling a live space was tried and does not hold: the Digital Crown
    /// force-fades to zero, the space can end up in a style that disagrees with
    /// the binding, and a space that flips to mixed against a stream with no alpha
    /// shows the wearer a black void. It starts progressive and returns there when
    /// a session ends, so nothing carries over from the last PC.
    var immersionStyle: FoveatedImmersionStyle = .progressive

    /// The active controller bridge (Switch Pro + hand tracking → SteamVR),
    /// non-nil only while a session with the bridge enabled is connected.
    private(set) var controllerBridge: ControllerBridgeSender?

    /// The PC's curated game library, served over the bridge's data channel.
    /// Long-lived (a view can hold it across reconnects) but only populated while
    /// a bridge is attached — see `FoveatedGameLibrary.attach(to:)`.
    let gameLibrary = FoveatedGameLibrary()

    private var connectTask: Task<Void, Never>?
    private var channelMonitorTask: Task<Void, Never>?
    /// Outlives a session drop on purpose — see `startBridgeSupervisor`.
    private var bridgeSupervisorTask: Task<Void, Never>?
    private var pauseRequestInFlight = false
    private var disconnectInFlight = false
    private let log = Logger(subsystem: "pro.longwave", category: "Foveated")

    // MARK: Derived state

    var status: FoveatedStreamingSession.Status { session.status }

    var isDisconnected: Bool {
        switch session.status {
        case .disconnected, .initialized, .connecting: true
        default: false
        }
    }

    var isConnecting: Bool {
        if case .connecting = session.status { return true }
        return connectTask != nil
    }

    /// Actually streaming — not connecting, not paused, not on the way down.
    /// Narrower than `!isDisconnected`, and the distinction is the point for the
    /// trial clock: a paused session is not play, so it must not be charged for.
    /// Exposed as a plain Bool so callers need no import of the framework that
    /// defines `Status`.
    var isStreaming: Bool {
        if case .connected = session.status { return true }
        return false
    }

    /// True only in the states where the framework will accept `connect()`.
    /// Distinct from `isDisconnected`, which is a UI predicate and counts
    /// `.connecting` as "not up yet" — calling `connect()` in `.connecting` (or any
    /// other non-disconnected state) throws "Attempted to connect multiple times on
    /// the same streaming session", and a session that has taken that call can keep
    /// refusing every later attempt with ConfigurationError until the app restarts.
    private var canConnect: Bool {
        switch session.status {
        case .disconnected, .initialized: true
        default: false
        }
    }

    /// Wait (bounded) for the session to settle into a connectable state,
    /// nudging it with a `disconnect()` when it is stuck anywhere else. An
    /// unexpected drop tears the session down asynchronously, so "the UI says
    /// disconnected" and "the session accepts connect()" are separated by an
    /// unpredictable gap — this bridges it instead of racing it.
    private func settleForConnect(timeout: Duration = .seconds(8)) async {
        if canConnect { return }
        await session.disconnect()
        let deadline = ContinuousClock.now + timeout
        while !canConnect, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Lifecycle

    /// Begin connecting to a saved foveated connection. Stores it as pending,
    /// then drives `connect(endpoint:)` on a cancelable task. Errors land in
    /// `lastError`; the immersive space auto-opens via the presentation
    /// behaviors set by the control window.
    func beginConnect(_ connection: SavedConnection) {
        pendingConnection = connection
        lastError = nil
        connectTask?.cancel()
        connectTask = Task { @MainActor in
            defer { self.connectTask = nil }
            do {
                let endpoint = try Self.endpoint(for: connection)
                /* Before the session, never after: connecting is what creates the immersive
                   space, and the style it is created with is the only one it reliably
                   keeps. The fallback is progressive — the half that degrades gracefully —
                   but it is recorded rather than silent: an unanswered host and a host that
                   genuinely wants progressive look identical from inside the headset, and
                   the difference is exactly what someone debugging needs. */
                if let answered = await FoveatedHostInfo.immersionStyle(for: connection) {
                    self.immersionStyle = answered
                    self.immersionUnanswered = false
                } else {
                    self.immersionStyle = .progressive
                    self.immersionUnanswered = true
                    self.log.notice("No immersion answer from the PC; opening progressive.")
                }
                await self.settleForConnect()
                try Task.checkCancellation()
                try await self.session.connect(endpoint: endpoint)
                // A completed connect earns back the auto-reconnect budget.
                self.autoReconnectAttempts = 0
                self.startBridgeSupervisor(for: connection)
            } catch is CancellationError {
                // User cancelled — leave status to the session.
            } catch {
                // A failed connect must not leave a bridge behind: the next attempt would
                // start a second one, and the second one is the broken one.
                self.bridgeSupervisorTask?.cancel()
                self.bridgeSupervisorTask = nil
                self.stopControllerBridge()
                /* And it must not leave a session behind either. A connect that throws can
                   still have left the system's foveated service holding a half-open session,
                   and the next attempt is then refused with "the foveated streaming service
                   is currently unavailable. Another app on the system may be streaming
                   already" — the other app being us, one attempt ago. Retrying looks like the
                   obvious thing to do at that point, and each retry renews the problem. */
                await self.session.disconnect()
                self.lastError = error.localizedDescription
                self.log.error("Foveated connect failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Cancel an in-flight connect attempt.
    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        isAutoReconnecting = false
    }

    // MARK: Session recovery

    /// How many drops in a row are retried without asking. One: each session start
    /// raises visionOS's own per-session consent prompt (a property of the
    /// FoveatedStreaming framework, not something to engineer around), so anything
    /// beyond a single quiet retry turns a flaky network into a prompt storm.
    private static let maxAutoReconnects = 1
    private var autoReconnectAttempts = 0
    private var autoReconnectTask: Task<Void, Never>?
    /// True while a scheduled automatic reconnect is pending, so the UI can say
    /// "reconnecting…" instead of raising the disconnect alert.
    private(set) var isAutoReconnecting = false

    /// Re-run the last requested connection (the alert's Reconnect button).
    func retryLastConnection() {
        guard let pending = pendingConnection else { return }
        beginConnect(pending)
    }

    /// Called when the session drops without the user asking for it. Returns true
    /// when an automatic reconnect has been scheduled — Wi-Fi blips are routine on
    /// the networks this has to work on, and the first response to one should not
    /// be a modal.
    func handleUnexpectedDisconnect() -> Bool {
        guard pendingConnection != nil,
              autoReconnectAttempts < Self.maxAutoReconnects else { return false }
        autoReconnectAttempts += 1
        isAutoReconnecting = true
        autoReconnectTask?.cancel()
        autoReconnectTask = Task { @MainActor [weak self] in
            // A beat of settling time: the host tears its side down asynchronously,
            // and reconnecting into a half-closed session is how "another app may be
            // streaming already" happens.
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.isAutoReconnecting = false
            guard self.isDisconnected else { return }
            self.log.notice("Attempting automatic reconnect after an unexpected drop.")
            self.retryLastConnection()
        }
        return true
    }

    func pause() async {
        guard !pauseRequestInFlight, !disconnectInFlight else { return }
        guard case .connected = session.status else { return }
        pauseRequestInFlight = true
        defer { pauseRequestInFlight = false }
        do {
            try await session.pause()
        } catch {
            log.error("Foveated pause failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resume() async {
        guard !pauseRequestInFlight, !disconnectInFlight else { return }
        guard case .paused = session.status else { return }
        do {
            try await session.resume()
        } catch {
            log.error("Foveated resume failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnect() async {
        guard !disconnectInFlight else { return }
        disconnectInFlight = true
        defer { disconnectInFlight = false }
        cancelConnect()   // also cancels any pending auto-reconnect
        // Before the teardown, or the supervisor would helpfully start a replacement.
        bridgeSupervisorTask?.cancel()
        bridgeSupervisorTask = nil
        stopControllerBridge()
        await session.disconnect()
    }

    /// The immersive space can disappear independently of the framework session when the user
    /// leaves it through visionOS. Pause the remote stream so the PC does not keep rendering and
    /// encoding an invisible session. A framework-driven disappearance caused by Pause or
    /// Disconnect is already represented by its transitional state/in-flight flag and is ignored.
    func pauseForImmersiveExit() async {
        guard !pauseRequestInFlight, !disconnectInFlight else { return }
        guard case .connected = session.status else { return }
        log.notice("Immersive space disappeared while connected; pausing the PCVR session.")
        await pause()
    }

    // MARK: Immersive presentation

    /// Wire the session to auto-open/close the immersive space on connect/pause.
    /// Called from the control window's `.task` (the SwiftUI environment actions
    /// are only available inside a view).
    func setImmersivePresentationBehaviors(open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) {
        session.immersivePresentationBehaviors = .automatic(open, dismiss)
    }

    // MARK: Endpoint mapping

    enum FoveatedError: LocalizedError {
        case invalidLocalEndpoint

        var errorDescription: String? {
            switch self {
            case .invalidLocalEndpoint: "Enter a valid IP address and port."
            }
        }
    }

    static func endpoint(for connection: SavedConnection) throws -> FoveatedStreamingSession.Endpoint {
        switch connection.foveatedConnectionMode {
        case .systemDiscovered:
            return .systemDiscovered
        case .local:
            guard let ip = IPv4Address(connection.hostname.trimmingCharacters(in: .whitespaces)),
                  connection.port > 0, connection.port <= 65_535,
                  let port = NWEndpoint.Port(rawValue: UInt16(connection.port)) else {
                throw FoveatedError.invalidLocalEndpoint
            }
            return .local(ipAddress: ip, port: port)
        }
    }

    // MARK: Controller bridge

    /// Owns the bridge for as long as the session lasts: starts one when the session is up
    /// and there is none, stops it when the session drops, and starts a fresh one when the
    /// session comes back.
    ///
    /// That last part is the whole reason this exists separately from the channel monitor.
    /// The monitor used to handle the drop itself and then return, which is correct exactly
    /// once — a session that re-attaches on its own (the host logs "headset attached")
    /// never got its bridge back, so input stopped permanently and silently while the
    /// stream itself carried on looking fine. Restarting is safe because starting is
    /// idempotent; only this task is allowed to outlive a drop.
    private func startBridgeSupervisor(for connection: SavedConnection) {
        guard connection.controllerBridgeEnabled else { return }
        bridgeSupervisorTask?.cancel()
        bridgeSupervisorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                /* Positive test: the bridge runs while the session is *up*, not merely while
                   it is "not disconnected". `.connecting` and `.initialized` are both
                   not-disconnected, so the first version opened UDP ports and a channel
                   monitor during a connect attempt — and then tore them down when the attempt
                   failed, adding port churn to the least stable moment in the session's life. */
                if self.isDisconnected {
                    if self.controllerBridge != nil {
                        self.log.notice("Session is not up — stopping the controller bridge until it returns.")
                        self.stopControllerBridge()
                    }
                } else if self.controllerBridge == nil {
                    self.startControllerBridgeIfNeeded(for: connection)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func startControllerBridgeIfNeeded(for connection: SavedConnection) {
        guard connection.controllerBridgeEnabled else { return }
        /* Idempotent, because it was not and the consequence was severe. Overwriting
           `controllerBridge` dropped our reference to the previous sender without stopping
           it, and a sender is kept alive by its own listener and send loop — so it went on
           holding the ports. The next one could not have them, and Network.framework reports
           that as "Cannot allocate memory", which reads like the device being out of
           resources rather than like us running two of something. Symptom on device: the
           game library reported the PC unreachable and the host looked disconnected. */
        stopControllerBridge()
        // The preferred transport is the session's message channel (the host
        // OpenXR layer's opaque data channel) — it needs no host IP, so the
        // bridge also works for system-discovered sessions. A configured host
        // additionally enables the UDP fallback (SteamVR-driver path).
        let host = connection.hostname.trimmingCharacters(in: .whitespaces)
        let bridge = ControllerBridgeSender(host: host)
        /* Reported, not acted on. Immersion is settled before the session starts (see
           `beginConnect`), because restyling a live space does not work — this arrives
           long after the space exists, and using it to switch was what produced the
           crown force-fading to zero and sessions opening mixed against a stream with no
           alpha. It stays because it is the strongest statement of what the host is
           actually doing: the blend mode the runtime *accepted*, where the pre-connect
           answer is only what the PC intended. A disagreement is worth showing. */
        bridge.onAlphaBlendChanged = { [weak self] alpha in
            self?.log.notice("Host reports alpha blend \(alpha ? "on" : "off", privacy: .public); session opened in \(self?.immersionStyle.rawValue ?? "?", privacy: .public).")
        }
        bridge.start()
        controllerBridge = bridge
        gameLibrary.attach(to: bridge)
        startChannelMonitor(for: bridge)
        log.notice("Controller bridge started (UDP host: \(host.isEmpty ? "none — channel only" : host, privacy: .public))")
    }

    /// Watch the session for the bridge message channel and hand it to the
    /// sender. `MessageChannel.ID` is opaque (constructible from a UUID but not
    /// readable back), so we match by constructing the expected ID. The host-GUID
    /// → client-UUID byte-order mapping was captured on real hardware (Quest 3,
    /// 2026-07-03), so the old accept-any-lone-channel fallback is retired: it
    /// could attach a foreign app's channel and feed its bytes to the rendezvous
    /// parser.
    private func startChannelMonitor(for bridge: ControllerBridgeSender) {
        channelMonitorTask?.cancel()
        channelMonitorTask = Task { @MainActor [weak self] in
            let target = FoveatedStreamingSession.MessageChannel.ID(ControllerBridgeProtocol.channelUUID)
            var attached = false
            var loggedUnmatched = false
            while !Task.isCancelled {
                /* Only attaches and re-attaches the channel. The session's own lifecycle —
                   including a drop, and the restart after it — belongs to
                   startBridgeSupervisor; a pause is deliberately not a drop. */
                guard let self, self.controllerBridge === bridge else { return }
                let ids = self.session.availableMessageChannels
                let match = ids.contains(target) ? target : nil
                if match == nil, !ids.isEmpty, !loggedUnmatched {
                    loggedUnmatched = true
                    self.log.notice("Message channels present but none match the bridge UUID (\(ids.count, privacy: .public) channel(s)); not attaching.")
                }

                if let match, let channel = self.session.messageChannel(for: match) {
                    if !attached {
                        bridge.attach(channel: channel)
                        attached = true
                    }
                } else if attached {
                    // The channel went away mid-session. This monitor used to return
                    // after the first attach, which left the bridge holding a dead
                    // channel for the rest of the session: input stopped and the game
                    // library reported the PC unreachable with no way back short of
                    // reconnecting. The host recreates its channel after a drop
                    // (data_channel.cpp), so the client has to keep watching for the
                    // replacement.
                    self.log.notice("Bridge message channel dropped; waiting for the host to recreate it.")
                    bridge.detachChannel()
                    attached = false
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopControllerBridge() {
        channelMonitorTask?.cancel()
        channelMonitorTask = nil
        gameLibrary.detach()
        controllerBridge?.stop()
        controllerBridge = nil
        // Nothing is reporting alpha any more, so stop claiming there is any. The
        // bridge is the only source of that fact, and a stale `.mixed` would open
        // the next session showing passthrough around a PC that is not sending
        // transparency.
        immersionStyle = .progressive
    }
}
#endif
