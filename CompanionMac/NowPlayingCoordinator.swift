import Foundation
import os

/// Single now-playing source for the rest of the companion, presenting the same
/// interface `MusicAppBridge` always did while choosing between two backends:
///
/// - `MediaRemoteBridge` — the system-wide Now Playing state, for every player,
///   with artwork that actually exists for Apple Music streaming.
/// - `MusicAppBridge` — AppleScript against Music.app. Sees only Music, and gets
///   no artwork bytes for streamed tracks, but uses nothing private.
///
/// MediaRemote wins whenever it has a track. The rule is deliberately about
/// *content* rather than a capability probe: with nothing playing anywhere, a
/// working-but-idle MediaRemote and a MediaRemote that Apple has broken look
/// exactly alike, and there is no way to tell them apart. Comparing what each
/// backend reports sidesteps the question — if MediaRemote goes dark while Music
/// is playing, Music.app's own answer is used and the user sees no difference.
final class NowPlayingCoordinator {

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "pro.longwave.companion",
        category: "NowPlaying"
    )

    /// Same contract as `MusicAppBridge.onNowPlaying`: nil info means nothing is
    /// playing, and nil artwork means the artwork is unchanged.
    var onNowPlaying: ((NowPlayingInfo?, Data?) -> Void)?

    private(set) var current: NowPlayingInfo?

    private let mediaRemote = MediaRemoteBridge()
    private let musicApp = MusicAppBridge()

    /// Which backend produced `current`. Transport commands follow it, so a
    /// pause sent while a browser owns Now Playing pauses the browser instead of
    /// starting Music.app.
    private enum Source { case mediaRemote, musicApp }
    private var activeSource: Source = .musicApp

    /// Latest snapshot from each backend, so a switch between them can be
    /// resolved without waiting for the next update.
    private var mediaRemoteInfo: NowPlayingInfo?
    private var musicAppInfo: NowPlayingInfo?
    /// Artwork already delivered downstream, so switching backends re-sends the
    /// image only when it genuinely differs.
    private var deliveredArtworkID: String?

    /// True while the system-wide source is working — surfaced for diagnostics.
    var isUsingSystemWideSource: Bool { mediaRemote.isAvailable }

    /// Bundle identifier of the app that owns Now Playing, when known.
    var sourceBundleID: String? {
        activeSource == .mediaRemote ? mediaRemote.sourceBundleID : "com.apple.Music"
    }

    // MARK: - Lifecycle

    func start() {
        mediaRemote.onNowPlaying = { [weak self] info, artwork in
            self?.handle(info, artwork: artwork, from: .mediaRemote)
        }
        mediaRemote.onAvailabilityChange = { [weak self] available in
            Self.log.log("system-wide now playing \(available ? "available" : "unavailable", privacy: .public)")
            self?.resolve(artwork: nil, preferring: available ? .mediaRemote : .musicApp)
        }
        musicApp.onNowPlaying = { [weak self] info, artwork in
            self?.handle(info, artwork: artwork, from: .musicApp)
        }

        // Both run at once. MusicAppBridge is event-driven off a distributed
        // notification and costs nothing while idle, so keeping it warm means a
        // MediaRemote failure is covered instantly rather than after a restart.
        mediaRemote.start()
        musicApp.start()
    }

    func stop() {
        mediaRemote.stop()
        musicApp.stop()
        current = nil
        mediaRemoteInfo = nil
        musicAppInfo = nil
        deliveredArtworkID = nil
    }

    /// Routes a transport command to whichever backend is currently in charge.
    func send(_ command: MediaCommand) {
        if activeSource == .mediaRemote, mediaRemote.send(command) { return }
        musicApp.send(command)
    }

    // MARK: - Arbitration

    private func handle(_ info: NowPlayingInfo?, artwork: Data?, from source: Source) {
        switch source {
        case .mediaRemote: mediaRemoteInfo = info
        case .musicApp: musicAppInfo = info
        }
        resolve(artwork: artwork, preferring: source)
    }

    /// Picks the snapshot to publish. `artwork` belongs to `preferring`, and is
    /// forwarded only if that backend is the one that wins.
    private func resolve(artwork: Data?, preferring source: Source) {
        let winner: Source
        if mediaRemote.isAvailable, mediaRemoteInfo?.hasTrack == true {
            winner = .mediaRemote
        } else if musicAppInfo?.hasTrack == true {
            winner = .musicApp
        } else {
            // Nothing anywhere: stay on whichever source is more trustworthy so
            // the next update doesn't look like a source change.
            winner = mediaRemote.isAvailable ? .mediaRemote : .musicApp
        }

        if winner != activeSource {
            Self.log.log("now-playing source → \(String(describing: winner), privacy: .public)")
            activeSource = winner
        }

        let info = winner == .mediaRemote ? mediaRemoteInfo : musicAppInfo
        var outgoingArtwork = source == winner ? artwork : nil

        // Backend switches arrive without artwork, so re-request nothing and
        // instead let the receiver keep using the cached image when the id is
        // unchanged. When the id *did* change we must not claim an artwork we
        // aren't sending.
        if let artworkID = info?.artworkID, artworkID != deliveredArtworkID,
           outgoingArtwork == nil {
            var stripped = info
            stripped?.artworkID = nil
            publish(stripped, artwork: nil)
            return
        }

        if outgoingArtwork != nil { deliveredArtworkID = info?.artworkID }
        if info?.hasTrack != true { deliveredArtworkID = nil; outgoingArtwork = nil }
        publish(info, artwork: outgoingArtwork)
    }

    private func publish(_ info: NowPlayingInfo?, artwork: Data?) {
        // Suppress no-op republishes, but never swallow an artwork delivery.
        if artwork == nil, info == current { return }
        current = info
        onNowPlaying?(info, artwork)
    }
}
