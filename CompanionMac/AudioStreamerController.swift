import SwiftUI
import AppKit
import os

/// Orchestrates the system audio tap and the TCP stream server.
@Observable
final class AudioStreamerController {

    let port: UInt16 = AudioStreamProtocol.defaultPort
    let macNativeStreaming = MacNativeStreamingController()

    /// Remembers whether the user had streaming on, so the menu bar app
    /// resumes it automatically on the next launch (e.g. after login).
    private static let autoStartKey = "autoStartStreaming"

    init() {
        macNativeStreaming.configure(token: token)
        if UserDefaults.standard.bool(forKey: Self.autoStartKey) {
            // Defer past App init so it runs on the main actor's run loop —
            // starting the tap/server synchronously during init is too early.
            Task { @MainActor in self.start() }
        }
        // Bring the inject server up if the user previously enabled it
        // (independent of audio streaming).
        injection.onInject = { [weak self] in self?.flashInjection() }
        Task { @MainActor in self.updateInjectionServer() }
    }

    /// Persistent static auth token — clients must present it to connect.
    /// Loaded from (or generated into) UserDefaults on init; the didSet
    /// keeps the store in sync when regenerated.
    var token: String = AudioStreamerController.loadOrCreateToken() {
        didSet { UserDefaults.standard.set(token, forKey: "audioStreamToken") }
    }

    /// x-callback URL carrying the token, for AirDrop to the Vision Pro.
    var tokenShareURL: URL? {
        AudioTokenURL.make(token: token)
    }

    private static func loadOrCreateToken() -> String {
        if let existing = UserDefaults.standard.string(forKey: "audioStreamToken"), !existing.isEmpty {
            return existing
        }
        let generated = AudioToken.generate()
        UserDefaults.standard.set(generated, forKey: "audioStreamToken")
        return generated
    }

    /// Discards the current token and generates a fresh one. Any connected
    /// client is dropped (its old token no longer matches) and must re-pair.
    func regenerateToken() {
        token = AudioToken.generate()
        if isRunning { start() } // restart audio server with the new token
        if injection.injectionEnabled { startInjectServer() } // re-key inject channel
        macNativeStreaming.updateToken(token)
    }

    // MARK: - SSH authorized keys (remote control)

    /// VisionVNC-added keys currently in ~/.ssh/authorized_keys.
    var installedVisionKeys: [AuthorizedKey] = []
    var keyActionStatus: String?
    var macHostFingerprint: String?

    func refreshKeys() {
        installedVisionKeys = AuthorizedKeysManager.read().filter { $0.comment.contains("visionvnc") }
        if macHostFingerprint == nil {
            macHostFingerprint = AuthorizedKeysManager.macHostFingerprint()
        }
    }

    /// Reads a public key from the clipboard (Universal Clipboard from the
    /// Vision Pro), prompts for explicit approval, then installs it.
    func addKeyFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            keyActionStatus = "Clipboard is empty."
            return
        }
        guard let key = AuthorizedKeysManager.parse(raw) else {
            keyActionStatus = "Clipboard isn't an SSH public key."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Authorize this Vision Pro for SSH?"
        alert.informativeText = """
        \(key.type)
        \(key.fingerprint)\(key.comment.isEmpty ? "" : "\n\(key.comment)")

        Allowing adds it to ~/.ssh/authorized_keys, letting that device log in over SSH (key-based).
        """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            keyActionStatus = "Cancelled."
            return
        }
        do {
            try AuthorizedKeysManager.add(line: raw)
            refreshKeys()
            keyActionStatus = "Authorized \(key.fingerprint)."
        } catch {
            keyActionStatus = "Failed: \(error.localizedDescription)"
        }
    }

    func removeKey(_ key: AuthorizedKey) {
        do {
            try AuthorizedKeysManager.remove(base64: key.base64)
            refreshKeys()
            keyActionStatus = "Removed \(key.fingerprint)."
        } catch {
            keyActionStatus = "Failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Companion keyboard injection

    let injection = InjectionService()
    private var injectServer: CompanionInjectServer?

    /// Transient flag for the menu-bar activity glyph — true for ~2 s after the
    /// most recent injection so the user sees remote typing happening.
    private(set) var isInjecting = false
    private var injectResetTask: Task<Void, Never>?

    private func flashInjection() {
        isInjecting = true
        injectResetTask?.cancel()
        injectResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.isInjecting = false
        }
    }

    /// Master toggle, bridging `InjectionService` and (re)starting the inject
    /// server as it flips. Independent of audio streaming.
    var injectionEnabled: Bool {
        get { injection.injectionEnabled }
        set {
            injection.injectionEnabled = newValue
            updateInjectionServer()
        }
    }

    /// Re-checks Accessibility and starts/stops the inject server to match the
    /// master toggle. Safe to call repeatedly.
    func updateInjectionServer() {
        injection.refreshAccessibility()
        if injection.injectionEnabled {
            startInjectServer()
        } else {
            injectServer?.stop()
            injectServer = nil
        }
    }

    private func startInjectServer() {
        injectServer?.stop()
        let server = CompanionInjectServer(port: CompanionInjectProtocol.defaultPort, token: token)
        server.onInjectText = { [weak self] text in
            Task { @MainActor [weak self] in self?.injection.insertText(text) }
        }
        server.onInjectBackspace = { [weak self] count in
            Task { @MainActor [weak self] in self?.injection.deleteBackward(count) }
        }
        do {
            try server.start()
            server.setAvailability(injection.statusByte)
            injectServer = server
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Prompts for Accessibility, then refreshes the live channel's availability.
    func grantAccessibility() {
        injection.promptAccessibility()
        injectServer?.setAvailability(injection.statusByte)
    }

    var clientCount = 0
    var lastError: String?
    private(set) var streamFormat: SystemAudioTap.StreamFormat?
    private(set) var nowPlaying: NowPlayingInfo?

    private var tap: SystemAudioTap?
    private var server: AudioStreamServer?
    private var musicBridge: MusicAppBridge?
    /// Whether the tap is currently muting local Mac output.
    private var tapMuted = false
    /// Delays tearing down the tap after the last client leaves, so a Vision
    /// Pro reconnect (e.g. an audio-mode switch, which drops and reopens the
    /// connection) doesn't restart the tap — which would both blip Mac audio
    /// out the local output and re-trigger the system audio-capture indicator.
    private var pendingStopTapTask: Task<Void, Never>?

    /// True while the server is listening (streaming "on"). Independent of the
    /// tap: the system audio tap is created only while a client is connected
    /// (see `handleClientCountChange`), so an idle companion captures no audio
    /// and shows no system audio-recording indicator.
    private var serverRunning = false

    var isRunning: Bool {
        get { serverRunning }
        set {
            guard newValue != isRunning else { return }
            UserDefaults.standard.set(newValue, forKey: Self.autoStartKey)
            newValue ? start() : stop()
        }
    }

    var showTrackInMenuBar: Bool {
        get {
            access(keyPath: \.showTrackInMenuBar)
            return UserDefaults.standard.bool(forKey: "showTrackInMenuBar")
        }
        set {
            withMutation(keyPath: \.showTrackInMenuBar) {
                UserDefaults.standard.set(newValue, forKey: "showTrackInMenuBar")
            }
        }
    }

    /// "Artist – Title" for the menu bar label, or nil when the option is
    /// off, nothing is playing (paused hides it too), or metadata is missing.
    var menuBarTrackText: String? {
        guard showTrackInMenuBar,
              let nowPlaying, nowPlaying.hasTrack, nowPlaying.isPlaying else { return nil }
        let parts = [nowPlaying.artist, nowPlaying.title].compactMap { $0?.isEmpty == false ? $0 : nil }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " – ")
    }

    var muteWhileStreaming: Bool {
        get {
            access(keyPath: \.muteWhileStreaming)
            return UserDefaults.standard.object(forKey: "muteWhileStreaming") as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.muteWhileStreaming) {
                UserDefaults.standard.set(newValue, forKey: "muteWhileStreaming")
            }
            // The mute behavior is baked into the tap at creation — restart
            // the tap (only matters while a client is actually connected,
            // since the tap doesn't exist with no clients).
            if isRunning, clientCount > 0, tap != nil {
                restartTap(muted: newValue)
            }
        }
    }

    var statusText: String {
        guard isRunning else { return "Not streaming" }
        switch clientCount {
        case 0: return "Listening — waiting for VisionVNC to connect"
        default: return "Streaming to VisionVNC"
        }
    }

    var formatText: String {
        guard let format = streamFormat else { return "—" }
        return "\(format.channelCount)ch \(Int(format.sampleRate)) Hz int24"
    }

    func start() {
        stop()
        lastError = nil

        // Bring up the server and Music bridge only — no audio tap yet. The
        // tap is created lazily when a client connects (handleClientCountChange),
        // so an idle companion captures no system audio and shows no
        // audio-recording indicator.
        let server = AudioStreamServer(port: port, token: token)
        server.onClientCountChange = { [weak self] count in
            Task { @MainActor [weak self] in
                self?.handleClientCountChange(count)
            }
        }
        do {
            try server.start()
        } catch {
            lastError = error.localizedDescription
            return
        }

        // Music.app now-playing metadata + transport commands
        let bridge = MusicAppBridge()
        bridge.onNowPlaying = { [weak self] info, artwork in
            self?.handleNowPlaying(info, artwork: artwork)
        }
        server.onCommand = { [weak bridge] command in
            Task { @MainActor [weak bridge] in
                bridge?.send(command)
            }
        }
        bridge.start()

        self.server = server
        self.musicBridge = bridge
        serverRunning = true
    }

    private func handleClientCountChange(_ count: Int) {
        let previous = clientCount
        clientCount = count
        guard isRunning else { return }
        if previous == 0, count > 0 {
            // First client connected — cancel a pending teardown and start the
            // tap (muted per the user setting, since a listener is present).
            pendingStopTapTask?.cancel()
            pendingStopTapTask = nil
            if tap == nil { startTap(muted: muteWhileStreaming) }
        } else if previous > 0, count == 0 {
            // Last client left — tear down the tap (stops capturing and clears
            // the audio-recording indicator) after a short grace, so a quick
            // Vision Pro reconnect (e.g. an audio-mode switch) doesn't thrash
            // the tap or blip Mac audio out the local output.
            pendingStopTapTask?.cancel()
            pendingStopTapTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled,
                      self.isRunning, self.clientCount == 0 else { return }
                self.stopTap()
            }
        }
    }

    /// Creates the system audio tap and hands its format to the server as the
    /// stream header. Called when the first client connects.
    private func startTap(muted: Bool) {
        guard let server, isRunning, tap == nil else { return }
        let tap = SystemAudioTap()
        do {
            let format = try tap.start(muteSystemOutput: muted)
            streamFormat = format
            tapMuted = muted
            tap.onAudio = { [weak server] pcm in
                server?.broadcast(pcm)
            }
            server.provideHeader(AudioStreamHeader(sampleRate: format.sampleRate, channelCount: format.channelCount))
            self.tap = tap
        } catch {
            tap.stop()
            streamFormat = nil
            lastError = error.localizedDescription
        }
    }

    /// Stops and releases the tap (no more system audio capture). The server
    /// keeps listening; the tap is recreated when a client next connects.
    private func stopTap() {
        tap?.onAudio = nil
        tap?.stop()
        tap = nil
        tapMuted = false
        streamFormat = nil
    }

    /// Rebuilds the tap with the given mute behavior (it's baked in at
    /// creation time). Used when the mute setting flips mid-stream. The tap
    /// format doesn't change with mute behavior, so the connected client's
    /// already-sent header stays valid; if it somehow did change, restart
    /// everything so a reconnect resyncs.
    private func restartTap(muted: Bool) {
        guard isRunning, tap != nil else { return }
        let oldFormat = streamFormat
        stopTap()
        startTap(muted: muted)
        if let oldFormat, let new = streamFormat,
           new.sampleRate != oldFormat.sampleRate || new.channelCount != oldFormat.channelCount {
            start()
        }
    }

    func stop() {
        pendingStopTapTask?.cancel()
        pendingStopTapTask = nil
        stopTap()
        musicBridge?.stop()
        musicBridge = nil
        server?.stop()
        server = nil
        serverRunning = false
        clientCount = 0
        nowPlaying = nil
    }

    private func handleNowPlaying(_ info: NowPlayingInfo?, artwork: Data?) {
        nowPlaying = info
        let infoFrame = info?.encoded().map { AudioStreamProtocol.encodeFrame(.nowPlaying, $0) }
            ?? NowPlayingInfo(isPlaying: false).encoded().map { AudioStreamProtocol.encodeFrame(.nowPlaying, $0) }
        let artworkFrame = artwork.map { AudioStreamProtocol.encodeFrame(.artwork, $0) }
        server?.updateMetadata(infoFrame: infoFrame, artworkFrame: artworkFrame)
    }
}
