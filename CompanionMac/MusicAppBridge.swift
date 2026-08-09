import AppKit
import os

/// Tracks Music.app playback state and provides transport control, using
/// only public APIs:
///
/// - `DistributedNotificationCenter` `com.apple.Music.playerInfo` for
///   event-driven track/state changes (zero idle cost, no polling).
/// - `NSAppleScript` one-shots for artwork, player position, and transport
///   commands (~10–50 ms on the main thread — fine for a menu bar app).
///
/// Every AppleScript call is guarded by an `NSRunningApplication` check:
/// `tell application "Music"` would otherwise launch Music.
final class MusicAppBridge {

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "pro.longwave.companion",
        category: "MusicBridge"
    )
    private static let musicBundleID = "com.apple.Music"
    /// Artwork is scaled down before streaming (longest side, points).
    private static let maxArtworkDimension: CGFloat = 600

    /// Fires on the main actor with the new state and, when the track
    /// changed, freshly scaled artwork JPEG data (nil = artwork unchanged).
    /// Info is nil when nothing is playing / Music quit.
    var onNowPlaying: ((NowPlayingInfo?, Data?) -> Void)?

    private(set) var current: NowPlayingInfo?

    private var observer: (any NSObjectProtocol)?
    /// Persistent ID of the track whose artwork was last sent.
    private var lastArtworkTrackID: String?

    private var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).isEmpty
    }

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Already delivered on the main queue; hop to satisfy isolation.
            let userInfo = notification.userInfo.map { dict in
                dict.reduce(into: [String: Any]()) { $0["\($1.key)"] = $1.value }
            }
            Task { @MainActor in
                self?.handlePlayerInfo(userInfo)
            }
        }

        // Seed initial state if Music is already running and playing.
        if isMusicRunning {
            refreshFromAppleScript()
        }
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
        current = nil
        lastArtworkTrackID = nil
    }

    /// Sends a transport command to Music. No-op if Music isn't running
    /// (never launches it).
    func send(_ command: MediaCommand) {
        guard isMusicRunning else { return }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        _ = runAppleScript("tell application \"Music\" to \(verb)")
    }

    // MARK: - Notification handling

    private func handlePlayerInfo(_ userInfo: [String: Any]?) {
        guard let userInfo else { return }
        let state = userInfo["Player State"] as? String

        if state == "Stopped" || state == nil {
            publishCleared()
            return
        }

        let trackID = (userInfo["PersistentID"] as? NSNumber).map { String($0.int64Value) }
            ?? (userInfo["PersistentID"] as? String)
        let durationMs = (userInfo["Total Time"] as? NSNumber)?.doubleValue

        var info = NowPlayingInfo(
            title: userInfo["Name"] as? String,
            artist: userInfo["Artist"] as? String,
            album: userInfo["Album"] as? String,
            isPlaying: state == "Playing",
            durationSeconds: durationMs.map { $0 / 1000 },
            elapsedSeconds: fetchPlayerPosition(),
            artworkID: trackID
        )

        var artwork: Data?
        if let trackID, trackID != lastArtworkTrackID {
            artwork = fetchArtwork()
            lastArtworkTrackID = trackID
            if artwork == nil {
                info.artworkID = nil
            }
        }

        publish(info, artwork: artwork)
    }

    /// Initial state fetch for when the bridge starts while Music is
    /// already playing (no notification to seed from).
    private func refreshFromAppleScript() {
        guard isMusicRunning else { return }
        let script = """
        tell application "Music"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & "\n" & (name of t) & "\n" & (artist of t) & "\n" & (album of t) & "\n" & (duration of t as text) & "\n" & (player position as text) & "\n" & (persistent ID of t)
        end tell
        """
        guard let result = runAppleScript(script)?.stringValue, result != "stopped" else {
            publishCleared()
            return
        }
        let parts = result.components(separatedBy: "\n")
        guard parts.count >= 7 else { return }

        let trackID = parts[6]
        let info = NowPlayingInfo(
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            isPlaying: parts[0] == "playing",
            durationSeconds: Double(parts[4].replacingOccurrences(of: ",", with: ".")),
            elapsedSeconds: Double(parts[5].replacingOccurrences(of: ",", with: ".")),
            artworkID: trackID
        )
        let artwork = fetchArtwork()
        lastArtworkTrackID = trackID
        publish(artwork == nil ? withoutArtworkID(info) : info, artwork: artwork)
    }

    private func withoutArtworkID(_ info: NowPlayingInfo) -> NowPlayingInfo {
        var copy = info
        copy.artworkID = nil
        return copy
    }

    private func publish(_ info: NowPlayingInfo, artwork: Data?) {
        current = info
        onNowPlaying?(info, artwork)
    }

    private func publishCleared() {
        guard current != nil else { return }
        current = nil
        lastArtworkTrackID = nil
        onNowPlaying?(nil, nil)
    }

    // MARK: - AppleScript helpers

    private func fetchPlayerPosition() -> Double? {
        guard isMusicRunning,
              let descriptor = runAppleScript("tell application \"Music\" to return player position")
        else { return nil }
        let position = descriptor.doubleValue
        return position.isFinite && position >= 0 ? position : nil
    }

    /// Fetches the current track's artwork and re-encodes it as a scaled
    /// JPEG suitable for streaming (≤600 px, ~0.8 quality).
    private func fetchArtwork() -> Data? {
        guard isMusicRunning,
              let descriptor = runAppleScript(
                "tell application \"Music\" to return data of artwork 1 of current track"
              )
        else { return nil }
        let raw = descriptor.data
        guard !raw.isEmpty, let image = NSImage(data: raw) else { return nil }
        return scaledJPEG(image)
    }

    private func scaledJPEG(_ image: NSImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, Self.maxArtworkDimension / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Self.log.log("AppleScript error: \(String(describing: error), privacy: .public)")
            return nil
        }
        return result
    }
}
