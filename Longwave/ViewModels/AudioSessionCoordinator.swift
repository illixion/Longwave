#if canImport(UIKit)
import AVFoundation
import Foundation
import os

/// Process-wide owner of the app's one `AVAudioSession`.
///
/// Several audio receivers can be live at once — one per Native session — but
/// the session category is a single setting for the whole process, so whoever
/// called `setCategory` last would win. A second Speaker stream starting up
/// would quietly drop a running Music stream's exclusive session (and with it
/// the ducking and the Now Playing behaviour that mode exists for), and a
/// Music stream starting up would take the mixable option away from every
/// Speaker stream already playing.
///
/// So nothing configures the session directly. Every live receiver declares
/// its mode here and this resolves the whole set: one Music participant means
/// an exclusive session, otherwise mixable. The category is re-asserted only
/// when that answer actually changes — re-asserting it mid-stream yanks the
/// audio config out from under whatever else holds it (the cause of the old
/// "a call drops the stream's audio until a speaker test" bug).
/// `nonisolated` because every caller is a receiver running on its own queue,
/// never the main actor.
nonisolated final class AudioSessionCoordinator: @unchecked Sendable {
    static let shared = AudioSessionCoordinator()

    private let lock = NSLock()
    /// The same category `AppLog.audioStream` uses, so these land beside the
    /// receiver's own lines in the in-app console — but constructed here,
    /// because `AppLog`'s statics are main-actor isolated and this is not.
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "pro.longwave",
        category: "AudioStream"
    )
    /// Every receiver currently holding a configured session, by mode.
    private var participants: [ObjectIdentifier: AudioMode] = [:]
    /// The options last applied, or nil when nothing has been configured yet
    /// (no participants, or the system reset media services under us).
    private var appliedOptions: AVAudioSession.CategoryOptions?

    private init() {}

    /// Declares one receiver's mode and brings the process session in line
    /// with the whole set. Returns false only when the category could not be
    /// set at all.
    @discardableResult
    func join(
        _ participant: AnyObject,
        mode: AudioMode,
        spatialAudioMode: SpatialAudioMode
    ) -> Bool {
        lock.lock()
        participants[ObjectIdentifier(participant)] = mode
        let options = Self.resolve(participants)
        let changed = appliedOptions != options
        appliedOptions = options
        lock.unlock()

        let session = AVAudioSession.sharedInstance()
        var configured = true
        if changed {
            do {
                try session.setCategory(.playback, mode: .default, options: options)
            } catch {
                log.log("Failed to configure audio session: \(error, privacy: .public)")
                configured = false
            }
        }
        applySessionTraits(spatialAudioMode: spatialAudioMode, options: options)
        return configured
    }

    /// Drops a receiver that has stopped. The remaining participants get the
    /// category their set now resolves to — in particular, Speaker streams
    /// left behind by a departing Music stream get the mixable option back,
    /// or they would keep ducking everything else on the device.
    func leave(_ participant: AnyObject) {
        lock.lock()
        guard participants.removeValue(forKey: ObjectIdentifier(participant)) != nil else {
            lock.unlock()
            return
        }
        let wasExclusive = appliedOptions == []
        let remaining = participants
        let options = Self.resolve(remaining)
        let changed = !remaining.isEmpty && appliedOptions != options
        appliedOptions = remaining.isEmpty ? nil : options
        lock.unlock()

        let session = AVAudioSession.sharedInstance()
        guard !remaining.isEmpty else {
            // Nothing is playing any more. Hand the session back so other apps
            // resume — but only if it was the exclusive one that interrupted
            // them in the first place.
            if wasExclusive {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            return
        }
        guard changed else { return }
        do {
            try session.setCategory(.playback, mode: .default, options: options)
        } catch {
            log.log("Failed to re-configure audio session: \(error, privacy: .public)")
        }
        applySessionTraits(spatialAudioMode: nil, options: options)
    }

    /// The system wiped the session out from under us (media services reset).
    /// Forgetting what we applied makes the next `join` re-assert it.
    func forgetAppliedState() {
        lock.lock()
        appliedOptions = nil
        lock.unlock()
    }

    /// Exclusive as soon as anyone is in Music mode; mixable otherwise.
    private static func resolve(
        _ participants: [ObjectIdentifier: AudioMode]
    ) -> AVAudioSession.CategoryOptions {
        participants.values.contains(.music) ? [] : [.mixWithOthers]
    }

    /// The two visionOS-only session traits that ride along with the category.
    /// Both are process-wide, so like the category they describe the resolved
    /// set rather than any one participant.
    private func applySessionTraits(
        spatialAudioMode: SpatialAudioMode?,
        options: AVAudioSession.CategoryOptions
    ) {
        // Both calls are visionOS-only, and neither has an iOS counterpart
        // that is needed: iOS does not route AVAudioEngine output through
        // AutomaticSpatialAudio, so there is no intended experience to
        // declare, and Now Playing candidacy is a visionOS notion about
        // windows the wearer has looked away from. iOS ducking follows the
        // category alone.
        #if os(visionOS)
        let session = AVAudioSession.sharedInstance()
        // `.auto` states no opinion at all, so the call is skipped rather
        // than passed a "default" the API doesn't have.
        if let experience = spatialAudioMode?.avSpatialExperience {
            try? session.setIntendedSpatialExperience(experience)
        }
        // A mixable session keeps running (un-ducked) when the user looks at
        // other windows only if it says it wants to. An exclusive Music
        // session is a real Now Playing app via `MPNowPlayingInfoCenter` and
        // doesn't need this.
        try? session.setIsNowPlayingCandidate(options.contains(.mixWithOthers))
        #endif
    }
}
#endif
