//  FoveatedHUDView.swift
//
//  The in-session wrist HUD for PCVR — fpsVR's readout and OVR Toolkit's palm mount,
//  except it is composited by visionOS rather than drawn into the stream. The streamed
//  video is the system's to composite; RealityKit content we add to the same immersive
//  space lands on top of it, which is why this can be real SwiftUI instead of a quad
//  layer the host has to render and encode.
//
//  Everything it shows was already measured on the host and written to a log line on
//  the PC — useless for judging a session you are wearing. `cb_perf_t` (0x0C) brings the
//  frame periods and the tracking residual across; `cb_telemetry_t` (0x07) supplies the
//  alignment state it shares with FoveatedAlignmentDebugView.
//
//  Summoned by turning a palm toward your face (see FoveatedImmersiveView) so it is a
//  deliberate act and never sits in the way of a game.
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import RAVEDiagnostics
import SwiftUI
import QuartzCore

struct FoveatedHUDView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @Environment(PCVRSessionLimiter.self) private var limiter
    @Environment(\.openWindow) private var openWindow
    @AppStorage("foveatedShowSentSkeleton") private var showSentSkeleton = false

    /// Redraw clock. The graph is a scrolling window over data that arrives at 10 Hz,
    /// so 10 Hz is also the fastest useful redraw — polling rather than observing the
    /// history array keeps a 180-element append from invalidating the view mid-batch.
    @State private var tick = 0

    private var bridge: ControllerBridgeSender? { manager.controllerBridge }

    /// Nil once the feed stops, rather than the last packet forever.
    ///
    /// A frozen readout is worse than an empty one: this panel showed a steady 33 fps at
    /// 29.9 ms for as long as it was looked at, which is an entirely plausible thing for a
    /// PC to be doing, and the number was minutes old. Every reading here is therefore
    /// gated on the packet being recent — the point of the panel is to be trusted at a
    /// glance, and "no data" is a thing it must be able to say.
    private var perf: ControllerBridgePerf? {
        guard let bridge else { return nil }
        return feedGate.gated(bridge.perf, now: CACurrentMediaTime())
    }

    /// The staleness rule, as the shared type. Every other HUD in the family
    /// wanted this and only this one had it.
    private var feedGate: RAVEFeedGate {
        var gate = RAVEFeedGate(timeout: Self.feedTimeout)
        if let receivedAt = bridge?.perfReceivedAt, receivedAt > 0 {
            gate.markUpdated(at: receivedAt)
        }
        return gate
    }
    private var telemetry: ControllerBridgeTelemetry? { bridge?.telemetry }
    /// Emptied with the feed, so the graph cannot keep plotting a dead session.
    private var history: [Float] { perf == nil ? [] : (bridge?.framePeriodHistory ?? []) }

    /// Perf arrives at 10 Hz, so this is several missed packets rather than one late one.
    private static let feedTimeout: CFTimeInterval = 1.5

    private var everHadPerf: Bool { feedGate.hasEverReceived }

    private var feedStatusText: String {
        guard bridge?.isRunning == true else { return "Bridge not running" }
        switch feedGate.status(now: CACurrentMediaTime()) {
        case .neverStarted:
            return "Waiting for the host's perf packet…"
        case .stopped(let secondsAgo):
            return String(format: "Host data stopped %.0fs ago", secondsAgo)
        case .live:
            return "Host data live"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            RAVEFrameTimeGraph(
                periodsMs: history.map(Double.init),
                slots: ControllerBridgeSender.framePeriodHistoryLength,
                emptyLabel: "no frames yet"
            )
            .frame(height: 66)
            pacingRow
            Divider()
            trackingSection
            switchProSection
            batteryRow
            questSection
            Divider()
            trialRow
            bandwidthRow
            actionRow
        }
        .padding(18)
        .frame(width: 380)
        .glassBackgroundEffect()
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                tick &+= 1
            }
        }
    }

    // MARK: Trial

    /// How long is left, for anyone who raised a palm to check rather than waiting
    /// to be told. Absent entirely once PCVR is unlocked — a paid session has no
    /// clock worth showing.
    @ViewBuilder
    private var trialRow: some View {
        if let remaining = limiter.remaining {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                Text("Trial session")
                Spacer()
                Text(PCVRSessionLimiter.clock(remaining))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(remaining <= 60 ? .orange : .secondary)
        }
    }

    // MARK: Bandwidth

    /// Fresh 0x0E or nothing, same "a dead feed reads as absent, not as stale good
    /// news" rule as `quest` above — and absent entirely when the host reports
    /// monitoring off, which is the expected state on an unmetered LAN PC.
    private var bandwidth: ControllerBridgeBandwidth? {
        guard let bridge, let bw = bridge.bandwidth,
              CACurrentMediaTime() - bridge.bandwidthReceivedAt < 3,
              bw.flags.contains(.enabled)
        else { return nil }
        return bw
    }

    @ViewBuilder
    private var bandwidthRow: some View {
        if let bandwidth {
            HStack(spacing: 6) {
                Image(systemName: "network")
                Text("Bandwidth")
                Spacer()
                Text("\(bandwidth.usedGB, specifier: "%.1f") / \(bandwidth.stopThresholdGB, specifier: "%.0f") GB")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(bandwidth.flags.contains(.stop) ? .red
                : bandwidth.flags.contains(.warning) ? .orange : .secondary)
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(frameRateText)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(bridge?.activeGame ?? "no title submitting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // The compositor's own rate, which is what the graph below plots. Shown
                // beside the game's rate rather than instead of it: the two coming apart is
                // the single most useful thing this panel can tell you, and while it was
                // the only number here a frozen picture read as a confident 120 fps.
                stat("composite", value: compositeFps.map { String(format: "%.0f", $0) } ?? "—",
                     tint: repeatingFrames ? .orange : nil)
                stat("frame", value: meanPeriod.map { String(format: "%.1f ms", $0) } ?? "—")
                stat("worst 1%", value: worstPeriod.map { String(format: "%.1f ms", $0) } ?? "—")
            }
        }
    }

    /// The rate new game frames arrive at — what you actually see move. Falls back to the
    /// compositor's rate only when the host is too old to report it.
    private var frameRateText: String {
        // The host is still talking; its render loop is the thing that stopped. Worth
        // distinguishing from a dead feed, because they call for opposite investigations.
        if perf?.flags.contains(.stalled) == true { return "host stalled" }
        if let client = clientFps, client > 0 { return String(format: "%.0f fps", client) }
        guard let composite = compositeFps else { return "— fps" }
        return String(format: "%.0f fps", composite)
    }

    private var clientFps: Float? {
        guard let perf, perf.clientFps > 0 else { return nil }
        return perf.clientFps
    }

    /// Derived from the graph's own samples rather than from `telemetry.fps`, which is a
    /// 10-second average and therefore hides exactly the dips this panel exists to show.
    private var compositeFps: Float? {
        guard let mean = meanPeriod, mean > 0 else { return nil }
        return 1000 / mean
    }

    /// The compositor is running ahead of the game, so some of what reaches the headset is
    /// the previous frame shown again. A little of this is normal; a lot of it is the bug
    /// that looked like a 1 fps game running at 120.
    private var repeatingFrames: Bool {
        guard let client = clientFps, let composite = compositeFps, composite > 0 else {
            return false
        }
        return client < composite * 0.9
    }

    /// The frame-period window as the shared series, so the reductions below are
    /// the same arithmetic every other HUD in the family uses.
    private var periodSeries: RAVESampleSeries {
        var series = RAVESampleSeries(capacity: ControllerBridgeSender.framePeriodHistoryLength)
        for period in history { series.append(Double(period)) }
        return series
    }

    /// Mean over the last ~half second, so the headline number settles enough to read.
    private var meanPeriod: Float? {
        periodSeries.mean(overLast: 45).map(Float.init)
    }

    /// The 99th percentile period — the stutter, which an average never shows.
    private var worstPeriod: Float? {
        periodSeries.p99.map(Float.init)
    }

    @ViewBuilder
    private var pacingRow: some View {
        if let perf {
            HStack(spacing: 18) {
                stat("wait", value: String(format: "%.1f ms", perf.waitBlockMs))
                stat("pace", value: String(format: "%.1f ms", perf.pdtStepMs))
                stat("pose drift", value: String(format: "%.2f°", perf.claimDeviationDegrees))
                Spacer()
            }
        } else {
            // "Lost" and "never arrived" are different faults with different causes, so
            // they get different words: one is a transport that stopped mid-session, the
            // other is one that never started.
            Label(feedStatusText, systemImage: everHadPerf ? "exclamationmark.triangle" : "clock")
                .font(.caption)
                .foregroundStyle(everHadPerf ? .orange : .secondary)
        }
    }

    // MARK: Tracking

    /// The disagreement between our hand tracking and the runtime's, which is the reason
    /// this section is not just a copy of the alignment window: on the wrist it can be
    /// read *while* moving, which is when the two sources come apart.
    @ViewBuilder
    private var trackingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hand tracking").font(.subheadline.weight(.semibold))
                Spacer()
                Text(wristSourceText).font(.caption).foregroundStyle(.secondary)
            }
            // Shake first: it is the symptom you notice in a game, where the gap below is
            // a number you have to go looking for.
            if let perf {
                HStack(spacing: 18) {
                    stat("shake L", value: String(format: "%.1f mm", perf.jitterMm.x),
                         tint: perf.jitterMm.x > 2 ? .orange : nil)
                    stat("shake R", value: String(format: "%.1f mm", perf.jitterMm.y),
                         tint: perf.jitterMm.y > 2 ? .orange : nil)
                    stat("worst", value: String(format: "%.1f mm",
                                                max(perf.jitterMaxMm.x, perf.jitterMaxMm.y)))
                    Spacer()
                }
            }
            if let perf, perf.solveMissMm > 0 || perf.solveMissDegrees > 0 {
                HStack(spacing: 18) {
                    stat("gap", value: String(format: "%.0f mm", perf.solveMissMm),
                         tint: perf.solveMissMm > 20 ? .orange : nil)
                    stat("angle", value: String(format: "%.1f°", perf.solveMissDegrees),
                         tint: perf.solveMissDegrees > 5 ? .orange : nil)
                    if let t = telemetry {
                        stat("input", value: t.inputAgeMs < 0
                             ? "never" : String(format: "%.0f ms", t.inputAgeMs))
                    }
                    Spacer()
                }
                // One line, and allowed its natural height: at four lines this caption
                // overlapped the row above it on device.
                Text("gap = our wrist vs the runtime's, same hand")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !handsOnly, perf?.flags.contains(.runtimeHands) == false {
                Text("Only our wrists are live — the runtime is not supplying any.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// What the toggle reflects: what we stopped (or resumed) sending, not what the host
    /// confirmed, so the label doesn't lag a round trip behind the tap. The host's side
    /// is implicit — no 0x03 packets reads as "controllers unplugged" within half a
    /// second, by the protocol's own stale-input rule.
    private var handsOnly: Bool {
        bridge?.emulatesControllers == false
    }

    /// Which source the host actually used for the emulated controllers, in frames.
    /// "runtime" is the good case: the runtime's own action spaces, where nothing is
    /// estimated. In hands-only mode there are no controllers to place, so the counts
    /// are meaningless and the mode itself is the honest readout.
    private var wristSourceText: String {
        if handsOnly { return "hands only" }
        guard let perf else { return "—" }
        let total = perf.runtimeGripFrames + perf.bridgeGripFrames
        guard total > 0 else { return "no wrists" }
        if perf.bridgeGripFrames == 0 { return "runtime" }
        if perf.runtimeGripFrames == 0 { return "ours (fallback)" }
        return "\(perf.runtimeGripFrames) runtime / \(perf.bridgeGripFrames) ours"
    }

    // MARK: Physical controller (Switch Pro)

    /// Appears only while a controller is attached. It answers the question you cannot
    /// otherwise answer from inside a headset — "is this thing connected, and does the PC
    /// think I am holding it in the hand I am actually holding it in?" — and lets the
    /// answer be corrected. Before this there was no feedback at all: a controller that
    /// failed to be picked up looked identical to a game ignoring its buttons.
    @ViewBuilder
    private var switchProSection: some View {
        if let bridge, bridge.controller != nil {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(bridge.controllerHasMotion ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Controller")
                        .font(.subheadline.weight(.semibold))
                    Text(controllerDetailText(bridge))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // Cycles auto → both → left → right. A picker would need a popover, and
                // this is four states read at a glance on a wrist panel.
                Button {
                    bridge.setHandPreference(Self.nextPreference(after: bridge.handPreference))
                } label: {
                    Text(Self.preferenceLabel(bridge.handPreference))
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(bridge.handPreference == .auto ? nil : .accentColor)
                .disabled(!bridge.controllerHasMotion)
            }
        }
    }

    private static func nextPreference(after current: ControllerHandPreference)
        -> ControllerHandPreference {
        switch current {
        case .auto:  .both
        case .both:  .left
        case .left:  .right
        case .right: .auto
        }
    }

    private static func preferenceLabel(_ p: ControllerHandPreference) -> String {
        switch p {
        case .auto:  "auto"
        case .both:  "both"
        case .left:  "left"
        case .right: "right"
        }
    }

    private func controllerDetailText(_ bridge: ControllerBridgeSender) -> String {
        guard bridge.controllerHasMotion else {
            // Buttons and sticks still work; only the IMU is missing. Say which, or the
            // row reads as "controller broken".
            return "Buttons and sticks only — this one reports no motion."
        }
        let holder = bridge.controllerHolder
        switch holder {
        case .unknown:
            return bridge.handPreference == .auto
                ? "Move it to work out which hand is holding it."
                : "No motion attributed."
        case .both, .left, .right:
            var text = "Motion → \(holder.displayName)"
            if bridge.handPreference == .auto {
                let scores = bridge.controllerHandScores
                if let l = scores.left, let r = scores.right {
                    text += String(format: " (match L %.0f%% / R %.0f%%)", l * 100, r * 100)
                }
            } else {
                text += " (set by you)"
            }
            return text + "."
        }
    }

    // MARK: Battery

    /// Every physical device's battery, in one glanceable row — the other reading you
    /// cannot take from inside a headset. Appears only when something reports one;
    /// charging is a glyph, and orange starts at 20% because that is roughly "finish
    /// this round, then plug in" for both pad families.
    @ViewBuilder
    private var batteryRow: some View {
        if !batteryChips.isEmpty {
            HStack(spacing: 14) {
                ForEach(batteryChips) { chip in
                    stat(chip.label + " batt",
                         value: "\(chip.percent)%" + (chip.charging ? " ⚡︎" : ""),
                         tint: chip.percent <= 20 && !chip.charging ? .orange : nil)
                }
                Spacer()
            }
        }
    }

    /// One chip per battery anyone can see: the locally paired pads (a fraction and
    /// a charging state, from GameController) and the desk-Quest's controllers (a
    /// whole percent off the 0x0D status, no charging state — the Quest cannot tell).
    private struct BatteryChip: Identifiable {
        let id: String
        let label: String
        let percent: Int
        let charging: Bool
    }

    private var batteryChips: [BatteryChip] {
        var chips = (bridge?.batteryReadouts ?? []).map {
            BatteryChip(id: $0.id,
                        label: $0.label,
                        percent: Int(($0.level * 100).rounded()),
                        charging: $0.charging)
        }
        /// nil is the norm rather than an error here: a controller that is off, or a
        /// Quest app that was never granted the permission it needs to read the
        /// levels, both simply contribute no chip.
        if let quest {
            if let left = quest.batteryLeft {
                chips.append(BatteryChip(id: "quest-left", label: "quest L",
                                         percent: left, charging: false))
            }
            if let right = quest.batteryRight {
                chips.append(BatteryChip(id: "quest-right", label: "quest R",
                                         percent: right, charging: false))
            }
        }
        return chips
    }

    // MARK: Desk-Quest controllers

    /// Fresh 0x0D or nothing: like `perf`, a dead feed must read as absent — "aligned"
    /// from a broker that has since restarted is exactly the confident-stale-number
    /// failure this panel exists to avoid.
    private var quest: ControllerBridgeQuestStatus? {
        guard let bridge, let status = bridge.questStatus,
              CACurrentMediaTime() - bridge.questStatusReceivedAt < 3
        else { return nil }
        return status
    }

    /// Appears only when a QuestControllerBridge headset is actually on the network —
    /// the host starts the feed on its first 0x01 packet. This is the assisted
    /// calibration the desk-Quest never had: live progress while waving, a residual
    /// once solved, and the enable/disable consent in the same place.
    @ViewBuilder
    private var questSection: some View {
        if let quest {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller")
                    .foregroundStyle(quest.state == .calibrated ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quest controllers")
                        .font(.subheadline.weight(.semibold))
                    Text(questDetailText(quest))
                        .font(.caption)
                        .foregroundStyle(quest.state == .lost ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    guard let bridge else { return }
                    bridge.setQuestControllers(!bridge.questControllersEnabled)
                } label: {
                    Text(bridge?.questControllersEnabled == true ? "off" : "use")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(bridge?.questControllersEnabled == true ? .accentColor : nil)
                .disabled(bridge == nil)
            }
        }
    }

    private func questDetailText(_ quest: ControllerBridgeQuestStatus) -> String {
        switch quest.state {
        case .seen:
            return "Detected on the network — tap \u{201C}use\u{201D} to calibrate."
        case .collecting:
            // Spread is the number that actually blocks the solve, so the nag is
            // keyed to it: pair count alone rises fine with a resting hand.
            if quest.spreadMeters < quest.spreadTargetMeters {
                return String(format: "Hold the controllers and wave your arms — spread %.0f of %.0f cm.",
                              quest.spreadMeters * 100, quest.spreadTargetMeters * 100)
            }
            return "Calibrating: \(quest.sampleCount) of \(quest.sampleTarget) pairs…"
        case .calibrated:
            var text = String(format: "Aligned, ±%.0f mm.", quest.residualMm)
            if quest.flags.contains(.warmStart) {
                text += " Restored from last session — confirming."
            }
            if !quest.flags.contains(.leftTracked) || !quest.flags.contains(.rightTracked) {
                let missing = quest.flags.contains(.leftTracked) ? "right" : "left"
                text += " The \(missing) controller is not tracked."
            }
            return text
        case .lost:
            return "Signal lost — is the Quest awake with its cameras facing you?"
        }
    }

    // MARK: Actions

    /// Icon-only. Labelled buttons wrapped their text to three lines inside visionOS's
    /// circular bordered style ("Co / ntr / ols"), which is unreadable — and a panel this
    /// size cannot fit four labels next to a status line either way. The input mode
    /// keeps a word, since an icon cannot say which of two states is active.
    private var desktopShown: Bool? { bridge?.desktopQuadShown }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                WindowSessionRegistry.surface("foveated-controls", using: openWindow)
            } label: {
                Label("Controls", systemImage: "slider.horizontal.3")
            }
            Button {
                showSentSkeleton.toggle()
            } label: {
                Label("Sent skeleton", systemImage: showSentSkeleton
                      ? "hand.raised.fill" : "hand.raised")
            }
            .tint(showSentSkeleton ? .accentColor : nil)
            FoveatedQuitTitleButton(bridge: bridge, iconOnly: true)
            // Your PC's screen, on a panel in the home view. Here because the palm HUD is
            // the one control surface you can reach without looking away from what you are
            // doing — and reaching for the desktop is usually something you want *while*
            // in the middle of something else.
            //
            // Reflects the host rather than our own last press: the desktop companion has
            // the same switch, and until the first telemetry arrives there is nothing
            // truthful to show.
            Button {
                guard let bridge else { return }
                bridge.setDesktopQuad(!(bridge.desktopQuadShown ?? false))
            } label: {
                Label("Desktop", systemImage: desktopShown == true
                      ? "display.trianglebadge.exclamationmark" : "display")
            }
            .tint(desktopShown == true ? .accentColor : nil)
            .disabled(desktopShown == nil)
            Spacer()
            // Input-mode switch, per title: emulated controllers driven by pinch
            // gestures (older games), or no controllers at all so a title with native
            // hand support reads our skeletons directly. Persisted into the game's
            // profile, and flippable mid-game because that is where you find out
            // which one a title wants.
            Button {
                guard let bridge else { return }
                bridge.setEmulateControllers(handsOnly)
            } label: {
                Text(handsOnly ? "hands" : "controllers")
                    .font(.caption2)
            }
            .tint(handsOnly ? .accentColor : nil)
            .disabled(bridge == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Plumbing

    /// The stat cell itself lives in RAVEDiagnostics now; this keeps the call
    /// spelling the thirteen sites above already use.
    private func stat(_ label: String, value: String, tint: Color? = nil) -> some View {
        RAVEStatView(label, value: value, tint: tint)
    }
}

#endif
