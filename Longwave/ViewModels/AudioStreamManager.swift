import Foundation
import os
import Network
import AVFoundation
import Observation
import RAVEMedia
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

    // visionOS, not canImport(UIKit): `AVAudioSessionSpatialExperience` and
    // `setIntendedSpatialExperience` are visionOS-only API. iOS imports UIKit
    // and has neither, so the wider guard didn't compile there.
    #if os(visionOS)
    /// `nil` for `.auto` — the caller should skip the `setIntendedSpatialExperience`
    /// call entirely rather than pass this through, since there's no "system
    /// default" case in that API.
    /// `nonisolated`: a pure mapping, read from the receiver's own queue and
    /// from `AudioSessionCoordinator`, neither of which is the main actor.
    nonisolated var avSpatialExperience: (any AVAudioSessionSpatialExperience)? {
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

    /// The mode the user picked for this player (Speaker vs Music), persisted
    /// per player. Whether Music is what actually runs is a separate question
    /// — see `effectiveAudioMode`. Changing it mid-stream rebuilds the
    /// receiver (the session config differs) and re-syncs the Now Playing /
    /// Control Center integration.
    var audioMode: AudioMode {
        didSet {
            guard audioMode != oldValue else { return }
            UserDefaults.standard.set(audioMode.rawValue, forKey: keys.audioMode)
            // Picking Music here is an explicit choice, so it takes the slot
            // from whoever had it rather than quietly doing nothing.
            if audioMode == .music {
                claimMusicMode(steal: true)
            } else {
                releaseMusicMode()
            }
            if state == .streaming || state == .connecting {
                reconnectLast() // rebuild with the new session category
            }
            refreshNowPlayingIntegration()
        }
    }

    /// Flips between the two modes (mini-player button).
    func toggleAudioMode() {
        // Already asking for Music and not getting it: the press takes the
        // slot from whoever has it, rather than "turning off" a mode that
        // isn't running anyway.
        if isForcedToSpeaker {
            claimMusicMode(steal: true)
            effectiveModeChanged()
            return
        }
        audioMode = (audioMode == .music) ? .speaker : .music
    }

    /// Glyph for the mode button — what is actually playing, not what was
    /// asked for, so a stream running in Speaker never shows a music note.
    var audioModeSymbol: String {
        effectiveAudioMode == .music ? "music.note" : "hifispeaker"
    }

    /// One line for the mode button's help text / accessibility label,
    /// including why Music mode isn't running when it was asked for.
    var audioModeLabel: String {
        guard isForcedToSpeaker else {
            return effectiveAudioMode == .music ? "Music Mode" : "Speaker Mode"
        }
        if let holder = musicModeHolderTitle {
            return "Speaker Mode — \(holder) is using Music Mode"
        }
        return "Speaker Mode — another session is using Music Mode"
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

    /// Flips between explicit on/off (mini-player button). visionOS's system
    /// default already spatializes — including plain stereo content — so
    /// `.auto` sounds identical to `.on`; the first press out of `.auto`
    /// needs to land on `.off` to produce an audible change, not silently
    /// re-land on `.on`.
    func toggleSpatialAudio() {
        spatialAudioMode = (spatialAudioMode == .off) ? .on : .off
    }

    /// Whether Control Center remote-command targets have been installed yet
    /// (added once, then just enabled/disabled per mode). Static, because
    /// `MPRemoteCommandCenter` is one object for the whole app: a second
    /// player adding its own targets would make one Control Center press
    /// reach every player at once.
    private static var remoteCommandsConfigured = false

    /// The player whose stream the Now Playing entry currently describes.
    /// There is one entry and one transport for the app, so a player that
    /// isn't this one must leave both alone — a Speaker stream stopping used
    /// to wipe the Music stream's Control Center card.
    private static weak var nowPlayingOwner: AudioStreamManager?

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
    var volume: Double {
        didSet {
            UserDefaults.standard.set(volume, forKey: keys.volume)
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

    // iOS suspends the app shortly after it backgrounds unless something is
    // actively justifying the "audio" background mode. A drop that happens
    // while locked tears the receiver down first, so there's nothing left
    // rendering audio to keep us alive while the backoff/health-recheck
    // Task sleeps and reconnects — it just stalls until the user unlocks and
    // reopens the app. Wrapping the retry window in a background task asks
    // iOS for extra runway to actually finish the reconnect. Not needed on
    // visionOS (no equivalent suspend-on-lock) or macOS (no UIApplication).
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundRetryWindow() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pro.longwave.audio-reconnect") { [weak self] in
            self?.endBackgroundRetryWindow()
        }
    }

    private func endBackgroundRetryWindow() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

    /// Token delivered via an AirDropped x-callback URL, waiting to be
    /// consumed by an open (or freshly opened) connection form. Set by the
    /// app's onOpenURL handler; cleared once a form fills its field.
    var pendingImportedToken: String?

    /// Records a token imported from a `longwave://…/setAudioToken` URL so
    /// the connection form can auto-fill it.
    func importToken(_ token: String) {
        pendingImportedToken = token
    }

    /// Where this player's preferences and last target live.
    ///
    /// The app's shared player keeps the original, unsuffixed keys, so an
    /// upgrade finds everything where it left it. A Native session's own
    /// player suffixes each key with its connection id, so two sessions
    /// streaming at once remember their own host, volume, mode and live
    /// toggle instead of overwriting each other's.
    private struct DefaultsKeys {
        let host: String
        let port: String
        let title: String
        let token: String
        let lowLatency: String
        let liveEnabled: String
        let audioMode: String
        let volume: String

        init(scope: String?) {
            func key(_ base: String) -> String {
                guard let scope else { return base }
                return "\(base).\(scope)"
            }
            host = key("lastAudioHost")
            port = key("lastAudioPort")
            title = key("lastAudioTitle")
            token = key("lastAudioToken")
            lowLatency = key("lastAudioLowLatency")
            liveEnabled = key("nativeAudioLiveEnabled")
            audioMode = key("audioMode")
            volume = key("audioVolume")
        }
    }

    /// Nil for the app's shared player; a Native session's connection id for
    /// one of its own.
    let scope: String?
    private let keys: DefaultsKeys

    /// - Parameter scope: `nil` for the app's shared player (VNC, the
    ///   standalone Audio Stream window, the iPhone's Audio tab); a stable
    ///   per-session string for a Native session's own player.
    init(scope: String? = nil) {
        self.scope = scope
        let keys = DefaultsKeys(scope: scope)
        self.keys = keys
        let defaults = UserDefaults.standard
        // A scoped player that has never been used inherits the shared
        // player's preferences, so a session opened after the multi-session
        // change starts where the single player left off rather than at the
        // factory defaults.
        let shared = DefaultsKeys(scope: nil)
        audioMode = AudioMode(
            rawValue: defaults.string(forKey: keys.audioMode)
                ?? defaults.string(forKey: shared.audioMode) ?? ""
        ) ?? .speaker
        volume = defaults.object(forKey: keys.volume) as? Double
            ?? defaults.object(forKey: shared.volume) as? Double
            ?? 1.0
        liveEnabled = defaults.bool(forKey: keys.liveEnabled)
        isMuted = volume <= 0
        AudioStreamManager.register(self)
    }

    /// The Native window's live Audio toggle, persisted separately from
    /// `state`: a transient drop or a deliberate toggle-off both leave
    /// `state` idle, but only this flag says whether Audio should resume
    /// after a scene reactivation or a full space-restoration relaunch (a
    /// fresh `AudioStreamManager` with no in-memory state).
    var liveEnabled: Bool {
        didSet {
            guard liveEnabled != oldValue else { return }
            UserDefaults.standard.set(liveEnabled, forKey: keys.liveEnabled)
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
        defaults.set(hostname, forKey: keys.host)
        defaults.set(Int(port), forKey: keys.port)
        defaults.set(title, forKey: keys.title)
        defaults.set(token, forKey: keys.token)
        defaults.set(lowLatency, forKey: keys.lowLatency)
    }

    func connect(hostname: String, port: UInt16, token: String, title: String, lowLatency: Bool = false) {
        // Not `disconnect()`: a reconnect must not put the Music slot back in
        // the pool, or every rebuild (a reload, a health re-check) would hand
        // it to another session.
        disconnect(releasingMusicMode: false)
        // The receiver's mode is fixed at construction, so the slot has to be
        // settled first. Only if it's free — taking it is an explicit choice
        // the user makes in `audioMode`, not something connecting does.
        if audioMode == .music { claimMusicMode(steal: false) }
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

        let receiver = AudioStreamReceiver(hostname: hostname, port: port, token: token, lowLatency: lowLatency, volume: Float(volume), mode: effectiveAudioMode, eq: eqSettings, spatialAudioMode: spatialAudioMode)
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
        disconnect(releasingMusicMode: true)
    }

    private func disconnect(releasingMusicMode: Bool) {
        pendingCloseTask?.cancel()
        pendingCloseTask = nil
        retryTask?.cancel()
        retryTask = nil
        healthRecheckTask?.cancel()
        healthRecheckTask = nil
        #if os(iOS)
        endBackgroundRetryWindow()
        #endif
        receiver?.stop()
        receiver = nil
        state = .idle
        isReceivingAudio = false
        clearNowPlayingIntegration()
        if releasingMusicMode { releaseMusicMode() }
    }

    /// Explicit user disconnect: also forget the last connection so the
    /// stream doesn't auto-resurrect on the next window restore.
    func userDisconnect() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: keys.host)
        defaults.removeObject(forKey: keys.port)
        defaults.removeObject(forKey: keys.title)
        defaults.removeObject(forKey: keys.token)
        defaults.removeObject(forKey: keys.lowLatency)
        liveEnabled = false
        disconnect()
    }

    /// Reconnects to the last-used sender, if one is remembered.
    func reconnectLast() {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: keys.host),
              let port = UInt16(exactly: defaults.integer(forKey: keys.port)),
              port > 0 else { return }
        // A pending fallback override (UDP failed) forces TCP for this
        // reconnect without disturbing the saved preference.
        let lowLatency = lowLatencyOverride ?? defaults.bool(forKey: keys.lowLatency)
        connect(
            hostname: host,
            port: port,
            token: defaults.string(forKey: keys.token) ?? "",
            title: defaults.string(forKey: keys.title) ?? "",
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
            if effectiveAudioMode == .speaker {
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
        #if os(iOS)
        beginBackgroundRetryWindow()
        #endif
        healthRecheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.healthRecheckTask = nil
            guard self.state == .streaming else { return }
            if self.isHealthy {
                AppLog.audioStream.line("Music mode: keepalive arrived — connection alive, not reconnecting")
                #if os(iOS)
                self.endBackgroundRetryWindow()
                #endif
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
            #if os(iOS)
            endBackgroundRetryWindow()
            #endif
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
            if effectiveAudioMode == .music { updateNowPlayingInfo() }
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
            #if os(iOS)
            endBackgroundRetryWindow()
            #endif
            state = .error(reason)
            releaseMusicMode()
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
        #if os(iOS)
        beginBackgroundRetryWindow()
        #endif
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnectLast()
        }
    }

    // MARK: - Music-mode arbitration

    /// Every player that has ever been created, so the Music slot can be
    /// handed on when its holder goes away. Weak: a Native session's player
    /// lives and dies with the session.
    private final class WeakPlayer {
        weak var value: AudioStreamManager?
        init(_ value: AudioStreamManager) { self.value = value }
    }

    private static var players: [WeakPlayer] = []
    /// The one player currently allowed to run in Music mode, if any.
    private static weak var musicHolder: AudioStreamManager?

    private static func register(_ player: AudioStreamManager) {
        players.removeAll { $0.value == nil }
        players.append(WeakPlayer(player))
    }

    private static var livePlayers: [AudioStreamManager] {
        players.compactMap(\.value)
    }

    /// Whether this player holds the process-wide Music slot. Stored (rather
    /// than derived from the static) so the views observing
    /// `effectiveAudioMode` see it change.
    private(set) var holdsMusicMode = false

    /// The mode this player is actually running in.
    ///
    /// Music mode is exclusive by construction: it takes the audio session
    /// away from everything else, and the app has exactly one Now Playing
    /// entry and one Control Center transport to give it. With several Native
    /// sessions streaming at once, letting each of them ask for that would
    /// mean the newest one silently cutting off the others. So the preference
    /// is per player and the grant is process-wide — one player runs in Music,
    /// every other one runs in Speaker, which is mixable, so the streams play
    /// together.
    var effectiveAudioMode: AudioMode {
        audioMode == .music && holdsMusicMode ? .music : .speaker
    }

    /// True when this player asked for Music mode but another one is holding
    /// it, so this stream is mixing in Speaker mode instead. Surfaced in the
    /// player UI — otherwise the Music button looks stuck.
    var isForcedToSpeaker: Bool {
        audioMode == .music && !holdsMusicMode
    }

    /// The player currently in Music mode, when it isn't this one — for the
    /// "…because <host> has it" half of the explanation.
    var musicModeHolderTitle: String? {
        guard isForcedToSpeaker, let holder = Self.musicHolder, holder !== self else { return nil }
        return holder.connectionTitle.isEmpty ? nil : holder.connectionTitle
    }

    /// Takes the Music slot. `steal` is for an explicit user choice: picking
    /// Music in this player's UI moves it here and drops whoever had it into
    /// Speaker mode. Connecting only ever takes a free slot.
    private func claimMusicMode(steal: Bool) {
        if let holder = Self.musicHolder, holder !== self {
            guard steal else { return }
            Self.musicHolder = self
            holdsMusicMode = true
            holder.holdsMusicMode = false
            holder.effectiveModeChanged()
            return
        }
        Self.musicHolder = self
        holdsMusicMode = true
    }

    /// Gives the Music slot up and offers it to another live player that
    /// wants it — the longest-running one first.
    private func releaseMusicMode() {
        let wasHolder = Self.musicHolder === self
        holdsMusicMode = false
        // Only the holder hands the slot on. Any other player stopping is not
        // an occasion to reconnect someone else's stream.
        guard wasHolder else { return }
        Self.musicHolder = nil
        guard let next = Self.livePlayers.first(where: {
            $0 !== self && $0.audioMode == .music && $0.state != .idle
        }) else { return }
        Self.musicHolder = next
        next.holdsMusicMode = true
        next.effectiveModeChanged()
    }

    /// This player's session category just changed under it. The receiver
    /// fixes its mode at construction, so the live one has to be rebuilt —
    /// a brief gap in that stream, and the only alternative is leaving it in
    /// a mode it is no longer entitled to.
    private func effectiveModeChanged() {
        refreshNowPlayingIntegration()
        guard state == .streaming || state == .connecting else { return }
        reconnectLast()
    }

    // MARK: - Now Playing / Control Center (Music Mode)

    /// Aligns the Now Playing / Control Center integration with the current
    /// mode: Music Mode enables the remote commands and populates the info
    /// center; Speaker Mode tears it down (a mixable session is ineligible for
    /// Now Playing anyway — see the audio-session notes in CLAUDE.md).
    private func refreshNowPlayingIntegration() {
        if effectiveAudioMode == .music, state == .streaming {
            Self.nowPlayingOwner = self
            configureRemoteCommands()
            setRemoteCommandsEnabled(true)
            updateNowPlayingInfo()
        } else {
            clearNowPlayingIntegration()
        }
    }

    private func clearNowPlayingIntegration() {
        guard Self.nowPlayingOwner === self else { return }
        Self.nowPlayingOwner = nil
        setRemoteCommandsEnabled(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Installs the Control Center transport handlers once; each maps to a
    /// MediaCommand sent to the Mac's Music.app over the stream.
    /// Installs the targets once for the whole app, each forwarding to
    /// whichever player owns the Now Playing entry at the time — not to the
    /// player that happened to install them, which may since have dropped to
    /// Speaker mode or gone away entirely.
    private func configureRemoteCommands() {
        guard !Self.remoteCommandsConfigured else { return }
        Self.remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()
        func forward(_ command: MediaCommand) -> MPRemoteCommandHandlerStatus {
            AudioStreamManager.nowPlayingOwner?.sendCommand(command)
            return .success
        }
        center.playCommand.addTarget { _ in forward(.play) }
        center.pauseCommand.addTarget { _ in forward(.pause) }
        center.togglePlayPauseCommand.addTarget { _ in forward(.toggle) }
        center.nextTrackCommand.addTarget { _ in forward(.next) }
        center.previousTrackCommand.addTarget { _ in forward(.previous) }
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        guard Self.remoteCommandsConfigured else { return }
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.isEnabled = enabled
        }
    }

    /// Pushes the current track metadata into the system Now Playing info
    /// center (Music Mode only) so it surfaces in Control Center.
    private func updateNowPlayingInfo() {
        guard effectiveAudioMode == .music else { return }
        Self.nowPlayingOwner = self
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
    /// Bytes at the front of `pending` already parsed, relative to its
    /// `startIndex`. Advancing an index is O(1); `removeFirst` memmoves the
    /// whole remainder on *every* frame, which at ~100 frames/s behind 64 KB
    /// reads was several MB/s of pointless copying on the same queue that
    /// schedules audio. Compacted in `compactPending` once it's worth a copy.
    private nonisolated(unsafe) var pendingOffset = 0
    /// Reassembly buffer for chunked artwork (see `AudioStreamProtocol`).
    private nonisolated(unsafe) var artworkAssembly = Data()
    private nonisolated(unsafe) var header: AudioStreamHeader?
    private nonisolated(unsafe) var stopped = false

    private nonisolated(unsafe) var audioEngine: AVAudioEngine?
    private nonisolated(unsafe) var playerNode: AVAudioPlayerNode?
    private nonisolated(unsafe) var audioFormat: AVAudioFormat?

    /// Jitter cushion held before playback starts, and maintained thereafter,
    /// expressed in **seconds of audio** rather than a count of scheduled
    /// buffers.
    ///
    /// A buffer count meant wildly different things on the two transports:
    /// the sender splits each PCM blob into ~1.1 KB datagrams for the DTLS
    /// path, so "2 buffers" was roughly 7 ms of audio there versus ~43 ms for
    /// "4 buffers" on TCP — which is most of why low-latency mode fell apart
    /// under load. It also drifted with the Mac's IO buffer size, which was
    /// never pinned.
    ///
    /// TCP has to ride out a Wi-Fi retransmit without stalling, so it starts
    /// larger; UDP drops a datagram instead of stalling and can run tight.
    private let baseTargetBufferSeconds: Double
    private let maxTargetBufferSeconds: Double
    /// Underrun growth, for the case that can't wait for the next health
    /// tick: the target grows by half again (at least 40 ms) on the spot.
    private static let bufferGrowthFactor: Double = 1.5
    private static let bufferGrowthFloor: Double = 0.04
    /// How fast the target walks back down once the link no longer demands
    /// it. Slow, because being 50 ms over costs latency nobody notices and
    /// being 5 ms under costs a dropout everybody does.
    private static let bufferDecayStep: Double = 0.01

    /// The cushion has to cover the worst stall the link actually produces,
    /// and on this link that is a *measurement*, not a guess: the first run
    /// with gap instrumentation showed a recurring ~165 ms delivery stall
    /// (inter-arrival gaps of 160-176 ms, every window, with the missing
    /// frames arriving as a burst in the next one — average rate exactly
    /// nominal). A fixed 100 ms target could not cover that, and the old
    /// decay walked it back down to 100 after every underrun, which
    /// guaranteed the next one: four underruns in fifteen minutes, evenly
    /// spaced. So the target now tracks the observed stall instead.
    private static let stallMargin: Double = 1.3
    /// Per-interval decay of the remembered stall, so the cushion follows a
    /// link that gets better as well as one that gets worse (~halves in a
    /// minute of clean running).
    private static let stallDecay: Double = 0.9
    /// Decaying maximum of the observed inter-arrival gap, in seconds.
    private nonisolated(unsafe) var observedStallSeconds: Double = 0
    /// Longest gap allowed to size the cushion. Beyond this it is an outage,
    /// not jitter, and no sane amount of buffering covers it — but letting
    /// one set the target pins the cushion at its ceiling for minutes
    /// afterwards. (The sender's silence suppression produced a 1051-second
    /// "gap", which did exactly that.)
    private static let maxCushionableGapNanos: UInt64 = 350_000_000
    /// A gap this long is the sender's silence suppression, not a fault.
    private static let sourceSuppressionGapNanos: UInt64 = 1_000_000_000
    /// How long the queue may stay empty before a real re-prime is worth its
    /// silence. Below this, the post-stall burst is expected to refill it.
    private static let starvationGraceNanos: UInt64 = 1_500_000_000
    /// When the current starvation episode began (0 == not starved), so an
    /// underrun is counted once per episode rather than once per buffer.
    private nonisolated(unsafe) var starvedSinceNanos: UInt64 = 0
    /// Worst gap in the window that is small enough to cushion against.
    private nonisolated(unsafe) var cushionableGapNanos: UInt64 = 0
    /// Smoothing applied to the measured queue depth before it is used as the
    /// drift signal. Deliberately slow (~seconds): jitter must average out,
    /// clock drift must not.
    private static let depthSmoothing: Double = 0.002
    /// Minimum buffers between drift nudges. Correcting on *every* buffer is
    /// ~2000 ppm of authority against clock drift that is realistically under
    /// 100 ppm, so the loop simply saturates and stops telling you anything —
    /// which is exactly what the first on-device run showed (94 corrections a
    /// second, sustained). One nudge per four buffers is still ~490 ppm, an
    /// order of magnitude more than real drift needs. Bursts are the burst
    /// trim's job, not this loop's.
    private static let driftCorrectionInterval = 4
    private nonisolated(unsafe) var targetBufferSeconds: Double

    /// Sample frames scheduled on the player node but not yet played back,
    /// with a generation stamp so completion callbacks belonging to a flushed
    /// node can't decrement the new one's depth.
    ///
    /// This is the measurement everything below runs on. `AVAudioPlayerNode`
    /// exposes no depth query, and counting *scheduled* buffers — what this
    /// used to do — can never observe an underrun: a starved node does not
    /// stop, it renders silence and keeps its clock running, so the cushion
    /// is silently gone for good and every later jitter spike is audible.
    /// Written from the render thread as well as `queue`, hence the lock.
    private struct QueueState: Sendable {
        var frames = 0
        var generation = 0
    }
    private let queueState = OSAllocatedUnfairLock(initialState: QueueState())

    /// True once the cushion filled and the node was told to play.
    private nonisolated(unsafe) var playing = false
    /// Smoothed queue depth in sample frames — the drift signal.
    private nonisolated(unsafe) var depthAverage: Double = 0
    /// True while shedding a backlog (see the ceiling check in `schedule`).
    private nonisolated(unsafe) var trimming = false
    private nonisolated(unsafe) var underrunCount = 0
    /// `underrunCount` as of the last health tick, so a clean stretch can be
    /// recognised and the grown target relaxed again.
    private nonisolated(unsafe) var underrunsAtLastHealthLog = 0
    private nonisolated(unsafe) var trimmedFrames = 0
    private nonisolated(unsafe) var driftCorrections = 0
    /// Buffers since the last drift nudge, for the rate limit below.
    private nonisolated(unsafe) var buffersSinceDrift = 0
    /// Wire sample frames received since the last health log, and the worst
    /// inter-arrival gap in that window. Together these separate the two
    /// things that look identical in a depth reading: the sender running at a
    /// genuinely different rate (shows up in the effective input rate) and
    /// the sender delivering the right amount in lumps (shows up in the gap).
    private nonisolated(unsafe) var framesSinceHealthLog = 0
    private nonisolated(unsafe) var maxArrivalGapNanos: UInt64 = 0
    /// Shallowest the queue got during the window. Reported because the
    /// depth reading is biased *high* — `.dataPlayedBack` fires only after
    /// the output latency has elapsed — so a low-but-positive floor is how
    /// genuine starvation shows up when the `<= 0` test never trips. Those
    /// are the glitches heard with nothing in the log.
    private nonisolated(unsafe) var minDepthFrames = Int.max
    /// Largest single TCP read in the window. This is what separates a
    /// network stall from a receiver-side one, which are indistinguishable
    /// in an arrival gap: both show up as a gap followed by a burst. If the
    /// app simply stopped reading for ~165 ms, the socket buffered that
    /// audio and hands it all back in one read (~47 KB at 48 kHz stereo
    /// int24); if the network stalled, the data trickles in at the usual
    /// frame size afterwards.
    private nonisolated(unsafe) var maxReceiveBytes = 0
    /// Loss, reordering and media-clock jitter, from the `PCMStamp` on every
    /// PCM payload. Created with the header (it needs the sample rate) and
    /// kept across engine rebuilds — the network doesn't change with them.
    private nonisolated(unsafe) var arrivalStats: AudioArrivalStats?
    /// Uptime (ns) of the last periodic buffer-health log and stats emit.
    private nonisolated(unsafe) var lastHealthLogNanos: UInt64 = 0
    private nonisolated(unsafe) var lastStatsNanos: UInt64 = 0
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
        self.baseTargetBufferSeconds = lowLatency ? 0.040 : 0.100
        // Headroom for the stall-driven target to actually reach what the
        // link demands. A capped cushion that still underruns is the worst
        // of both: the latency without the robustness it was paid for.
        self.maxTargetBufferSeconds = lowLatency ? 0.200 : 0.400
        self.targetBufferSeconds = lowLatency ? 0.040 : 0.100
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
            #if os(visionOS)
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
            // …and so was the category the coordinator thinks it applied.
            AudioSessionCoordinator.shared.forgetAppliedState()
            self?.scheduleAudioRebuild(delay: .milliseconds(100))
        })
        // Diagnostics: visionOS rerouting our output to the People channel
        // when Safari WebRTC kicks in shows up here, not as an interruption.
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            let session = AVAudioSession.sharedInstance()
            let outs = session.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            AppLog.audioStream.line("Route change (\(reason.map(String.init(describing:)) ?? "?")) → outputs=[\(outs)] silenceHint=\(session.secondaryAudioShouldBeSilencedHint)")
            guard let self, reason == .categoryChange else { return }
            // A category change we didn't cause — the broadcast pipeline's
            // mic capture (`BroadcastMicCapture`) shares this process's one
            // AVAudioSession and reasserts .playAndRecord to record, which
            // resets the intended spatial experience to that category's own
            // default (observed as forced head-tracked rendering: starting a
            // broadcast while streaming audio silently re-spatialized it).
            // Re-declaring our own spatial experience doesn't touch category
            // or activation, so it can't fight Broadcast for the session —
            // it only reclaims the one setting that got stomped.
            #if os(visionOS)
            if let experience = self.spatialAudioMode.avSpatialExperience {
                do {
                    try session.setIntendedSpatialExperience(experience)
                } catch {
                    AppLog.audioStream.line("Failed to reclaim spatial audio experience after category change: \(error)")
                }
            }
            #endif
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
            // Leaving re-resolves the process session for whoever is left —
            // and releases it outright when this was the last stream playing.
            AudioSessionCoordinator.shared.leave(self)
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
    /// indicated we should. `shouldResume` is unreliable in practice — many
    /// short, benign interruptions (Siri, a notification sound, a brief
    /// route hiccup) end without it set, which otherwise left the stream
    /// silently paused until the user found it and hit Control Center play.
    /// So also resume whenever nothing else is actually holding the audio
    /// session by the time the interruption clears.
    private nonisolated func handleInterruptionEnded(shouldResume: Bool) {
        scheduleAudioRebuild(delay: .milliseconds(150))
        #if canImport(UIKit)
        let resume = shouldResume || !AVAudioSession.sharedInstance().isOtherAudioPlaying
        #else
        let resume = shouldResume
        #endif
        if resume {
            send(.play)
        }
    }

    // MARK: - Receive / Parse

    private nonisolated func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }

            if let data, !data.isEmpty {
                self.maxReceiveBytes = max(self.maxReceiveBytes, data.count)
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
            let remaining = pending[(pending.startIndex + pendingOffset)...]
            guard remaining.count >= AudioStreamProtocol.headerSize else { return }
            guard let parsed = AudioStreamHeader(parsing: remaining) else {
                fail("Invalid stream header — is the sender the Longwave Companion?")
                return
            }
            pendingOffset += AudioStreamProtocol.headerSize
            header = parsed
            arrivalStats = AudioArrivalStats(sampleRate: parsed.sampleRate)
            guard setupAudio(header: parsed) else {
                fail("Unsupported audio format (\(parsed.channelCount)ch @ \(parsed.sampleRate) Hz)")
                return
            }
            onEvent?(.connected(sampleRate: parsed.sampleRate, channels: parsed.channelCount))
            if lowLatency { openUDP() }
        }

        // Then typed, length-prefixed frames
        while true {
            let base = pending.startIndex + pendingOffset
            let remaining = pending[base...]
            guard let length = AudioStreamProtocol.decodeFrameLength(remaining) else { break }
            guard length >= 1, length <= AudioStreamProtocol.maxFrameBytes else {
                fail("Malformed frame (\(length) bytes)")
                return
            }
            let frameEnd = AudioStreamProtocol.frameLengthPrefixSize + Int(length)
            guard remaining.count >= frameEnd else { break }

            let type = pending[base + AudioStreamProtocol.frameLengthPrefixSize]
            let payload = pending.subdata(
                in: (base + AudioStreamProtocol.frameLengthPrefixSize + 1)..<(base + frameEnd)
            )
            pendingOffset += frameEnd

            switch AudioStreamProtocol.FrameType(rawValue: type) {
            case .pcm:
                receivePCM(payload)
            case .nowPlaying:
                // Malformed metadata is logged and skipped — never fail
                // the audio stream over it.
                if let info = NowPlayingInfo.decode(payload) {
                    onEvent?(.nowPlaying(info))
                } else {
                    AppLog.audioStream.line("Skipping malformed now-playing frame (\(payload.count) bytes)")
                }
            case .artwork:
                // Chunked as of protocol v7: a 1-byte continuation flag then
                // the chunk bytes. See AudioStreamProtocol for why artwork
                // can't be handed over in one piece.
                guard let final = payload.first else { break }
                artworkAssembly.append(payload.dropFirst())
                if artworkAssembly.count > AudioStreamProtocol.maxArtworkBytes {
                    AppLog.audioStream.line("Artwork exceeded \(AudioStreamProtocol.maxArtworkBytes) bytes — discarding")
                    artworkAssembly = Data()
                } else if final == 1 {
                    onEvent?(.artwork(artworkAssembly))
                    artworkAssembly = Data()
                }
            case .keepAlive:
                // Silence heartbeat from the sender (no PCM while quiet).
                // Refresh liveness so the health probe doesn't mistake a
                // quiet-but-live connection for a dead one.
                onEvent?(.bytesReceived(totalBytes))
            case .command, .udpHello, nil:
                break // not receiver-bound / unknown — skip
            }
        }
        compactPending()
    }

    /// Drops the already-parsed prefix of `pending`, but only when the copy
    /// buys something — otherwise the O(1) cursor is left to do its job.
    private nonisolated func compactPending() {
        guard pendingOffset > 0 else { return }
        if pendingOffset >= pending.count {
            pending.removeAll(keepingCapacity: true)
        } else if pendingOffset >= 64 * 1024 {
            pending = Data(pending[(pending.startIndex + pendingOffset)...])
        } else {
            return
        }
        pendingOffset = 0
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
        receivePCM(payload)
    }

    /// Entry point for a `pcm` payload from either transport: books its
    /// stamp, then schedules the samples behind it. A payload arriving behind
    /// audio that is already scheduled is dropped — playing it would put
    /// samples out of order, which is worse than the hole it would fill.
    private nonisolated func receivePCM(_ payload: Data) {
        guard let stamp = PCMStamp(parsing: payload) else { return }
        let samples = payload.dropFirst(PCMStamp.size)
        let bytesPerWireFrame = max(1, (header?.channelCount ?? 2) * AudioStreamProtocol.bytesPerSample)
        let disposition = arrivalStats?.record(
            stamp: stamp,
            frames: samples.count / bytesPerWireFrame,
            arrivalNanos: DispatchTime.now().uptimeNanoseconds
        )
        guard disposition != .late else { return }
        schedule(samples)
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
                // Restart with the normal jitter cushion. Anything still
                // queued from before the pause is stale, and its playback
                // completions must not count against the new cushion.
                resetPlayback()
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

        // Declare this receiver's mode once, and let the coordinator decide
        // what the process session should be — there may be several receivers
        // live at once and only one session between them. Re-asserting the
        // category mid-stream (e.g. while a VoIP call owns the voice channel)
        // yanks the system audio config out from under the other app — the
        // cause of "GMeet loses audio until speaker test" — so the
        // coordinator only touches it when the resolved answer changes.
        //
        // AVAudioEngine isn't a Now Playing candidate, so the per-app
        // Spatialize Stereo system setting doesn't apply here: the user's
        // `spatialAudioMode` toggle is this stream's only control over
        // head-tracked rendering vs flat bypass.
        if !sessionConfigured {
            sessionConfigured = true
            AudioSessionCoordinator.shared.join(
                self,
                mode: mode,
                spatialAudioMode: spatialAudioMode
            )
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

        // Every depth reading includes this: `.dataPlayedBack` fires only
        // once a buffer has made it all the way out, so the true lead over the
        // render thread is the reported depth minus the output latency. It is
        // what the `floor` in the health line has to be read against.
        let presentationMs = Int(engine.outputNode.presentationLatency * 1000)
        #if canImport(UIKit)
        AppLog.audioStream.line(
            "Output latency \(Int(session.outputLatency * 1000)) ms, IO buffer "
            + "\(Int(session.ioBufferDuration * 1000)) ms, output node \(presentationMs) ms"
        )
        #else
        AppLog.audioStream.line("Output node latency \(presentationMs) ms")
        #endif
        // Fresh node, fresh cushion. The target keeps any growth an earlier
        // underrun earned — a link that needed 140 ms before needs it now.
        playing = false
        depthAverage = 0
        trimming = false
        starvedSinceNanos = 0
        lastScheduleNanos = 0
        queueState.withLock { state in
            state.frames = 0
            state.generation &+= 1
        }

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
        // Invalidate any outstanding playback completions before the node
        // goes away, so a late callback can't decrement a rebuilt node's
        // depth into a spurious underrun.
        queueState.withLock { state in
            state.frames = 0
            state.generation &+= 1
        }
        playing = false
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

    // MARK: - Jitter cushion

    private nonisolated var wireSampleRate: Double { header?.sampleRate ?? 48_000 }

    /// Cushion we aim to keep queued on the player node, in sample frames.
    private nonisolated var targetFrames: Int {
        max(1, Int(targetBufferSeconds * wireSampleRate))
    }

    /// Hard ceiling. Past this the stream is running long — a TCP stall that
    /// cleared and dumped its backlog at once, or the sender's clock simply
    /// outpacing ours — and whole buffers are dropped until it's back in
    /// range. Single-sample drift correction sheds a half-second backlog far
    /// too slowly to be the only mechanism.
    private nonisolated var ceilingFrames: Int {
        max(targetFrames * 3, targetFrames + Int(0.150 * wireSampleRate))
    }

    /// Re-enters the prebuffer state after the node has run dry, *without*
    /// cutting it. Runs on `queue`.
    ///
    /// Deliberately `pause()`, not `stop()`. By the time this is called the
    /// node has already drained and is rendering silence, so pausing there is
    /// silence-to-silence and inaudible — whereas `stop()` halts mid-waveform
    /// and resets the timeline, so the gap acquires a step discontinuity at
    /// each end: two clicks bracketing every recovery. `pause()` also keeps
    /// the scheduled queue and its pending completions intact, so the depth
    /// counter stays valid and no generation bump is needed; buffers
    /// scheduled from here simply accumulate until the cushion is back.
    private nonisolated func rebuildCushion() {
        playerNode?.pause()
        playing = false
        depthAverage = 0
        trimming = false
        starvedSinceNanos = 0
    }

    /// Hard reset: stops the node, discards everything scheduled, and
    /// re-enters the prebuffer state. Bumps the queue generation so
    /// completion callbacks from the flushed buffers don't corrupt the new
    /// depth. For the cases where the queued audio is genuinely stale (local
    /// unpause, engine rebuild) rather than merely late. Runs on `queue`.
    private nonisolated func resetPlayback() {
        playerNode?.stop()
        playing = false
        depthAverage = 0
        trimming = false
        starvedSinceNanos = 0
        queueState.withLock { state in
            state.frames = 0
            state.generation &+= 1
        }
    }

    /// Periodic one-liner so a real-device session can be read back from the
    /// log: what the cushion is actually running at, and what it has cost.
    /// Also relaxes the target again after a clean stretch, so one rough
    /// patch early on doesn't cost latency for the rest of the session.
    private nonisolated func logBufferHealth(depth: Int, now: UInt64) {
        // First buffer of the session: start the window, don't report a
        // rate measured against an uptime-length interval.
        guard lastHealthLogNanos != 0 else {
            lastHealthLogNanos = now
            framesSinceHealthLog = 0
            maxArrivalGapNanos = 0
            _ = arrivalStats?.takeReport()
            return
        }
        let elapsed = Double(now &- lastHealthLogNanos) / 1_000_000_000
        guard elapsed > 10 else { return }
        lastHealthLogNanos = now

        underrunsAtLastHealthLog = underrunCount

        // Size the cushion from the stall the link actually produces. Rise
        // at once — an under-sized cushion is a dropout on the next stall —
        // and fall a step at a time, so one quiet interval can't undo what a
        // recurring stall demonstrated.
        let windowGapSeconds = Double(cushionableGapNanos) / 1_000_000_000
        observedStallSeconds = max(observedStallSeconds * Self.stallDecay, windowGapSeconds)
        let demanded = min(
            maxTargetBufferSeconds,
            max(baseTargetBufferSeconds, observedStallSeconds * Self.stallMargin)
        )
        // Converge on `demanded` proportionally rather than by a fixed step:
        // a target driven to its ceiling by one bad patch took minutes to
        // come back at 10 ms per interval, and that is all latency.
        targetBufferSeconds = demanded > targetBufferSeconds
            ? demanded
            : max(demanded, targetBufferSeconds - max(Self.bufferDecayStep, (targetBufferSeconds - demanded) * 0.25))

        // Effective input rate: wire frames delivered per second of *our*
        // wall clock. Against the nominal sample rate this is the one number
        // that says whether the sender is genuinely running fast (a rate
        // mismatch the drift loop should chase) or merely delivering the
        // right amount unevenly (a burst the cushion has to absorb) — the
        // two are indistinguishable in a depth reading alone.
        let inputRate = Double(framesSinceHealthLog) / elapsed
        let maxGapMs = maxArrivalGapNanos / 1_000_000
        let floor = minDepthFrames == Int.max ? 0 : minDepthFrames
        let biggestRead = maxReceiveBytes
        let net = arrivalStats?.takeReport() ?? AudioArrivalStats.Report()
        framesSinceHealthLog = 0
        maxArrivalGapNanos = 0
        cushionableGapNanos = 0
        minDepthFrames = Int.max
        maxReceiveBytes = 0

        let ms = { (frames: Double) in Int(frames / self.wireSampleRate * 1000) }
        // `late` is arrival delay above the window's best, against the media
        // clock — the lead the cushion needed to cover each payload. `holes`
        // are audio that never arrived; `ooo` payloads arrived behind their
        // successors and were dropped. Largest TCP read only means something
        // on TCP; a datagram is always one payload.
        let delays = [net.delayP50Ms, net.delayP95Ms, net.delayP99Ms, net.delayMaxMs]
            .map { String(Int($0.rounded())) }
            .joined(separator: "/")
        let transport = udpFramesReceived > 0 ? "" : "maxread \(biggestRead / 1024) KB · "
        let restarts = net.discontinuities > 0 ? " restarts=\(net.discontinuities)" : ""
        AppLog.audioStream.line(
            "Audio buffer: \(ms(Double(depth))) ms now, \(ms(depthAverage)) ms avg, "
            + "target \(Int(targetBufferSeconds * 1000)) ms · "
            + "floor \(ms(Double(floor))) ms · "
            + "in \(Int(inputRate)) Hz (nominal \(Int(wireSampleRate))) maxgap \(maxGapMs) ms · "
            + "late p50/95/99/max \(delays) ms · "
            + "holes=\(net.holes) (\(ms(Double(net.holeFrames))) ms) ooo=\(net.late) resumes=\(net.resumes)\(restarts) · "
            + transport
            + "underruns=\(underrunCount) trimmed=\(ms(Double(trimmedFrames)))ms drift=\(driftCorrections)"
        )
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
        let wireFrames = payload.count / bytesPerWireFrame
        guard wireFrames > 0 else { return }

        let nowNanos = DispatchTime.now().uptimeNanoseconds
        framesSinceHealthLog += wireFrames
        let gapNanos = lastScheduleNanos == 0 ? 0 : nowNanos &- lastScheduleNanos
        if gapNanos > 0 {
            maxArrivalGapNanos = max(maxArrivalGapNanos, gapNanos)
            if gapNanos <= Self.maxCushionableGapNanos {
                cushionableGapNanos = max(cushionableGapNanos, gapNanos)
            }
        }

        // The sender suppresses sustained silence, so a long absence is
        // expected rather than a fault: the node has drained and has to be
        // re-primed, but the link did nothing wrong and the cushion must not
        // grow because of it. Only genuinely long gaps qualify — the old
        // 200 ms threshold fired on ordinary stalls the cushion had already
        // absorbed, and each firing added a whole target of silence on top.
        if playing, gapNanos > Self.sourceSuppressionGapNanos {
            AppLog.audioStream.line(
                "Audio resumed after a \(gapNanos / 1_000_000) ms source gap — re-priming"
            )
            rebuildCushion()
        }
        lastScheduleNanos = nowNanos

        var depth = queueState.withLock { $0.frames }
        if playing { minDepthFrames = min(minDepthFrames, depth) }

        // Underrun: the node played everything and is rendering silence with
        // its clock still running.
        //
        // Ride it out rather than re-priming on the spot. A stall on this
        // link is always followed by a burst — a deficit window is invariably
        // followed by a surplus one, average rate exactly nominal — so the
        // cushion refills by itself. Pausing to re-prime instead *adds* the
        // whole target as silence on top of the outage, and when gaps arrive
        // back to back that stacking is what turned a bad patch into a large
        // dropout: seven re-primes in 3.4 s, each one paying 300-400 ms for a
        // gap of about the same length.
        //
        // The safety net is time, not the first sample: if the queue is still
        // empty after `starvationGraceNanos` the sender is not catching up,
        // and only then is a real re-prime worth its silence. That still
        // fixes the original fault, where the cushion was lost for good and
        // nothing ever rebuilt it.
        if playing, depth <= 0 {
            if starvedSinceNanos == 0 {
                starvedSinceNanos = nowNanos
                underrunCount += 1
                targetBufferSeconds = min(
                    maxTargetBufferSeconds,
                    max(targetBufferSeconds + Self.bufferGrowthFloor, targetBufferSeconds * Self.bufferGrowthFactor)
                )
                AppLog.audioStream.line(
                    "⚠️ Audio underrun #\(underrunCount) — riding out, target now \(Int(targetBufferSeconds * 1000)) ms"
                )
            } else if nowNanos &- starvedSinceNanos > Self.starvationGraceNanos {
                AppLog.audioStream.line(
                    "⚠️ Queue still empty after \((nowNanos &- starvedSinceNanos) / 1_000_000) ms — re-priming"
                )
                rebuildCushion()
            }
        } else if depth > 0 {
            starvedSinceNanos = 0
        }

        // Burst trim: bound the latency a recovered stall leaves behind.
        if playing, depth > ceilingFrames {
            if !trimming {
                trimming = true
                AppLog.audioStream.line(
                    "⚠️ Audio queue at \(Int(Double(depth) / wireSampleRate * 1000)) ms — trimming to target"
                )
            }
            trimmedFrames += wireFrames
            return
        }
        trimming = false

        // Drift correction. The Mac's capture clock and this device's output
        // clock are independent and differ by tens of ppm, which silently
        // eats (or inflates) the cushion over minutes — the reason a session
        // that starts clean develops dropouts with nothing else changing.
        // Nudge by a single sample frame per buffer: a ~20 µs discontinuity,
        // inaudible, and at ~100 buffers/s good for ~2000 ppm of correction,
        // orders of magnitude more than any real clock mismatch. The
        // *smoothed* depth is what's compared, so ordinary jitter never
        // triggers it.
        var adjust = 0
        if playing {
            depthAverage += (Double(depth) - depthAverage) * Self.depthSmoothing
            let target = Double(targetFrames)
            let tolerance = max(target * 0.2, 0.005 * wireSampleRate)
            buffersSinceDrift += 1
            if buffersSinceDrift >= Self.driftCorrectionInterval {
                if depthAverage > target + tolerance {
                    adjust = -1
                } else if depthAverage < target - tolerance {
                    adjust = 1
                }
                if adjust != 0 {
                    driftCorrections += 1
                    buffersSinceDrift = 0
                }
            }
        }

        let frameCount = AVAudioFrameCount(max(1, wireFrames + adjust))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        // Decode interleaved wire int24 → Float32, deinterleaving into the
        // engine's per-channel buffers.
        let outFrames = Int(frameCount)
        let sampleStride = AudioStreamProtocol.bytesPerSample
        payload.withUnsafeBytes { raw in
            guard let channelData = buffer.floatChannelData else { return }
            let bytes = raw.bindMemory(to: UInt8.self)
            guard adjust != 0 else {
                for channel in 0..<channels {
                    let out = channelData[channel]
                    for frame in 0..<outFrames {
                        out[frame] = PCM24.sample(bytes, at: (frame * channels + channel) * sampleStride)
                    }
                }
                return
            }
            // Applying the drift nudge by *resampling* the buffer, not by
            // dropping or repeating a sample frame.
            //
            // Dropping one sample is a step discontinuity whose height is the
            // adjacent-sample delta — on music that is a broadband click
            // around −20 dBFS, and fired once per buffer (~94/s while the
            // average sits outside the tolerance band) it is a buzz, not the
            // "inaudible 20 µs" it looks like on paper. Linear interpolation
            // spreads the same ±1 frame across the whole buffer instead: a
            // ~0.2% rate change lasting 10 ms. The endpoints still map to the
            // first and last input frames, so consecutive buffers join with
            // no discontinuity at the seam.
            let step = Double(wireFrames - 1) / Double(max(1, outFrames - 1))
            for channel in 0..<channels {
                let out = channelData[channel]
                for frame in 0..<outFrames {
                    let position = Double(frame) * step
                    let low = min(Int(position), wireFrames - 1)
                    let high = min(low + 1, wireFrames - 1)
                    let fraction = Float(position - Double(low))
                    let a = PCM24.sample(bytes, at: (low * channels + channel) * sampleStride)
                    let b = PCM24.sample(bytes, at: (high * channels + channel) * sampleStride)
                    out[frame] = a + (b - a) * fraction
                }
            }
        }

        // Exact-zero payload == a warm-keep silence frame from the sender
        // (it transmits silence for a few seconds across short gaps before
        // suppressing). Used below to gate the animated glyph. `contains`
        // early-exits, so real audio costs next to nothing.
        let isSilentFrame = !payload.contains { $0 != 0 }

        let scheduledCount = Int(frameCount)
        let generation = queueState.withLock { state -> Int in
            state.frames += scheduledCount
            return state.generation
        }
        // `.dataPlayedBack` is what makes the depth real: it fires when the
        // samples have actually been rendered, not when the node accepted
        // them. The generation check discards callbacks for buffers a
        // `resetPlayback` already flushed.
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [queueState] _ in
            queueState.withLock { state in
                guard state.generation == generation else { return }
                state.frames -= scheduledCount
            }
        }

        // Hold playback until the cushion has accumulated. Works for both
        // entry paths: before the first `play()` the node is stopped, and
        // after `rebuildCushion` it is paused — either way scheduled buffers
        // queue up instead of being consumed, and `play()` releases them.
        if !playing {
            let filled = queueState.withLock { $0.frames }
            if filled >= targetFrames {
                playing = true
                depthAverage = Double(filled)
                playerNode.play()
            }
        }

        // Drive the animated glyph off *actual sound*. The sender keeps the
        // stream warm with exact-silence frames across short gaps (so playback
        // doesn't glitch), so a zero-filled frame is silence — schedule it to
        // keep the node fed, but don't count it as activity. The manager's
        // watchdog then settles the animation shortly after sound stops.
        if !isSilentFrame, nowNanos &- lastAudioActivityNanos > 200_000_000 {
            lastAudioActivityNanos = nowNanos
            onEvent?(.audioActivity)
        }

        if nowNanos &- lastStatsNanos > 500_000_000 {
            lastStatsNanos = nowNanos
            onEvent?(.bytesReceived(totalBytes))
        }
        logBufferHealth(depth: depth, now: nowNanos)
    }
}
