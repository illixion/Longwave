#if canImport(UIKit)
import AVFoundation
import DebugTrace
import Foundation

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
    /// The receiver's own category, so these land beside its lines.
    private let log = AppLog.audioStream
    /// Every receiver currently holding a configured session, by mode.
    private var participants: [ObjectIdentifier: AudioMode] = [:]
    /// Everything currently capturing the microphone (`MicrophoneUplink`).
    /// Any one of them turns the category into `.playAndRecord`; the options
    /// still come from the receivers, so a mixable session stays mixable.
    private var recorders: Set<ObjectIdentifier> = []
    /// The category and options last applied, or nil when nothing has been
    /// configured yet (no participants, or the system reset media services
    /// under us).
    private var applied: Resolved?

    private struct Resolved: Equatable {
        var category: AVAudioSession.Category
        var options: AVAudioSession.CategoryOptions
    }

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
        let resolved = resolveLocked()
        let changed = applied != resolved
        applied = resolved
        lock.unlock()

        var configured = true
        if changed {
            configured = apply(resolved)
        }
        applySessionTraits(spatialAudioMode: spatialAudioMode, options: resolved.options)
        return configured
    }

    /// Starts a microphone capture. The session moves to `.playAndRecord`
    /// (keeping whatever mixability the receivers resolve to) and is
    /// activated. Returns false when the category could not be set.
    @discardableResult
    func beginRecording(_ recorder: AnyObject) -> Bool {
        lock.lock()
        recorders.insert(ObjectIdentifier(recorder))
        let resolved = resolveLocked()
        let changed = applied != resolved
        applied = resolved
        lock.unlock()

        if changed, !apply(resolved) { return false }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.log("Failed to activate the audio session for recording: \(error)")
            return false
        }
        return true
    }

    func endRecording(_ recorder: AnyObject) {
        lock.lock()
        guard recorders.remove(ObjectIdentifier(recorder)) != nil else {
            lock.unlock()
            return
        }
        let idle = participants.isEmpty && recorders.isEmpty
        let resolved = resolveLocked()
        let changed = !idle && applied != resolved
        applied = idle ? nil : resolved
        lock.unlock()

        if changed {
            apply(resolved)
            applySessionTraits(spatialAudioMode: nil, options: resolved.options)
        }
    }

    /// True while something is capturing the microphone — other code that
    /// borrows the session (dictation) must not hand it back as `.playback`.
    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !recorders.isEmpty
    }

    @discardableResult
    private func apply(_ resolved: Resolved) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(resolved.category, mode: .default, options: resolved.options)
            return true
        } catch {
            log.log("Failed to configure audio session (\(resolved.category.rawValue, privacy: .public)): \(error)")
            return false
        }
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
        let wasExclusive = applied?.options == []
        let idle = participants.isEmpty && recorders.isEmpty
        let resolved = resolveLocked()
        let changed = !idle && applied != resolved
        applied = idle ? nil : resolved
        lock.unlock()

        guard !idle else {
            // Nothing is playing or recording any more. Hand the session back
            // so other apps resume — but only if it was the exclusive one that
            // interrupted them in the first place.
            if wasExclusive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            return
        }
        guard changed else { return }
        apply(resolved)
        applySessionTraits(spatialAudioMode: nil, options: resolved.options)
    }

    /// The system wiped the session out from under us (media services reset).
    /// Forgetting what we applied makes the next `join` re-assert it.
    func forgetAppliedState() {
        lock.lock()
        applied = nil
        lock.unlock()
    }

    /// Exclusive as soon as anyone is in Music mode; mixable otherwise.
    /// Recording adds the input and nothing else, so a microphone sent to the
    /// Mac coexists with a call in another app just as playback does.
    /// Under `lock`.
    private func resolveLocked() -> Resolved {
        Resolved(
            category: recorders.isEmpty ? .playback : .playAndRecord,
            options: participants.values.contains(.music) ? [] : [.mixWithOthers]
        )
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
