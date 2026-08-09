//  PCVRSessionLimiter.swift
//
//  The trial condition for PCVR: play as often as you like, but a session ends
//  after twenty minutes. Nothing is locked, nothing is watermarked, no feature
//  is withheld — the whole product works, in twenty-minute pieces, until it is
//  bought (see PCVRStore).
//
//  Two rules make that fair rather than merely limited:
//
//  - Only time actually streaming counts. Pausing, or stepping out of the
//    immersive space, stops the clock — otherwise closing the space to answer a
//    message would quietly spend the trial. It stops it rather than rewinding
//    it: the clock only goes back to twenty minutes when the session ends.
//  - The cut is announced before it happens, twice, so it is never a surprise
//    mid-fight. Announcing it is the point; a silent cut reads as a crash.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import os

@Observable
final class PCVRSessionLimiter {

    /// How long one unpaid session may stream.
    static let sessionLimit: TimeInterval = 20 * 60
    /// Remaining-time marks that raise the banner, longest first. Five minutes
    /// is the headline warning; the one-minute repeat exists because a banner
    /// that appeared and vanished four minutes ago is not a warning any more.
    static let warningMarks: [TimeInterval] = [5 * 60, 60]
    /// How long each banner stays up before fading itself out.
    static let bannerDuration: TimeInterval = 25

    /// Streaming time spent in the current session.
    private(set) var elapsed: TimeInterval = 0
    /// Nil when the limit does not apply — unlocked, or not streaming.
    private(set) var remaining: TimeInterval?
    /// Drives the in-space banner. Set at a warning mark, cleared on a timer.
    private(set) var bannerRemaining: TimeInterval?
    /// Raised once when a session was ended by the limit, so the PCVR tab can
    /// say why rather than leaving the user to guess at a stream that stopped.
    var didEndSession = false

    private var marksFired: Set<Int> = []
    private var bannerClearAt: TimeInterval?
    private var lastTickAt: TimeInterval?
    private var cutoffInFlight = false
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "pro.longwave", category: "PCVRTrial")

    /// Starts the 1 Hz supervisor. Called once, from the app, and left running:
    /// a timer that only exists while some view is on screen would stop counting
    /// the moment the user switched tabs.
    func start(manager: FoveatedConnectionManager, store: PCVRStore) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(manager: manager, store: store)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: Clock

    private func tick(manager: FoveatedConnectionManager, store: PCVRStore) {
        let reachedLimit = advance(disconnected: manager.isDisconnected,
                                   streaming: manager.isStreaming,
                                   trial: store.isTrial,
                                   now: ProcessInfo.processInfo.systemUptime)
        if reachedLimit { endSession(manager: manager) }
    }

    /// The whole clock, with the session state passed in as plain booleans rather
    /// than read from a manager — which is what makes twenty minutes of trial
    /// something a test can step through in microseconds. Returns true on the
    /// tick the limit is reached.
    @discardableResult
    func advance(disconnected: Bool, streaming: Bool, trial: Bool, now: TimeInterval) -> Bool {
        let previous = lastTickAt
        lastTickAt = now

        // Session over or not yet begun: reset, so the next one starts from a full
        // twenty minutes.
        if disconnected {
            reset()
            return false
        }

        // Connected but not streaming — paused, pausing, resuming, on the way
        // down. Hold the clock where it is. Note *hold*, not reset: pausing must
        // not refund the minutes already played, or pausing every nineteen
        // minutes would be an unlimited session with extra steps.
        guard streaming else { return false }

        // A paying customer, or an answer StoreKit has not given yet. Never run
        // the clock on an unresolved entitlement: the wrong guess here ends a
        // paid session early.
        guard trial else {
            remaining = nil
            bannerRemaining = nil
            return false
        }

        // Measure the real gap rather than assuming one second, so a stalled or
        // throttled tick does not undercount the session.
        if let previous {
            let delta = now - previous
            // A jump this large means the app was suspended, not that the user
            // streamed through it. Charge a nominal second and move on.
            elapsed += (delta > 0 && delta < 10) ? delta : 1
        }

        let left = max(0, Self.sessionLimit - elapsed)
        remaining = left

        if let clearAt = bannerClearAt, now >= clearAt {
            bannerClearAt = nil
            bannerRemaining = nil
        }

        for mark in Self.warningMarks where left <= mark && !marksFired.contains(Int(mark)) {
            marksFired.insert(Int(mark))
            bannerRemaining = left
            bannerClearAt = now + Self.bannerDuration
            log.info("PCVR trial warning at \(Int(left))s remaining")
            break
        }

        return left <= 0
    }

    private func reset() {
        elapsed = 0
        remaining = nil
        bannerRemaining = nil
        bannerClearAt = nil
        marksFired.removeAll()
        cutoffInFlight = false
    }

    // MARK: Cutoff

    /// Stop the game first, then the stream. The other order leaves the title
    /// running blind on the PC — still holding the GPU, still in a session the
    /// user can no longer see — and the host has no idea the headset left.
    private func endSession(manager: FoveatedConnectionManager) {
        guard !cutoffInFlight else { return }
        cutoffInFlight = true
        log.info("PCVR trial limit reached; ending session")
        bannerRemaining = nil
        bannerClearAt = nil

        let bridge = manager.controllerBridge
        Task { @MainActor in
            if bridge?.activeGame != nil {
                bridge?.requestStopActiveClient()
                // Enough for the host to act on it before the channel goes away;
                // the stop is a request over the bridge, not a synchronous call.
                try? await Task.sleep(for: .seconds(2))
            }
            await manager.disconnect()
            self.didEndSession = true
        }
    }

    // MARK: Formatting

    /// mm:ss, for a banner that is read at a glance mid-game.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
