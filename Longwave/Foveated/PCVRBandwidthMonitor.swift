//  PCVRBandwidthMonitor.swift
//
//  A monthly data cap for whichever PC is on the other end — set up once on a
//  metered host (a rented cloud GPU) and left off on a LAN one, since each
//  host measures and persists its own counter (see cb_bandwidth_t). The
//  headset never caches a number by hostname; it only ever mirrors whatever
//  the connected host currently reports.
//
//  That host-side persistence is exactly what makes this different from
//  PCVRSessionLimiter, which this otherwise mirrors closely: the trial clock
//  resets every session, so "the limit is reached" only ever needs to be true
//  once. The bandwidth counter is monthly, so its WARNING/STOP flags stay set
//  for the rest of the month once crossed — including across every reconnect
//  made specifically to fix it. Treating that as level state to *display* and
//  edge state to *act on* is the whole design here; conflating the two turns
//  the one place you can raise the limit or hit reset into something that
//  kills your connection before you can reach it.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import os

@Observable
final class PCVRBandwidthMonitor {

    enum BannerKind: Equatable {
        case warning
        case stop
    }

    /// How long each banner stays up before fading itself out. Matches
    /// `PCVRSessionLimiter.bannerDuration` — same read-at-a-glance reasoning.
    static let bannerDuration: TimeInterval = 25

    /// This calendar month's usage, straight from the host. Nil until a packet arrives,
    /// or once monitoring is off — the panel treats both the same way.
    private(set) var usedGB: Double?
    private(set) var warningThresholdGB: Double?
    private(set) var stopThresholdGB: Double?
    /// Level state: true for the rest of the month once the host reports the cap
    /// crossed, whether or not THIS session is the one that crossed it. This is what
    /// the panel reads to show "cap reached" — it must never depend on `bannerKind`,
    /// which clears itself after `bannerDuration` regardless of the underlying state.
    private(set) var isOverStopThreshold = false

    /// Drives the in-space banner. Set once per session per kind, cleared on a timer —
    /// never re-derived from `isOverStopThreshold` directly, or it would stay lit for
    /// the rest of the month instead of announcing the crossing and stepping aside.
    private(set) var bannerKind: BannerKind?
    /// Raised once when a session was ended by a fresh in-session crossing, so the
    /// PCVR tab can say why. Never raised for a session that was already over the cap
    /// when it connected — see `advance`.
    var didEndSession = false

    private var hasSeenNonStopThisSession = false
    /// Edge-tracking, not a one-shot latch: a mid-session Reset can legitimately drop
    /// usage back under a threshold and have it climb past it again in the same
    /// session, and that second crossing must fire too. A flag that only ever goes
    /// false→true and never back would miss it — these track the *previous tick's*
    /// flag state so a fresh crossing is always "false last tick, true this tick".
    private var previousWarningFlag = false
    private var previousStopFlag = false
    private var bannerClearAt: TimeInterval?
    private var stopInFlight = false
    private var task: Task<Void, Never>?
    private let log = Logger(subsystem: "pro.longwave", category: "PCVRBandwidth")

    /// Starts the 1 Hz supervisor. Same reasoning as `PCVRSessionLimiter.start`: owned
    /// by the app, not a view, so switching tabs never pauses the clock.
    func start(manager: FoveatedConnectionManager) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(manager: manager)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: Clock

    private func tick(manager: FoveatedConnectionManager) {
        let shouldEnd = advance(disconnected: manager.isDisconnected,
                                 bandwidth: manager.controllerBridge?.bandwidth,
                                 now: ProcessInfo.processInfo.systemUptime)
        if shouldEnd { endSession(manager: manager) }
    }

    /// The whole state machine, with the packet passed in rather than read from the
    /// bridge — same reason `PCVRSessionLimiter.advance` takes plain booleans: a test
    /// can step through a whole month of crossings in microseconds. Returns true only
    /// on the tick a FRESH in-session crossing should end the stream.
    @discardableResult
    func advance(disconnected: Bool, bandwidth: ControllerBridgeBandwidth?, now: TimeInterval) -> Bool {
        if disconnected {
            reset()
            return false
        }

        guard let bandwidth, bandwidth.flags.contains(.enabled) else {
            usedGB = nil
            warningThresholdGB = nil
            stopThresholdGB = nil
            isOverStopThreshold = false
            return false
        }

        usedGB = Double(bandwidth.usedGB)
        warningThresholdGB = Double(bandwidth.warningThresholdGB)
        stopThresholdGB = Double(bandwidth.stopThresholdGB)
        isOverStopThreshold = bandwidth.flags.contains(.stop)

        if let clearAt = bannerClearAt, now >= clearAt {
            bannerClearAt = nil
            bannerKind = nil
        }

        var shouldEndSession = false
        if bandwidth.flags.contains(.stop) {
            if hasSeenNonStopThisSession && !previousStopFlag {
                // A genuine crossing during THIS session — not "was already over when
                // we connected", which is left alone so the panel stays reachable.
                bannerKind = .stop
                bannerClearAt = now + Self.bannerDuration
                log.info("Bandwidth stop threshold crossed this session")
                shouldEndSession = true
            }
            previousStopFlag = true
        } else {
            hasSeenNonStopThisSession = true
            previousStopFlag = false
            if bandwidth.flags.contains(.warning) {
                if !previousWarningFlag {
                    bannerKind = .warning
                    bannerClearAt = now + Self.bannerDuration
                    log.info("Bandwidth warning threshold crossed this session")
                }
                previousWarningFlag = true
            } else {
                previousWarningFlag = false
            }
        }

        return shouldEndSession
    }

    private func reset() {
        usedGB = nil
        warningThresholdGB = nil
        stopThresholdGB = nil
        isOverStopThreshold = false
        bannerKind = nil
        bannerClearAt = nil
        hasSeenNonStopThisSession = false
        previousWarningFlag = false
        previousStopFlag = false
        stopInFlight = false
    }

    // MARK: Cutoff

    /// Stop the game first, then the stream — identical ordering to, and for the same
    /// reason as, `PCVRSessionLimiter.endSession`: the other order leaves a cloud
    /// instance rendering and encoding for a headset that already left, which for a
    /// bandwidth cap is exactly the stranded-cost scenario the feature exists to avoid.
    ///
    /// Deliberately does NOT clear `bannerKind` here — `advance()` just set it to
    /// `.stop` on this same tick, and it should stay up through the ~2s wind-down
    /// below rather than vanish the instant the cutoff starts. `reset()` clears it
    /// naturally once `disconnect()` completes and the next tick observes it.
    private func endSession(manager: FoveatedConnectionManager) {
        guard !stopInFlight else { return }
        stopInFlight = true
        log.info("Bandwidth stop threshold reached; ending session")

        let bridge = manager.controllerBridge
        Task { @MainActor in
            if bridge?.activeGame != nil {
                bridge?.requestStopActiveClient()
                try? await Task.sleep(for: .seconds(2))
            }
            await manager.disconnect()
            self.didEndSession = true
        }
    }
}
#endif
