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
import SwiftUI
import QuartzCore

struct FoveatedHUDView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
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
        guard let bridge, let perf = bridge.perf,
              CACurrentMediaTime() - bridge.perfReceivedAt < Self.feedTimeout
        else { return nil }
        return perf
    }
    private var telemetry: ControllerBridgeTelemetry? { bridge?.telemetry }
    /// Emptied with the feed, so the graph cannot keep plotting a dead session.
    private var history: [Float] { perf == nil ? [] : (bridge?.framePeriodHistory ?? []) }

    /// Perf arrives at 10 Hz, so this is several missed packets rather than one late one.
    private static let feedTimeout: CFTimeInterval = 1.5

    private var everHadPerf: Bool { (bridge?.perfReceivedAt ?? 0) > 0 }

    private var feedStatusText: String {
        guard bridge?.isRunning == true else { return "Bridge not running" }
        guard everHadPerf else { return "Waiting for the host's perf packet…" }
        let age = CACurrentMediaTime() - (bridge?.perfReceivedAt ?? 0)
        return String(format: "Host data stopped %.0fs ago", age)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            FrameTimeGraph(periodsMs: history)
                .frame(height: 66)
            pacingRow
            Divider()
            trackingSection
            switchProSection
            questSection
            Divider()
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

    /// Mean over the last ~half second, so the headline number settles enough to read.
    private var meanPeriod: Float? {
        let recent = history.suffix(45)
        guard !recent.isEmpty else { return nil }
        return recent.reduce(0, +) / Float(recent.count)
    }

    /// The 99th percentile period — the stutter, which an average never shows.
    private var worstPeriod: Float? {
        guard !history.isEmpty else { return nil }
        let sorted = history.sorted()
        return sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.99))]
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

    private func stat(_ label: String, value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Scrolling frame-period graph. Bars rather than a line: a single 40 ms spike in a line
/// chart reads as a slope between two good frames, and the spike is the whole point.
private struct FrameTimeGraph: View {
    let periodsMs: [Float]

    /// Guides at the rates a host might be pacing to. Whichever ones fit the current
    /// ceiling are drawn, so the graph annotates itself instead of needing a legend.
    private static let guides: [(ms: Float, label: String)] = [
        (8.33, "120"), (11.11, "90"), (16.67, "60")
    ]

    var body: some View {
        Canvas { context, size in
            guard !periodsMs.isEmpty else { return }
            // Scaled to the 95th percentile, not the maximum: a single 65 ms hitch set the
            // ceiling so high that every guide line collapsed onto the baseline and the
            // graph became one spike over an empty box. Outliers clip to the top instead,
            // where they are still perfectly visible as a full-height bar.
            let sorted = periodsMs.sorted()
            let p95 = sorted[min(sorted.count - 1, Int(Float(sorted.count) * 0.95))]
            let ceiling = max(20, p95 * 1.3)
            let y = { (ms: Float) in size.height * CGFloat(1 - min(ms, ceiling) / ceiling) }

            for guide in Self.guides where guide.ms < ceiling {
                let line = Path { p in
                    p.move(to: CGPoint(x: 0, y: y(guide.ms)))
                    p.addLine(to: CGPoint(x: size.width, y: y(guide.ms)))
                }
                context.stroke(line, with: .color(.white.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                context.draw(Text(guide.label).font(.system(size: 8)).foregroundStyle(.tertiary),
                             at: CGPoint(x: size.width - 8, y: y(guide.ms) - 5), anchor: .trailing)
            }

            // Right-aligned: the newest frame is always at the same edge, so the eye can
            // track "now" without re-finding it as the buffer fills.
            let slots = ControllerBridgeSender.framePeriodHistoryLength
            let barWidth = size.width / CGFloat(slots)
            let offset = slots - periodsMs.count
            for (index, ms) in periodsMs.enumerated() {
                let top = y(ms)
                let rect = CGRect(x: CGFloat(index + offset) * barWidth, y: top,
                                  width: max(barWidth - 0.5, 0.5), height: size.height - top)
                // Coloured by severity, not by index: 90 Hz is fine, 60 is a compromise,
                // below that is a stutter the user felt.
                let color: Color = ms <= 12 ? .green : ms <= 17 ? .yellow : .orange
                context.fill(Path(rect), with: .color(color.opacity(0.85)))
            }
        }
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .center) {
            if periodsMs.isEmpty {
                Text("no frames yet").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
#endif
