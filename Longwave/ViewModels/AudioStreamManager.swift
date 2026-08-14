import Foundation
import os
import Network
import AVFoundation
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import MediaPlayer

/// How the receiver coexists with the rest of the system.
/// - `.speaker` (default): a **mixable** session (`.mixWithOthers`) that plays
///   alongside everything else and silently auto-recovers when another app
///   (e.g. a VoIP call) grabs the audio config. No Control Center integration.
/// - `.music`: an **exclusive** session that takes audio focus, surfaces in
///   Now Playing / Control Center (transport maps to the Mac's Music.app), and
///   on interruption pauses the Mac source instead of fighting to stay alive.
enum AudioMode: String, Sendable, CaseIterable {
    case speaker, music
}

/// How the stream's session declares its spatial experience.
/// - `.auto`: never calls `setIntendedSpatialExperience` — the session is left
///   at whatever the system's own default resolves to for this app/route.
/// - `.on`: explicit head-tracked spatial rendering.
/// - `.off`: explicit flat bypass (stereo/multichannel passthrough).
enum SpatialAudioMode: String, Sendable, CaseIterable {
    case auto, on, off

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    #if canImport(UIKit)
    /// `nil` for `.auto` — the caller should skip the `setIntendedSpatialExperience`
    /// call entirely rather than pass this through, since there's no "system
    /// default" case in that API.
    var avSpatialExperience: (any AVAudioSessionSpatialExperience)? {
        switch self {
        case .auto: return nil
        case .on: return .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic)
        case .off: return .bypassed
        }
    }
    #endif
}

/// Receives an uncompressed PCM audio stream from the Longwave Companion
/// Mac menu bar app and plays it through AVAudioEngine.
///
/// The stream arrives as an already-mixed stereo/multichannel signal, so
/// spatializing it is a user choice rather than automatic — `spatialAudioMode`
/// (mini-player button, defaulting from Settings) switches the session
/// between head-tracked spatial rendering, flat bypass, and the system
/// default, applied live with no reconnect needed.
@Observable
final class AudioStreamManager {

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case streaming
        case error(String)
    }

    var state: ConnectionState = .idle
    var connectionTitle: String = ""

    /// Player mode (Speaker vs Music). Persisted. Changing it mid-stream
    /// rebuilds the receiver (the session config differs) and re-syncs the
    /// Now Playing / Control Center integration.
    var audioMode: AudioMode = AudioMode(rawValue: UserDefaults.standard.string(forKey: "audioMode") ?? "") ?? .speaker {
        didSet {
            guard audioMode != oldValue else { return }
            UserDefaults.standard.set(audioMode.rawValue, forKey: "audioMode")
            if state == .streaming || state == .connecting {
                reconnectLast() // rebuild with the new session category
            }
            refreshNowPlayingIntegration()
        }
    }

    /// Flips between the two modes (mini-player button).
    func toggleAudioMode() {
        audioMode = (audioMode == .music) ? .speaker : .music
    }

    /// Whether decoded audio is spatialized (head-tracked) at the session
    /// level, bypassed (flat stereo/multichannel passthrough), or left on the
    /// system's own default (the stream already arrives pre-mixed from the
    /// Mac, so spatializing it is a user choice, not automatic). Seeded from
    /// the Settings default the first time this launches; once the user
    /// touches the mini-player button that explicit choice is persisted and
    /// takes over. Applied live to the running session, no rebuild needed.
    var spatialAudioMode: SpatialAudioMode = SpatialAudioMode(
        rawValue: UserDefaults.standard.string(forKey: "spatialAudioMode") ?? ""
    ) ?? ConnectionDefaults.spatialAudioMode {
        didSet {
            guard spatialAudioMode != oldValue else { return }
            UserDefaults.standard.set(spatialAudioMode.rawValue, forKey: "spatialAudioMode")
            receiver?.setSpatialAudioMode(spatialAudioMode)
        }
    }

    /// Flips between explicit on/off (mini-player button) — jumps out of
    /// `.auto` the first time it's pressed.
    func toggleSpatialAudio() {
        spatialAudioMode = (spatialAudioMode == .on) ? .off : .on
    }

    /// Whether Control Center remote-command targets have been installed yet
    /// (added once, then just enabled/disabled per mode).
    private var remoteCommandsConfigured = false

    /// Now-playing state mirrored from the Mac's Music.app (nil when
    /// nothing is playing or Music is closed).
    var nowPlaying: NowPlayingInfo?
    var artworkImage: PlatformImage?
    /// Local mute, derived from `volume`: true while the slider is at 0.
    /// Dropping the stream's audio on this end (no disconnect, no effect on
    /// Mac playback) is driven by the volume setter — there is no separate
    /// mute control.
    private(set) var isMuted = false

    /// Local output volume (0…1), applied to the player node on this end
    /// only. Persisted so it carries across reconnects and relaunches. At 0
    /// it engages the internal mute (drops incoming PCM so no backlog builds
    /// while silenced); any positive value resumes playback and applies the
    /// gain. The slider *is* the mute.
    var volume: Double = UserDefaults.standard.object(forKey: "audioVolume") as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "audioVolume")
            let muted = volume <= 0
            if muted != isMuted {
                isMuted = muted
                receiver?.setPaused(muted)
            }
            if !muted {
                receiver?.setVolume(Float(volume))
            }
        }
    }

    /// Receiver-side EQ (global, like `volume`/`audioMode`). Persisted as
    /// a JSON blob; every edit (including per-tick drag updates from the
    /// editor) is pushed to the live engine — AVAudioUnitEQ parameters are
    /// settable while running, no rebuild needed. While Auto preamp is on,
    /// the preamp is recomputed on every band change (and when the toggle
    /// turns on) so a boosted curve never plays louder than flat
    /// (re-assignment inside didSet doesn't re-trigger the observer).
    var eqSettings: EQSettings = .load() {
        didSet {
            guard eqSettings != oldValue else { return }
            if eqSettings.autoPreamp,
               eqSettings.bands != oldValue.bands || !oldValue.autoPreamp {
                eqSettings.autoTrimPreamp()
            }
            eqSettings.save()
            receiver?.setEQ(eqSettings)
        }
    }
    var sampleRate: Double = 0
    var channelCount: Int = 0
    var bytesReceived: Int = 0

    /// True while non-silent PCM is actually arriving (the sender suppresses
    /// silent audio, so a frame == real sound). Drives the animated speaker
    /// glyph: it pulses only when sound is genuinely playing, and goes still
    /// during silence (e.g. Music paused while another app plays) — in either
    /// mode. Flipped off by a watchdog when the activity pings stop.
    private(set) var isReceivingAudio = false
    private var audioActivityToken = 0

    /// Low-latency (UDP) mode was requested for the current connection.
    private(set) var lowLatencyRequested = false
    /// PCM is actually flowing over the UDP path.
    private(set) var lowLatencyActive = false
    /// Low-latency was requested but UDP couldn't deliver, so the session
    /// fell back to TCP. Sticky for the session — surfaced in the UI.
    private(set) var lowLatencyDegraded = false

    /// One-line transport summary for the UI.
    var transportLabel: String {
        if lowLatencyActive { return "UDP · low-latency" }
        if lowLatencyDegraded { return "TCP · low-latency unavailable" }
        if lowLatencyRequested { return "TCP · negotiating low-latency…" }
        return "TCP"
    }

    var formatLabel: String {
        guard sampleRate > 0 else { return "—" }
        let channels = channelCount == 1 ? "Mono" : channelCount == 2 ? "Stereo" : "\(channelCount)ch"
        return "\(channels) · \(Int(sampleRate)) Hz · int24 PCM"
    }

    private var receiver: AudioStreamReceiver?

    /// Deferred health re-check used in Music mode (see `ensureConnected`).
    private var healthRecheckTask: Task<Void, Never>?

    /// Last event (connect or data) timestamp — drives the health probe
    /// used to detect a silently dead TCP connection after the app was
    /// suspended (visionOS space restore / scenePhase flips).
    private var lastActivityAt: Date?
    private var pendingCloseTask: Task<Void, Never>?
    /// Artwork bytes waiting for the matching nowPlaying frame's artworkID.
    private var pendingArtwork: Data?

    /// Auto-reconnect after unexpected drops. On a space-restoration
    /// relaunch the first attempt typically fails (the network stack isn't
    /// ready that early), so a single try isn't enough — retry with backoff
    /// until the stream is up, the user disconnects, or the window closes.
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 2
    private var lastReloadAt: Date?
    private static let maxRetryDelay: TimeInterval = 30

    /// Token delivered via an AirDropped x-callback URL, waiting to be
    /// consumed by an open (or freshly opened) connection form. Set by the
    /// app's onOpenURL handler; cleared once a form fills its field.
    var pendingImportedToken: String?

    /// Records a token imported from a `longwave://…/setAudioToken` URL so
    /// the connection form can auto-fill it.
    func importToken(_ token: String) {
        pendingImportedToken = token
    }

    private enum DefaultsKeys {
        static let host = "lastAudioHost"
        static let port = "lastAudioPort"
        static let title = "lastAudioTitle"
        static let token = "lastAudioToken"
        static let lowLatency = "lastAudioLowLatency"
        static let liveEnabled = "nativeAudioLiveEnabled"
    }

    /// The Native window's live Audio toggle, persisted separately from
    /// `state`: a transient drop or a deliberate toggle-off both leave
    /// `state` idle, but only this flag says whether Audio should resume
    /// after a scene reactivation or a full space-restoration relaunch (a
    /// fresh `AudioStreamManager` with no in-memory state).
    var liveEnabled: Bool = UserDefaults.standard.bool(forKey: AudioStreamManager.DefaultsKeys.liveEnabled) {
        didSet {
            guard liveEnabled != oldValue else { return }
            UserDefaults.standard.set(liveEnabled, forKey: DefaultsKeys.liveEnabled)
        }
    }

    /// Forces TCP for the *next* reconnect without overwriting the user's
    /// saved low-latency preference — set when the UDP path fails to deliver
    /// (one-way block), cleared on the next explicit `connect(...)`.
    private var lowLatencyOverride: Bool?

    /// True while streaming and data has arrived recently. The receiver
    /// reports byte counts every ~0.5 s, so a few seconds of silence means
    /// the connection is dead even if no error has surfaced yet.
    var isHealthy: Bool {
        guard state == .streaming, let lastActivityAt else { return false }
        return Date().timeIntervalSince(lastActivityAt) < 2.5
    }

    /// True once toggled on, even mid-connect or after a drop — mirrors user
    /// intent rather than the transient handshake state, so the Audio toggle
    /// in the Native window doesn't flip itself off on a hiccup.
    var isEnabled: Bool { state != .idle }

    /// Remembers a target (same bookkeeping `connect(...)` does) without
    /// starting the receiver — used when opening the Native window with
    /// Audio initially off, so `reconnectLast()` has something to start
    /// once the live toggle turns it on.
    func prepareTarget(hostname: String, port: UInt16, token: String, title: String, lowLatency: Bool) {
        rememberTarget(hostname: hostname, port: port, token: token, title: title, lowLatency: lowLatency)
    }

    private func rememberTarget(hostname: String, port: UInt16, token: String, title: String, lowLatency: Bool) {
        // Remember the target so the stream can resume after the app is
        // relaunched by visionOS space restoration of a snapped window.
        let defaults = UserDefaults.standard
        defaults.set(hostname, forKey: DefaultsKeys.host)
        defaults.set(Int(port), forKey: DefaultsKeys.port)
        defaults.set(title, forKey: DefaultsKeys.title)
        defaults.set(token, forKey: DefaultsKeys.token)
        defaults.set(lowLatency, forKey: DefaultsKeys.lowLatency)
    }

    func connect(hostname: String, port: UInt16, token: String, title: String, lowLatency: Bool = false) {
        disconnect()
        lowLatencyOverride = nil
        connectionTitle = title
        state = .connecting
        bytesReceived = 0
        sampleRate = 0
        channelCount = 0
        isReceivingAudio = false
        lastActivityAt = nil
        nowPlaying = nil
        artworkImage = nil
        pendingArtwork = nil
        isMuted = volume <= 0
        lowLatencyRequested = lowLatency
        lowLatencyActive = false
        // Reset the sticky degraded flag only on a genuine low-latency
        // attempt — not on the automatic TCP fallback reconnect, which must
        // preserve the warning for the UI.
        if lowLatency { lowLatencyDegraded = false }

        rememberTarget(hostname: hostname, port: port, token: token, title: title, lowLatency: lowLatency)

        let receiver = AudioStreamReceiver(hostname: hostname, port: port, token: token, lowLatency: lowLatency, volume: Float(volume), mode: audioMode, eq: eqSettings, spatialAudioMode: spatialAudioMode)
        receiver.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        self.receiver = receiver
        if isMuted { receiver.setPaused(true) } // started with the slider at 0
        receiver.start()
    }

    func disconnect() {
        pendingCloseTask?.cancel()
        pendingCloseTask = nil
        retryTask?.cancel()
        retryTask = nil
        healthRecheckTask?.cancel()
        healthRecheckTask = nil
        receiver?.stop()
        receiver = nil
        state = .idle
        isReceivingAudio = false
        clearNowPlayingIntegration()
    }

    /// Explicit user disconnect: also forget the last connection so the
    /// stream doesn't auto-resurrect on the next window restore.
    func userDisconnect() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKeys.host)
        defaults.removeObject(forKey: DefaultsKeys.port)
        defaults.removeObject(forKey: DefaultsKeys.title)
        defaults.removeObject(forKey: DefaultsKeys.token)
        defaults.removeObject(forKey: DefaultsKeys.lowLatency)
        liveEnabled = false
        disconnect()
    }

    /// Reconnects to the last-used sender, if one is remembered.
    func reconnectLast() {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: DefaultsKeys.host),
              let port = UInt16(exactly: defaults.integer(forKey: DefaultsKeys.port)),
              port > 0 else { return }
        // A pending fallback override (UDP failed) forces TCP for this
        // reconnect without disturbing the saved preference.
        let lowLatency = lowLatencyOverride ?? defaults.bool(forKey: DefaultsKeys.lowLatency)
        connect(
            hostname: host,
            port: port,
            token: defaults.string(forKey: DefaultsKeys.token) ?? "",
            title: defaults.string(forKey: DefaultsKeys.title) ?? "",
            lowLatency: lowLatency
        )
    }

    /// Called when the audio window (re)appears or its scene becomes
    /// active: cancels any pending close-grace disconnect and rebuilds the
    /// connection if it is idle, errored, or silently dead.
    func ensureConnected() {
        pendingCloseTask?.cancel()
        pendingCloseTask = nil
        switch state {
        case .connecting:
            break
        case .idle, .error:
            reconnectLast()
        case .streaming:
            guard !isHealthy else {
                healthRecheckTask?.cancel()
                healthRecheckTask = nil
                break
            }
            // Stale health on scene restore. In Speaker mode a reconnect is
            // harmless (mixable session), so recover immediately. In Music
            // mode a reconnect rebuilds the receiver and re-asserts the
            // *exclusive* audio session — which interrupts whatever else the
            // device is playing (e.g. a YouTube video). Since the sender now
            // heartbeats during silence, a live-but-quiet connection refreshes
            // its health within ~0.5 s of resume; give it a grace window to
            // prove it, and only reconnect if it stays silent (truly dead).
            if audioMode == .speaker {
                AppLog.audioStream.line("Connection unhealthy after scene activation — reconnecting")
                reconnectLast()
            } else {
                scheduleMusicHealthRecheck()
            }
        }
    }

    /// Music mode: wait for the sender's keepalive heartbeat to prove the
    /// existing connection survived suspension before resorting to a
    /// reconnect (which would interrupt other device audio). No-op if the
    /// connection reports healthy by the time the grace window elapses.
    private func scheduleMusicHealthRecheck() {
        guard healthRecheckTask == nil else { return }
        AppLog.audioStream.line("Music mode: connection stale on restore — waiting for keepalive before reconnecting")
        healthRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.healthRecheckTask = nil
            guard self.state == .streaming else { return }
            if self.isHealthy {
                AppLog.audioStream.line("Music mode: keepalive arrived — connection alive, not reconnecting")
            } else {
                AppLog.audioStream.line("Music mode: still no data after grace — reconnecting")
                self.reconnectLast()
            }
        }
    }

    /// Called from the window's onDisappear. visionOS also fires this on
    /// transient hides (space restore, snapping), so tear down only after a
    /// grace period — `ensureConnected()` cancels it if the window returns.
    func windowDisappeared() {
        pendingCloseTask?.cancel()
        pendingCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.disconnect()
        }
    }

    /// Sends a media transport command to control Music.app on the Mac.
    func sendCommand(_ command: MediaCommand) {
        receiver?.send(command)
    }

    private func handle(_ event: AudioStreamReceiver.Event) {
        switch event {
        case .connected(let rate, let channels):
            sampleRate = rate
            channelCount = channels
            state = .streaming
            lastActivityAt = Date()
            retryDelay = 2
            refreshNowPlayingIntegration()
            AppLog.audioStream.line("Connected: \(channels)ch @ \(Int(rate)) Hz")
        case .bytesReceived(let total):
            bytesReceived = total
            lastActivityAt = Date()
        case .audioActivity:
            // A non-silent PCM frame arrived. Light the animated glyph and
            // arm a watchdog to dim it once the pings stop (silence). Each
            // ping supersedes the previous watchdog via the token.
            lastActivityAt = Date()
            if !isReceivingAudio { isReceivingAudio = true }
            audioActivityToken &+= 1
            let token = audioActivityToken
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, self.audioActivityToken == token else { return }
                self.isReceivingAudio = false
            }
        case .nowPlaying(let info):
            nowPlaying = info.hasTrack ? info : nil
            if info.artworkID == nil {
                artworkImage = nil
            } else if let pendingArtwork {
                artworkImage = PlatformImage(data: pendingArtwork)
            } // same artworkID as before and no new artwork frame: keep current image
            pendingArtwork = nil
            if audioMode == .music { updateNowPlayingInfo() }
        case .artwork(let data):
            pendingArtwork = data
        case .reloadRequested(let reason):
            // Audio config shifted under us (VoIP call grabbing the session,
            // route change). Reload immediately — same as the manual reload
            // button — instead of the backoff retry path: a fresh receiver
            // re-asserts setCategory/setActive and restores routing.
            guard receiver != nil else { return }
            receiver = nil
            // If the system re-interrupts straight after a reload, don't
            // hot-loop — fall back to the backoff retry path.
            if let lastReloadAt, Date().timeIntervalSince(lastReloadAt) < 2 {
                AppLog.audioStream.line("Reload requested again too soon (\(reason)) — backing off")
                state = .idle
                scheduleRetry()
                return
            }
            lastReloadAt = Date()
            AppLog.audioStream.line("Reloading stream: \(reason)")
            reconnectLast()
        case .authFailed(let reason):
            guard receiver != nil else { return }
            receiver = nil
            nowPlaying = nil
            artworkImage = nil
            pendingArtwork = nil
            // Terminal: don't schedule a retry — the same token would just
            // be rejected again. The user must fix the token and reconnect.
            retryTask?.cancel()
            retryTask = nil
            state = .error(reason)
            AppLog.audioStream.line("Authentication failed: \(reason)")
        case .lowLatencyEngaged:
            lowLatencyActive = true
            lowLatencyDegraded = false
            AppLog.audioStream.line("Low-latency UDP engaged")
        case .lowLatencyUnavailable:
            // UDP couldn't deliver — reconnect once over plain TCP. Keep the
            // saved preference intact (override only this session) so it
            // retries low-latency next time the user connects fresh.
            guard receiver != nil else { return }
            receiver = nil
            lowLatencyActive = false
            lowLatencyDegraded = true
            lowLatencyOverride = false
            AppLog.audioStream.line("Low-latency UDP unavailable — reconnecting over TCP")
            reconnectLast()
        case .disconnected(let reason):
            // Ignore events from a receiver we already tore down
            guard receiver != nil else { return }
            receiver = nil
            nowPlaying = nil
            artworkImage = nil
            pendingArtwork = nil
            if let reason {
                state = .error(reason)
                AppLog.audioStream.line("Disconnected: \(reason)")
            } else {
                state = .idle
                AppLog.audioStream.line("Disconnected: sender closed the stream")
            }
            scheduleRetry()
        }
    }

    /// Retries the last connection after an unexpected drop, with capped
    /// exponential backoff. Cancelled by disconnect()/userDisconnect()
    /// (and therefore by the window-close grace teardown).
    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        AppLog.audioStream.line("Reconnecting in \(Int(delay)) s")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnectLast()
        }
    }

    // MARK: - Now Playing / Control Center (Music Mode)

    /// Aligns the Now Playing / Control Center integration with the current
    /// mode: Music Mode enables the remote commands and populates the info
    /// center; Speaker Mode tears it down (a mixable session is ineligible for
    /// Now Playing anyway — see the audio-session notes in CLAUDE.md).
    private func refreshNowPlayingIntegration() {
        if audioMode == .music, state == .streaming {
            configureRemoteCommands()
            setRemoteCommandsEnabled(true)
            updateNowPlayingInfo()
        } else {
            setRemoteCommandsEnabled(false)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func clearNowPlayingIntegration() {
        setRemoteCommandsEnabled(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Installs the Control Center transport handlers once; each maps to a
    /// MediaCommand sent to the Mac's Music.app over the stream.
    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.sendCommand(.play); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.sendCommand(.pause); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.sendCommand(.toggle); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.sendCommand(.next); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.sendCommand(.previous); return .success }
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        guard remoteCommandsConfigured else { return }
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.isEnabled = enabled
        }
    }

    /// Pushes the current track metadata into the system Now Playing info
    /// center (Music Mode only) so it surfaces in Control Center.
    private func updateNowPlayingInfo() {
        guard audioMode == .music else { return }
        var info: [String: Any] = [:]
        if let np = nowPlaying {
            if let title = np.title { info[MPMediaItemPropertyTitle] = title }
            if let artist = np.artist { info[MPMediaItemPropertyArtist] = artist }
            if let album = np.album { info[MPMediaItemPropertyAlbumTitle] = album }
            if let duration = np.durationSeconds { info[MPMediaItemPropertyPlaybackDuration] = duration }
            if let elapsed = np.elapsedSeconds { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
            info[MPNowPlayingInfoPropertyPlaybackRate] = np.isPlaying ? 1.0 : 0.0
            if let image = artworkImage {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = (nowPlaying?.isPlaying == true) ? .playing : .paused
    }
}

/// Network + audio pipeline. All work happens on its serial queue and the
/// NWConnection callback queue — off the main actor, same pattern as
/// MoonlightAudioRenderer. Events are marshalled back via `onEvent`.
final class AudioStreamReceiver: @unchecked Sendable {

    enum Event: Sendable {
        case connected(sampleRate: Double, channels: Int)
        case bytesReceived(Int)
        /// A non-silent PCM frame was just scheduled (throttled to ~5/s).
        /// Drives the "audio active" UI; absent during silence.
        case audioActivity
        case nowPlaying(NowPlayingInfo)
        case artwork(Data)
        /// The audio session/config was lost (VoIP interruption, reroute);
        /// the manager should immediately rebuild via a fresh receiver.
        case reloadRequested(String)
        /// The sender rejected our token. Terminal — auto-retry with the
        /// same token would just loop, so the manager surfaces it and stops.
        case authFailed(String)
        /// First PCM datagram arrived over the low-latency UDP path.
        case lowLatencyEngaged
        /// Low-latency UDP was requested but no PCM arrived over it (one-way
        /// block / firewall). The manager reconnects once over plain TCP
        /// without disturbing the saved preference.
        case lowLatencyUnavailable
        case disconnected(String?)
    }

    nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?

    private let hostname: String
    private let port: UInt16
    private let token: String
    /// When true, PCM is carried over a parallel UDP socket with a smaller
    /// jitter buffer; the TCP connection still handles auth/header/metadata.
    private let lowLatency: Bool
    /// Speaker (mixable, auto-recover) vs Music (exclusive, pause-on-interrupt).
    private let mode: AudioMode
    private let queue = DispatchQueue(label: "pro.longwave.audio-stream", qos: .userInteractive)

    private nonisolated(unsafe) var connection: NWConnection?
    /// Low-latency PCM path. The receiver *listens* on an ephemeral UDP port
    /// (advertised to the sender via a `udpHello` over TCP); the sender
    /// connects out and pushes `pcm` frames (one per datagram). Listening,
    /// rather than connecting, avoids connected-UDP source-port filtering.
    private nonisolated(unsafe) var udpListener: NWListener?
    private nonisolated(unsafe) var udpConnection: NWConnection?
    /// Count of PCM datagrams received over UDP — gates the fallback timer.
    private nonisolated(unsafe) var udpFramesReceived = 0
    private nonisolated(unsafe) var pending = Data()
    private nonisolated(unsafe) var header: AudioStreamHeader?
    private nonisolated(unsafe) var stopped = false

    private nonisolated(unsafe) var audioEngine: AVAudioEngine?
    private nonisolated(unsafe) var playerNode: AVAudioPlayerNode?
    private nonisolated(unsafe) var audioFormat: AVAudioFormat?

    /// Frames scheduled before starting playback, to absorb network jitter.
    /// At a typical ~10 ms device IO cadence the standard buffer is ~40 ms;
    /// low-latency mode trades robustness for a ~20 ms buffer.
    private let prebufferFrameCount: Int
    private nonisolated(unsafe) var scheduledFrames = 0
    private nonisolated(unsafe) var totalBytes = 0
    /// Last `.audioActivity` emit (uptime ns), to throttle the ping to ~5/s.
    private nonisolated(unsafe) var lastAudioActivityNanos: UInt64 = 0
    /// Uptime (ns) of the last scheduled PCM buffer, to detect a silence gap
    /// (the sender suppresses silent PCM) and rebuild the jitter cushion on
    /// resume. 0 == no buffer scheduled yet.
    private nonisolated(unsafe) var lastScheduleNanos: UInt64 = 0
    /// While true, incoming PCM is dropped instead of scheduled (local
    /// pause); the connection keeps draining.
    private nonisolated(unsafe) var playbackPaused = false
    private nonisolated(unsafe) var droppedWhilePaused = 0
    private nonisolated(unsafe) var sessionConfigured = false
    private nonisolated(unsafe) var engineObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var sessionObservers: [any NSObjectProtocol] = []
    /// Output gain (0…1) applied to the player node; survives engine rebuilds.
    private nonisolated(unsafe) var volume: Float
    /// EQ configuration applied to `eqNode`; survives engine rebuilds.
    private nonisolated(unsafe) var eqSettings: EQSettings
    private nonisolated(unsafe) var eqNode: AVAudioUnitEQ?
    /// Head-tracked spatial rendering vs flat bypass vs system default;
    /// survives engine rebuilds and is re-applied to the session live via
    /// `setSpatialAudioMode`.
    private nonisolated(unsafe) var spatialAudioMode: SpatialAudioMode

    nonisolated init(hostname: String, port: UInt16, token: String, lowLatency: Bool = false, volume: Float = 1.0, mode: AudioMode = .speaker, eq: EQSettings = EQSettings(), spatialAudioMode: SpatialAudioMode = .auto) {
        self.hostname = hostname
        self.port = port
        self.token = token
        self.lowLatency = lowLatency
        self.mode = mode
        self.prebufferFrameCount = lowLatency ? 2 : 4
        self.volume = volume
        self.eqSettings = eq
        self.spatialAudioMode = spatialAudioMode
    }

    /// Adjusts output gain live (and for subsequent engine rebuilds).
    nonisolated func setVolume(_ newValue: Float) {
        queue.async { [self] in
            volume = newValue
            playerNode?.volume = newValue
        }
    }

    /// Applies new EQ settings live (and for subsequent engine rebuilds).
    nonisolated func setEQ(_ settings: EQSettings) {
        queue.async { [self] in
            eqSettings = settings
            if let eqNode { apply(settings, to: eqNode) }
        }
    }

    /// Switches the session between head-tracked spatial rendering, flat
    /// bypass, and the system default live — `setIntendedSpatialExperience`
    /// takes effect on an already-active session, so no engine/session
    /// rebuild is needed. `.auto` is a no-op here: there's no API to revert
    /// an already-explicit choice back to "system default" mid-session, so
    /// switching into `.auto` only has effect on the *next* fresh connect.
    nonisolated func setSpatialAudioMode(_ newMode: SpatialAudioMode) {
        queue.async { [self] in
            spatialAudioMode = newMode
            #if canImport(UIKit)
            guard let experience = newMode.avSpatialExperience else { return }
            do {
                try AVAudioSession.sharedInstance().setIntendedSpatialExperience(experience)
            } catch {
                AppLog.audioStream.line("Failed to update spatial audio experience: \(error)")
            }
            #endif
        }
    }

    nonisolated func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onEvent?(.disconnected("Invalid port \(port)"))
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(hostname),
            port: nwPort,
            using: AudioCrypto.tlsTCPParameters(token: token)
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // TLS-PSK handshake succeeded → token matched. The sender
                // sends the header next; just start draining.
                self.receiveLoop()
            case .waiting(let error):
                // The connection can't proceed yet (refused, unreachable, or
                // a TLS handshake stall) — NWConnection retries silently, so
                // surface the underlying error instead of hanging on
                // "Connecting…".
                AppLog.audioStream.line("⚠️ Connection waiting: \(error.localizedDescription)")
            case .failed(let error):
                // A TLS failure before the header almost always means the
                // PSK (token) didn't match — surface it as terminal so we
                // don't retry-loop with the same bad token.
                if case .tls = error, self.header == nil {
                    self.authFailed("Secure pairing failed — re-pair with a fresh token from the Mac.")
                } else {
                    self.fail("Connection failed: \(error.localizedDescription)")
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)

        // Any signal that the audio config has shifted (interruption,
        // engine config-change, silence-hint flip) triggers an immediate
        // stream reload via the manager (fresh receiver). Engine-only
        // rebuilds *don't* recover when visionOS reroutes us away for
        // another app's VoIP — only a fresh receiver with a re-asserted
        // setCategory/setActive does (confirmed via the manual reload
        // button). The crucial case is interruption *began*: the app
        // loses its audio session the moment GMeet starts, with no
        // matching route-change or ended event until the call finishes.
        // macOS has no AVAudioSession — audio plays through AVAudioEngine
        // directly, with no interruption/route/silence-hint lifecycle to track.
        #if canImport(UIKit)
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            switch rawType {
            case AVAudioSession.InterruptionType.began.rawValue:
                AppLog.audioStream.line("Audio session interrupted (began)")
                if self.mode == .music {
                    // Pause the source instead of reloading — exclusive Music
                    // mode should yield gracefully to a call, not fight it.
                    self.handleInterruptionBegan()
                } else {
                    self.requestReload("audio session interrupted")
                }
            case AVAudioSession.InterruptionType.ended.rawValue:
                AppLog.audioStream.line("Audio session interruption ended")
                if self.mode == .music {
                    let raw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
                    self.handleInterruptionEnded(shouldResume: shouldResume)
                } else {
                    self.requestReload("interruption ended")
                }
            default:
                break
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] _ in
            AppLog.audioStream.line("Media services reset — rebuilding engine")
            self?.sessionConfigured = false // session state was wiped
            self?.scheduleAudioRebuild(delay: .milliseconds(100))
        })
        // Diagnostics: visionOS rerouting our output to the People channel
        // when Safari WebRTC kicks in shows up here, not as an interruption.
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            let session = AVAudioSession.sharedInstance()
            let outs = session.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            AppLog.audioStream.line("Route change (\(reason.map(String.init(describing:)) ?? "?")) → outputs=[\(outs)] silenceHint=\(session.secondaryAudioShouldBeSilencedHint)")
        })
        // visionOS doesn't always notify us via interruption/route-change
        // when Safari WebRTC takes the People channel — sometimes it just
        // flips this hint and silently routes our output to nowhere. On
        // any flip (begin and end), reload the stream.
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let raw = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt ?? 0
            let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw)
            AppLog.audioStream.line("Silence-secondary-audio hint: \(type.map(String.init(describing:)) ?? "?")")
            // Mixable (Speaker) only: this hint signals the People-channel
            // reroute, which doesn't apply to an exclusive Music-mode session.
            if self.mode == .speaker {
                self.requestReload("silence-secondary-audio hint flipped")
            }
        })
        #endif
    }

    /// Tears down this receiver and asks the manager to reload the stream
    /// immediately with a fresh receiver (which re-asserts the audio
    /// session). Mirrors `fail(_:)` but routes to the instant reload path
    /// instead of the error/backoff retry path. Safe against bursts: the
    /// first signal wins, the rest hit `stopped` and no-op.
    private nonisolated func requestReload(_ reason: String) {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            connection?.cancel()
            connection = nil
            udpListener?.cancel()
            udpListener = nil
            udpConnection?.cancel()
            udpConnection = nil
            for observer in sessionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            sessionObservers.removeAll()
            teardownAudio()
            onEvent?(.reloadRequested(reason))
        }
    }

    nonisolated func stop() {
        queue.async { [self] in
            stopped = true
            onEvent = nil
            connection?.cancel()
            connection = nil
            udpListener?.cancel()
            udpListener = nil
            udpConnection?.cancel()
            udpConnection = nil
            for observer in sessionObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            sessionObservers.removeAll()
            teardownAudio()
            #if canImport(UIKit)
            if mode == .music {
                // Release exclusive focus so other apps resume.
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            #endif
        }
    }

    // MARK: - Music-mode interruption handling

    /// A call/other interruption began. Pause the Mac source (so it stops
    /// producing audio into a now-deactivated session) and stop local
    /// playback. The connection stays up — interruptions are transient.
    private nonisolated func handleInterruptionBegan() {
        queue.async { [self] in
            guard !stopped else { return }
            playerNode?.pause()
        }
        send(.pause)
    }

    /// The interruption ended. Rebuild the engine and re-activate the session
    /// (the interruption deactivated it), and resume the Mac if the system
    /// indicated we should. If not, we stay ready so a Control Center play
    /// works immediately.
    private nonisolated func handleInterruptionEnded(shouldResume: Bool) {
        scheduleAudioRebuild(delay: .milliseconds(150))
        if shouldResume {
            send(.play)
        }
    }

    // MARK: - Receive / Parse

    private nonisolated func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }

            if let data, !data.isEmpty {
                self.pending.append(data)
                self.totalBytes += data.count
                self.processPending()
            }

            if isComplete {
                self.fail(nil) // sender closed the stream cleanly
            } else if let error {
                self.fail("Receive error: \(error.localizedDescription)")
            } else {
                self.receiveLoop()
            }
        }
    }

    private nonisolated func processPending() {
        // Header first
        if header == nil {
            guard pending.count >= AudioStreamProtocol.headerSize else { return }
            guard let parsed = AudioStreamHeader(parsing: pending) else {
                fail("Invalid stream header — is the sender the Longwave Companion?")
                return
            }
            pending.removeFirst(AudioStreamProtocol.headerSize)
            header = parsed
            guard setupAudio(header: parsed) else {
                fail("Unsupported audio format (\(parsed.channelCount)ch @ \(parsed.sampleRate) Hz)")
                return
            }
            onEvent?(.connected(sampleRate: parsed.sampleRate, channels: parsed.channelCount))
            if lowLatency { openUDP() }
        }

        // Then typed, length-prefixed frames
        while let length = AudioStreamProtocol.decodeFrameLength(pending) {
            guard length >= 1, length <= AudioStreamProtocol.maxFrameBytes else {
                fail("Malformed frame (\(length) bytes)")
                return
            }
            let frameEnd = AudioStreamProtocol.frameLengthPrefixSize + Int(length)
            guard pending.count >= frameEnd else { return }

            let type = pending[pending.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize)]
            let payload = pending.subdata(in: pending.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize + 1)..<pending.startIndex.advanced(by: frameEnd))
            pending.removeFirst(frameEnd)

            switch AudioStreamProtocol.FrameType(rawValue: type) {
            case .pcm:
                schedule(payload)
            case .nowPlaying:
                // Malformed metadata is logged and skipped — never fail
                // the audio stream over it.
                if let info = NowPlayingInfo.decode(payload) {
                    onEvent?(.nowPlaying(info))
                } else {
                    AppLog.audioStream.line("Skipping malformed now-playing frame (\(payload.count) bytes)")
                }
            case .artwork:
                onEvent?(.artwork(payload))
            case .keepAlive:
                // Silence heartbeat from the sender (no PCM while quiet).
                // Refresh liveness so the health probe doesn't mistake a
                // quiet-but-live connection for a dead one.
                onEvent?(.bytesReceived(totalBytes))
            case .command, .udpHello, nil:
                break // not receiver-bound / unknown — skip
            }
        }
    }

    // MARK: - Low-latency UDP path

    /// Opens a UDP listener on an ephemeral port and advertises it to the
    /// sender via a `udpHello` over TCP. The sender then connects out and
    /// pushes PCM datagrams here. Runs on `queue`. Falls back to TCP if no
    /// PCM arrives within the grace window.
    private nonisolated func openUDP() {
        guard !stopped, udpListener == nil else { return }
        udpFramesReceived = 0
        let listener: NWListener
        do {
            listener = try NWListener(using: AudioCrypto.dtlsUDPParameters(token: token))
        } catch {
            AppLog.audioStream.line("Low-latency UDP listener failed to open: \(error.localizedDescription) — staying on TCP")
            onEvent?(.lowLatencyUnavailable)
            return
        }
        udpListener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let udpPort = listener.port?.rawValue else { return }
                AppLog.audioStream.line("Low-latency UDP listening on port \(udpPort) — advertising to sender")
                var payload = Data(count: 2)
                payload[0] = UInt8(udpPort & 0xff)
                payload[1] = UInt8(udpPort >> 8)
                let hello = AudioStreamProtocol.encodeFrame(.udpHello, payload)
                self.connection?.send(content: hello, completion: .contentProcessed { _ in })
            case .failed(let error):
                AppLog.audioStream.line("Low-latency UDP listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            // Single sender; a fresh inbound flow displaces any prior.
            self.udpConnection?.cancel()
            self.udpConnection = connection
            connection.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    AppLog.audioStream.line("⚠️ UDP DTLS failed: \(error.localizedDescription)")
                }
            }
            connection.start(queue: self.queue)
            self.udpReceiveLoop(connection)
        }
        listener.start(queue: queue)

        // Fallback: if PCM never arrives (one-way UDP block / firewall), drop
        // to plain TCP for this session and surface it loudly.
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped, self.udpFramesReceived == 0 else { return }
            AppLog.audioStream.line("⚠️ No UDP PCM within 2 s — low-latency unavailable, falling back to TCP")
            self.udpListener?.cancel()
            self.udpListener = nil
            self.udpConnection?.cancel()
            self.udpConnection = nil
            self.onEvent?(.lowLatencyUnavailable)
        }
    }

    private nonisolated func udpReceiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                // Count *any* datagram (PCM or keepalive) for liveness — a
                // silent source sends only keepalives, and the grace window
                // must still see the path as live.
                self.udpFramesReceived += 1
                if self.udpFramesReceived == 1 {
                    AppLog.audioStream.line("First low-latency UDP datagram received (\(data.count) bytes) — engaging")
                    self.onEvent?(.lowLatencyEngaged)
                }
                self.totalBytes += data.count
                self.processUDPDatagram(data)
            }
            if let error {
                AppLog.audioStream.line("⚠️ UDP receive error: \(String(describing: error))")
            } else {
                self.udpReceiveLoop(connection)
            }
        }
    }

    /// One UDP datagram == one `pcm` frame (datagram boundaries preserve
    /// framing). Decoded directly — kept off the TCP `pending` byte-stream
    /// buffer to avoid interleaving a whole datagram into a partial TCP frame.
    private nonisolated func processUDPDatagram(_ data: Data) {
        guard let length = AudioStreamProtocol.decodeFrameLength(data),
              length >= 1, length <= AudioStreamProtocol.maxFrameBytes else { return }
        let frameEnd = AudioStreamProtocol.frameLengthPrefixSize + Int(length)
        guard data.count >= frameEnd else { return }
        let type = data[data.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize)]
        // Non-PCM datagrams carry no audio. A keepAlive (sent while the
        // source is silent) still proves liveness — refresh the health probe
        // so a quiet UDP stream isn't mistaken for a dead one.
        if type == AudioStreamProtocol.FrameType.keepAlive.rawValue {
            onEvent?(.bytesReceived(totalBytes))
            return
        }
        guard type == AudioStreamProtocol.FrameType.pcm.rawValue else { return }
        let payload = data.subdata(in: data.startIndex.advanced(by: AudioStreamProtocol.frameLengthPrefixSize + 1)..<data.startIndex.advanced(by: frameEnd))
        schedule(payload)
    }

    /// Sends a media transport command to the Mac sender.
    nonisolated func send(_ command: MediaCommand) {
        queue.async { [self] in
            guard !stopped, let connection,
                  let payload = MediaCommandMessage(command: command).encoded() else { return }
            let frame = AudioStreamProtocol.encodeFrame(.command, payload)
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    /// Locally pauses/resumes playback without disconnecting: incoming PCM
    /// is dropped while paused (no stale backlog on resume) and the
    /// connection keeps draining so it stays healthy.
    nonisolated func setPaused(_ paused: Bool) {
        queue.async { [self] in
            guard playbackPaused != paused else { return }
            playbackPaused = paused
            if paused {
                playerNode?.pause()
            } else {
                // Restart with the normal jitter prebuffer.
                playerNode?.stop()
                scheduledFrames = 0
                lastScheduleNanos = 0
            }
        }
    }

    private nonisolated func fail(_ reason: String?) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        udpListener?.cancel()
        udpListener = nil
        udpConnection?.cancel()
        udpConnection = nil
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
        teardownAudio()
        onEvent?(.disconnected(reason))
    }

    /// Like `fail`, but routes to the terminal authFailed event so the
    /// manager surfaces the reason without scheduling a retry.
    private nonisolated func authFailed(_ reason: String) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        udpListener?.cancel()
        udpListener = nil
        udpConnection?.cancel()
        udpConnection = nil
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
        teardownAudio()
        onEvent?(.authFailed(reason))
    }

    // MARK: - Audio

    private nonisolated func setupAudio(header: AudioStreamHeader) -> Bool {
        // macOS has no AVAudioSession; AVAudioEngine renders to the default
        // output device directly, so the session category/activation/route
        // dance below is visionOS/iOS-only.
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()

        // Configure the session only once per receiver. Re-asserting the
        // category mid-stream (e.g. while a VoIP call owns the voice
        // channel) yanks the system audio config out from under the other
        // app — the cause of "GMeet loses audio until speaker test".
        if !sessionConfigured {
            sessionConfigured = true
            // AVAudioEngine isn't a Now Playing candidate so the per-app
            // Spatialize Stereo system setting doesn't apply here — the
            // user's `spatialAudioMode` toggle is this stream's only
            // control over head-tracked rendering vs flat bypass. `.auto`
            // skips the call outright and leaves the session at whatever the
            // system resolves for an app that never states an opinion.
            // Speaker mode uses .mixWithOthers to coexist with other apps and
            // VoIP calls (ineligible for Now Playing as a trade-off). Music
            // mode takes exclusive focus (no mix) so it *is* a Now Playing /
            // Control Center app (see AudioStreamManager's MP integration).
            do {
                let options: AVAudioSession.CategoryOptions = mode == .music ? [] : [.mixWithOthers]
                try session.setCategory(.playback, mode: .default, options: options)
                if let experience = spatialAudioMode.avSpatialExperience {
                    try session.setIntendedSpatialExperience(experience)
                }
                if mode == .speaker {
                    // Keep a mixable session running (un-ducked) when the user
                    // looks at other windows. Music mode is a real Now Playing
                    // app via MPNowPlayingInfoCenter, so this isn't needed.
                    try session.setIsNowPlayingCandidate(true)
                }
            } catch {
                AppLog.audioStream.line("Failed to configure audio session: \(error)")
            }
        }

        // Activate on every (re)build. After an interruption (e.g. a VoIP
        // call grabbing the People channel) the system deactivates our
        // session — engine.start() alone won't bring it back, so the
        // rebuilt engine reports "running" but pumps audio nowhere.
        // Returning false here engages the rebuild retry/backoff.
        //
        // Exception: in Music mode, behave like a regular media player and
        // don't wrestle the channel away from another app that's actively
        // playing. setActive(true) on an exclusive session would interrupt
        // it. Stay yielded — when the other app stops, the audio-session
        // interruption-ended notification rebuilds us and re-activates then.
        // (Speaker mode is mixable, so this never applies.)
        if mode == .music, session.isOtherAudioPlaying {
            AppLog.audioStream.line("Music mode: other audio is playing — yielding, not reacquiring the session")
        } else {
            do {
                try session.setActive(true)
            } catch {
                AppLog.audioStream.line("Failed to activate audio session: \(error)")
                return false
            }
        }
        let outs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        AppLog.audioStream.line("Session activated — outputs=[\(outs)] silenceHint=\(session.secondaryAudioShouldBeSilencedHint) otherAudio=\(session.isOtherAudioPlaying)")
        #endif

        // The wire format is interleaved int24, but AVAudioEngine requires
        // the standard (deinterleaved Float32) format on its graph — it
        // throws an NSException ("SetFormat") for an interleaved/non-float
        // format. We decode int24 → Float32 and deinterleave in schedule().
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: header.sampleRate,
            channels: AVAudioChannelCount(header.channelCount)
        ) else { return false }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        player.volume = volume
        // EQ sits between the player and the mixer. Always in the graph
        // (bypassed when disabled) so enabling it never needs a rebuild;
        // Float32 processing, no lookahead — quality/latency neutral.
        let eq = AVAudioUnitEQ(numberOfBands: EQSettings.maxBands)
        engine.attach(player)
        engine.attach(eq)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        apply(eqSettings, to: eq)

        do {
            try engine.start()
        } catch {
            AppLog.audioStream.line("Failed to start audio engine: \(error)")
            return false
        }

        audioEngine = engine
        playerNode = player
        eqNode = eq
        audioFormat = format
        scheduledFrames = 0

        // Engine config change = audio path shifted underneath us (VoIP
        // route, sample-rate switch, device change). Engine-only rebuild
        // doesn't recover when visionOS has rerouted us — reload the
        // whole receiver so the next setupAudio re-asserts the session.
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            AppLog.audioStream.line("Audio engine configuration changed")
            if self.mode == .music {
                // Keep the exclusive session; just rebuild the engine graph.
                self.scheduleAudioRebuild(delay: .milliseconds(100))
            } else {
                self.requestReload("engine configuration changed")
            }
        }

        return true
    }

    /// Tears down and rebuilds the engine for the current stream format,
    /// retrying with backoff while the system audio config is in flux
    /// (engine starts can fail transiently mid-call-transition).
    private nonisolated func scheduleAudioRebuild(delay: DispatchTimeInterval, attempt: Int = 0) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, let header = self.header else { return }
            self.teardownAudio()
            if self.setupAudio(header: header) {
                AppLog.audioStream.line("Audio engine rebuilt")
            } else if attempt < 5 {
                self.scheduleAudioRebuild(delay: .milliseconds(500 * (attempt + 1)), attempt: attempt + 1)
            } else {
                AppLog.audioStream.line("Audio engine rebuild failed after \(attempt + 1) attempts")
            }
        }
    }

    /// Pushes an EQSettings snapshot into the node's fixed 16-band array:
    /// active bands get the user's parameters (Q converted to the node's
    /// bandwidth-in-octaves unit), the rest are bypassed. Called on `queue`
    /// only — at engine build and live from `setEQ`.
    private nonisolated func apply(_ settings: EQSettings, to eq: AVAudioUnitEQ) {
        eq.bypass = !settings.enabled
        eq.globalGain = Float(min(max(settings.preampDB, -12), 0))
        // Band centers above Nyquist make the filter misbehave — clamp to
        // the actual wire rate, not the nominal 20 kHz editor limit.
        let maxHz = header.map { $0.sampleRate / 2 * 0.95 } ?? EQSettings.maxFrequency
        for (i, node) in eq.bands.enumerated() {
            guard settings.enabled, i < settings.bands.count else {
                node.bypass = true
                node.gain = 0
                continue
            }
            let band = settings.bands[i].clamped()
            switch band.type {
            case .parametric: node.filterType = .parametric
            case .lowShelf: node.filterType = .lowShelf
            case .highShelf: node.filterType = .highShelf
            }
            node.frequency = Float(min(band.frequency, maxHz))
            node.gain = Float(band.gain)
            node.bandwidth = Float(EQSettings.bandwidthOctaves(q: band.q))
            node.bypass = false
        }
    }

    private nonisolated func teardownAudio() {
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
        }
        engineObserver = nil
        playerNode?.stop()
        audioEngine?.stop()
        if let engine = audioEngine, let player = playerNode {
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }
        if let engine = audioEngine, let eq = eqNode {
            engine.disconnectNodeOutput(eq)
            engine.detach(eq)
        }
        audioEngine = nil
        playerNode = nil
        eqNode = nil
        audioFormat = nil
    }

    private nonisolated func schedule(_ payload: Data) {
        guard let playerNode, let format = audioFormat else { return }

        // Local pause: drop frames (no stale backlog on resume) but keep
        // emitting throttled stats so the connection health probe stays alive.
        if playbackPaused {
            droppedWhilePaused += 1
            if droppedWhilePaused % 50 == 0 {
                onEvent?(.bytesReceived(totalBytes))
            }
            return
        }

        let channels = Int(format.channelCount)
        let bytesPerWireFrame = channels * AudioStreamProtocol.bytesPerSample
        guard payload.count % bytesPerWireFrame == 0 else { return }
        let frameCount = AVAudioFrameCount(payload.count / bytesPerWireFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        // Decode interleaved wire int24 → Float32, deinterleaving into the
        // engine's per-channel buffers.
        payload.withUnsafeBytes { raw in
            guard let channelData = buffer.floatChannelData else { return }
            let bytes = raw.bindMemory(to: UInt8.self)
            for channel in 0..<channels {
                let out = channelData[channel]
                for frame in 0..<Int(frameCount) {
                    out[frame] = PCM24.sample(bytes, at: (frame * channels + channel) * AudioStreamProtocol.bytesPerSample)
                }
            }
        }

        // Exact-zero payload == a warm-keep silence frame from the sender
        // (it transmits silence for a few seconds across short gaps before
        // suppressing). Used below to gate the animated glyph. `contains`
        // early-exits, so real audio costs next to nothing.
        let isSilentFrame = !payload.contains { $0 != 0 }

        // Resume after a silence gap: once the sender suppresses sustained
        // silence the player node drains dry. Feeding it a single late buffer
        // underruns and pops (worst on the small low-latency UDP cushion) —
        // reset so the jitter prebuffer is rebuilt before playback resumes,
        // exactly like a fresh start. The threshold sits well above the
        // ~10–20 ms frame cadence so only real suppression gaps trigger it.
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        if scheduledFrames >= prebufferFrameCount, lastScheduleNanos != 0,
           nowNanos &- lastScheduleNanos > 200_000_000 {
            playerNode.stop()
            scheduledFrames = 0
        }
        lastScheduleNanos = nowNanos

        playerNode.scheduleBuffer(buffer)
        scheduledFrames += 1

        // Drive the animated glyph off *actual sound*. The sender keeps the
        // stream warm with exact-silence frames across short gaps (so playback
        // doesn't glitch), so a zero-filled frame is silence — schedule it to
        // keep the node fed, but don't count it as activity. The manager's
        // watchdog then settles the animation shortly after sound stops.
        if !isSilentFrame, nowNanos &- lastAudioActivityNanos > 200_000_000 {
            lastAudioActivityNanos = nowNanos
            onEvent?(.audioActivity)
        }

        // Hold playback until a small jitter buffer has accumulated
        if scheduledFrames == prebufferFrameCount {
            playerNode.play()
        }

        // Throttled stats update (~every 0.5 s at 10 ms frames)
        if scheduledFrames % 50 == 0 {
            onEvent?(.bytesReceived(totalBytes))
        }
    }
}
