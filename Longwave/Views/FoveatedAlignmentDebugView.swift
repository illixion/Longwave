//  FoveatedAlignmentDebugView.swift
//
//  Hand-tracking alignment HUD for PCVR sessions. Alignment is only judgeable while
//  wearing the device — you have to see the game's hand next to your real one — so this
//  panel puts the whole loop inside the headset: what the host solved (0x07 telemetry),
//  a live nudge on top of it (0x08 tuning), and an optional overlay of the exact joints
//  we ship, drawn in the headset's own space.
//
//  How to use it:
//    1. Turn on "Show sent skeleton". If the dots sit on your real hand, everything up
//       to the wire is correct and the residual is entirely host-side.
//    2. Nudge Right/Up/Back until the game's hand lands on the dots. The offset that
//       fixes it names the bug: a constant translation is an origin/anchor error, a yaw
//       is a failed origin solve, and "no offset helps" means it isn't rigid at all.
//    3. Read the residual off the panel and tell the host side about it.
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import RAVEInput
import SwiftUI
import UIKit

struct FoveatedAlignmentDebugView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @AppStorage("foveatedShowSentSkeleton") private var showSentSkeleton = false

    /// Nudge granularity. Coarse first to find the ballpark, fine to settle it.
    @State private var positionStep: Float = 0.01
    @State private var yawStep: Float = 1.0

    enum EditingHand: Hashable { case both, left, right }
    @State private var editingHand: EditingHand = .both
    @State private var exportedProfiles = false
    /// Redraw clock for the live palm-facing readout (see `palmSection`).
    @State private var palmTick = 0

    private var bridge: ControllerBridgeSender? { manager.controllerBridge }
    private var telemetry: ControllerBridgeTelemetry? { bridge?.telemetry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profileSection
                Divider()
                hostSection
                Divider()
                nudgeSection
                Divider()
                solverSection
                Divider()
                palmSection
                Divider()
                overlaySection
            }
            .padding(24)
        }
        .navigationTitle("Hand Alignment")
    }

    // MARK: Per-title profile

    /// Names the title in play and which profile it resolved to. Input mapping is what a
    /// profile carries now; nudges below are a live diagnostic and are not saved.
    @ViewBuilder
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile").font(.headline)
            readout("Game", bridge?.activeGame ?? "none submitting")
            readout("Profile", profileDescription)

            Button(exportedProfiles ? "Copied" : "Copy profiles JSON",
                   systemImage: exportedProfiles ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = GameProfiles.exportJSON()
                exportedProfiles = true
            }
            Text("Nudges below are not saved — the host takes wrists from the runtime's "
                 + "own tracking, so an offset that persists is a bug to investigate "
                 + "rather than a value to keep.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var isNudgeZeroed: Bool {
        guard let tune = bridge?.debugTune else { return true }
        return tune.offsetLeft == .zero && tune.offsetRight == .zero && tune.yawDegrees == 0
    }

    private var profileDescription: String {
        switch bridge?.gameProfileSource {
        case .saved: "configured on this device"
        case .shipped: "shipped with the app"
        case .global: "none — global settings apply"
        case nil: "bridge not running"
        }
    }

    // MARK: Host telemetry

    @ViewBuilder
    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Host").font(.headline)
            if let t = telemetry {
                readout("Solved yaw", String(format: "%+.2f°", t.originYawDegrees))
                readout("Solved translation", vector(t.originTranslation))
                readout("Origin solve", t.flags.contains(.originValid)
                    ? (t.flags.contains(.solverOff) ? "bypassed"
                       : t.flags.contains(.solverFrozen) ? "frozen" : "converged")
                    : "not converged")
                readout("Head (host / sent)",
                        "\(vector(t.hostHeadPosition))\n\(vector(t.senderHeadPosition))")
                readout("Head difference", vector(t.hostHeadPosition - t.senderHeadPosition))
                // 0 = the host hasn't measured a worn headset yet and is on its 1.6 m
                // fallback; a wrong value here displaces every hand pose vertically.
                readout("Eye height", t.eyeHeight > 0
                    ? String(format: "%.3f m", t.eyeHeight) : "not sampled (1.600 m)")
                readout("Transport", t.flags.contains(.channel) ? "data channel" : "UDP")
                readout("Input age", age(t.inputAgeMs))
                readout("Skeleton age (L/R)", "\(age(t.leftJointsAgeMs)) / \(age(t.rightJointsAgeMs))")
                readout("Head packet age", age(t.headAgeMs))
                readout("Host frame rate", String(format: "%.1f fps", t.fps))
                readout("Hand prediction", String(format: "%.0f ms", t.handPredictMs))
            } else if bridge?.isRunning == true {
                Label("Waiting for host telemetry…", systemImage: "clock")
                    .foregroundStyle(.secondary)
                Text("Needs a host build with the 0x07 packet (broker ≥ alignment HUD).")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Label("Controller bridge not running", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Manual nudge

    @ViewBuilder
    private var nudgeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nudge").font(.headline)
                Spacer()
                Picker("Step", selection: $positionStep) {
                    Text("1 mm").tag(Float(0.001))
                    Text("1 cm").tag(Float(0.01))
                    Text("5 cm").tag(Float(0.05))
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            Text("Moves the VR hands relative to your real ones, in your own frame of "
                 + "reference — right, up and back are always yours, not the game's.")
                .font(.caption).foregroundStyle(.secondary)

            // Per hand, because a game's avatar-hand offset is mirrored rather than
            // shared: measure one hand, then mirror it and check the other.
            Picker("Hand", selection: $editingHand) {
                Text("Both").tag(EditingHand.both)
                Text("Left").tag(EditingHand.left)
                Text("Right").tag(EditingHand.right)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            let offset = editedOffset
            axisRow("Right", value: offset.x, axis: 0)
            axisRow("Up", value: offset.y, axis: 1)
            axisRow("Back", value: offset.z, axis: 2)
            if editingHand == .both, let tune = bridge?.debugTune,
               tune.offsetLeft != tune.offsetRight {
                Text("Hands differ — showing the left. Pick a side to edit one.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Text("Yaw").frame(width: 80, alignment: .leading)
                Button { nudgeYaw(-yawStep) } label: { Image(systemName: "rotate.left") }
                Button { nudgeYaw(+yawStep) } label: { Image(systemName: "rotate.right") }
                Text(String(format: "%+.1f°", bridge?.debugTune.yawDegrees ?? 0))
                    .monospacedDigit().frame(width: 90, alignment: .trailing)
                Picker("Yaw step", selection: $yawStep) {
                    Text("0.5°").tag(Float(0.5))
                    Text("1°").tag(Float(1))
                    Text("5°").tag(Float(5))
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            HStack(spacing: 16) {
                /* An avatar-hand offset is mirrored between hands, so a nudge measured on
                   one side is worth trying on the other before assuming they differ. */
                Button("Mirror to other hand", systemImage: "arrow.left.arrow.right") {
                    let source: BridgeHand = editingHand == .right ? .right : .left
                    mutate {
                        switch source {
                        case .left:
                            $0.offsetRight = SIMD3(-$0.offsetLeft.x, $0.offsetLeft.y,
                                                   $0.offsetLeft.z)
                        case .right:
                            $0.offsetLeft = SIMD3(-$0.offsetRight.x, $0.offsetRight.y,
                                                  $0.offsetRight.z)
                        }
                    }
                }
                .disabled(editingHand == .both)

                Button("Zero", systemImage: "circle.slash") {
                    mutate {
                        $0.offsetLeft = .zero
                        $0.offsetRight = .zero
                        $0.yawDegrees = 0
                    }
                }
                .disabled(isNudgeZeroed)
            }
        }
    }

    private func axisRow(_ title: String, value: Float, axis: Int) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 80, alignment: .leading)
            Button { nudge(axis: axis, by: -positionStep) } label: { Image(systemName: "minus") }
            Button { nudge(axis: axis, by: +positionStep) } label: { Image(systemName: "plus") }
            Text(String(format: "%+.3f m", value))
                .monospacedDigit().frame(width: 110, alignment: .trailing)
        }
    }

    // MARK: Solver + prediction

    @ViewBuilder
    private var solverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Origin solve").font(.headline)
            Text("The host continuously solves the yaw + translation between our ARKit "
                 + "world and the streaming runtime's tracking space, from the two views "
                 + "of your head. Freeze it to stop it drifting while you measure; bypass "
                 + "it to see how much of the error it was responsible for.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Freeze solve", isOn: binding(.freezeSolver))
            Toggle("Bypass solve (raw ARKit poses)", isOn: binding(.disableSolver))
            Button("Re-converge now", systemImage: "arrow.triangle.2.circlepath") {
                bridge?.requestAlignmentResolve()
            }

            Divider().padding(.vertical, 4)

            Toggle("Override hand prediction", isOn: binding(.setPredict))
            if bridge?.debugTune.flags.contains(.setPredict) == true {
                HStack {
                    Slider(value: predictBinding, in: -1...60, step: 1)
                    Text(String(format: "%.0f ms", bridge?.debugTune.handPredictMs ?? 0))
                        .monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                Text("Lead time added to the hand extrapolation; −1 disables prediction "
                     + "entirely. Raise it if the VR hands trail yours in motion, lower "
                     + "it if they overshoot and snap back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sent-skeleton overlay

    /// Live palm-facing values, because the wrist HUD's summon gesture has now been wrong
    /// twice and "it appears on the back of my hand" cannot distinguish a bad sign from a
    /// bad threshold. Hold a palm toward your face and read it: it should approach +1, and
    /// the panel appears above 0.78. Negative means the normal is inverted for that hand.
    @ViewBuilder
    private var palmSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wrist HUD gesture").font(.headline)
            // Hand poses change faster than anything else on this panel publishes, so this
            // section drives its own redraw rather than waiting for an observable change.
            let _ = palmTick
            readout("Palm facing (L)", facing(.left))
            readout("Palm facing (R)", facing(.right))
            EmptyView().task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    palmTick &+= 1
                }
            }
            Text("+1 is squarely toward you, 0 edge-on, −1 away. The panel summons above "
                 + "0.78 and holds until 0.50. A negative reading while looking straight at "
                 + "your palm means the palm normal is inverted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func facing(_ hand: BridgeHand) -> String {
        guard let value = bridge?.palmFacing(hand) else { return "hand not tracked" }
        return String(format: "%+.2f", value)
    }

    @ViewBuilder
    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overlay").font(.headline)
            Toggle("Show sent skeleton", isOn: $showSentSkeleton)
            Text("Draws the 26 joints per hand exactly as they go on the wire, in the "
                 + "headset's own space. On your real hand ⇒ the sender is correct. Off "
                 + "your real hand ⇒ the bug is here, before anything is transmitted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Plumbing

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    /// The offset the axis rows show and edit. "Both" edits the pair together and
    /// displays the left, which is the same thing until the hands are given to differ.
    private var editedOffset: SIMD3<Float> {
        guard let tune = bridge?.debugTune else { return .zero }
        return editingHand == .right ? tune.offsetRight : tune.offsetLeft
    }

    private func vector(_ v: SIMD3<Float>) -> String {
        String(format: "%+.3f, %+.3f, %+.3f", v.x, v.y, v.z)
    }

    /// Host ages arrive as −1 for "no packet ever seen".
    private func age(_ ms: Float) -> String {
        ms < 0 ? "never" : String(format: "%.0f ms", ms)
    }

    private func mutate(_ body: (inout ControllerBridgeDebugTune) -> Void) {
        guard let bridge else { return }
        var tune = bridge.debugTune
        body(&tune)
        bridge.debugTune = tune
    }

    private func nudge(axis: Int, by delta: Float) {
        mutate { tune in
            if editingHand != .right { tune.offsetLeft[axis] += delta }
            if editingHand != .left { tune.offsetRight[axis] += delta }
        }
    }

    private func nudgeYaw(_ delta: Float) {
        mutate { $0.yawDegrees += delta }
    }

    private func binding(_ flag: ControllerBridgeDebugTune.Flags) -> Binding<Bool> {
        Binding(
            get: { bridge?.debugTune.flags.contains(flag) ?? false },
            set: { on in
                mutate { tune in
                    if on { tune.flags.insert(flag) } else { tune.flags.remove(flag) }
                }
            })
    }

    private var predictBinding: Binding<Double> {
        Binding(
            get: { Double(bridge?.debugTune.handPredictMs ?? 15) },
            set: { value in mutate { $0.handPredictMs = Float(value) } })
    }
}
#endif
