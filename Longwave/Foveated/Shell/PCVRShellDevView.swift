#if FOVEATED_ENABLED && DEBUG && os(visionOS)
import SwiftUI

/// The developer window for Shell A: opens and closes the space, tunes the fake
/// remote and the reprojection live, and shows what the render loop measured.
/// DEBUG only, opened from the PCVR tab's toolbar or at launch with
/// `-LongwavePCVRShellDemo` (which also opens the space, for simulator runs).
struct PCVRShellDevView: View {
    static let windowID = "pcvr-shell-dev"
    static let demoArgument = "-LongwavePCVRShellDemo"

    @Environment(PCVRShellSession.self) private var session
    @Environment(FoveatedConnectionManager.self) private var foveated
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isTransitioning = false
    @State private var openError: String?

    private enum ReprojectionKind: Hashable {
        case none, rotation, rotationAndTranslation
    }

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                Section {
                    Button(session.isPresenting ? "Close Shell A" : "Open Shell A", action: toggleSpace)
                        .disabled(isTransitioning || (!session.isPresenting && !foveated.isDisconnected))
                    if let openError {
                        Text(openError).foregroundStyle(.red)
                    }
                } footer: {
                    Text("A full immersive space presenting a fake remote's test room through the PCVR receiver. Only one immersive space can be open, so a PCVR session must be disconnected first.")
                }

                Section("Render loop") {
                    let stats = session.stats
                    LabeledContent("Configuration", value: stats.configuration)
                    LabeledContent("World tracking", value: stats.worldTracking)
                    LabeledContent("Display rate", value: String(format: "%.1f Hz", stats.displayRate))
                    LabeledContent("Frame age at present", value: Self.milliseconds(stats.frameAge, max: stats.frameAgeMax))
                    LabeledContent("Pose to present", value: Self.milliseconds(stats.poseToPresent))
                    LabeledContent("Arrival to present", value: Self.milliseconds(stats.arrivalToPresent))
                    LabeledContent("Prediction horizon", value: Self.milliseconds(stats.predictionHorizon))
                    LabeledContent("New / repeated / dropped", value: "\(stats.presentedNew) / \(stats.repeated) / \(stats.dropped)")
                    LabeledContent("Remote rendered / stalled", value: "\(session.remoteCounts.rendered) / \(session.remoteCounts.stalled)")
                    LabeledContent("Frames without anchor", value: "\(stats.framesWithoutAnchor)")
                }
                Section("Fake remote") {
                    LabeledContent("Delay", value: "\(Int(session.remoteSettings.delay * 1000)) ms")
                    Slider(value: $session.remoteSettings.delay, in: 0...0.06, step: 0.002)
                    Picker("Frame rate", selection: $session.remoteSettings.frameRate) {
                        ForEach([45.0, 72, 90], id: \.self) { Text("\(Int($0)) fps").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Overscan", value: "\(Int(session.remoteSettings.overscan * 100)) %")
                    Slider(value: $session.remoteSettings.overscan, in: 0...0.3, step: 0.01)
                    Button("Restart stream (numbering from 1)") { session.restartFakeStream() }
                        .disabled(!session.isPresenting)
                    Button("Simulate recentre (bump space epoch)") { session.simulateRecentre() }
                        .disabled(!session.isPresenting)
                }

                Section("Reprojection") {
                    Picker("Mode", selection: reprojectionKind) {
                        Text("None").tag(ReprojectionKind.none)
                        Text("Rotation").tag(ReprojectionKind.rotation)
                        Text("Rotation + translation").tag(ReprojectionKind.rotationAndTranslation)
                    }
                    if case .rotationAndTranslation(let distance) = session.renderOptions.receiver.mode {
                        LabeledContent("Proxy plane", value: String(format: "%.2f m", distance))
                        Slider(value: planeDistance, in: 0.5...5, step: 0.05)
                    }
                    Toggle("Predict pose to measured latency", isOn: $session.renderOptions.predictsToLatency)
                }

            }
            .navigationTitle("PCVR Shell A")
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains(Self.demoArgument), !session.isPresenting else { return }
            toggleSpace()
        }
    }

    private var reprojectionKind: Binding<ReprojectionKind> {
        Binding {
            switch session.renderOptions.receiver.mode {
            case .none: .none
            case .rotation: .rotation
            case .rotationAndTranslation: .rotationAndTranslation
            }
        } set: { kind in
            switch kind {
            case .none: session.renderOptions.receiver.mode = .none
            case .rotation: session.renderOptions.receiver.mode = .rotation
            case .rotationAndTranslation: session.renderOptions.receiver.mode = .rotationAndTranslation(planeDistance: 2)
            }
        }
    }

    private var planeDistance: Binding<Float> {
        Binding {
            if case .rotationAndTranslation(let distance) = session.renderOptions.receiver.mode { return distance }
            return 2
        } set: { distance in
            session.renderOptions.receiver.mode = .rotationAndTranslation(planeDistance: distance)
        }
    }

    private func toggleSpace() {
        isTransitioning = true
        openError = nil
        Task {
            defer { isTransitioning = false }
            if session.isPresenting {
                await dismissImmersiveSpace()
                return
            }
            switch await openImmersiveSpace(id: PCVRShellSession.immersiveSpaceID) {
            case .opened: break
            case .userCancelled: openError = "The space was not opened."
            case .error: openError = "The space could not be opened. Is another immersive space open?"
            @unknown default: openError = "The space could not be opened."
            }
        }
    }

    private static func milliseconds(_ value: Double?, max: Double? = nil) -> String {
        guard let value else { return "—" }
        guard let max else { return String(format: "%.1f ms", value) }
        return String(format: "%.1f ms (max %.1f)", value, max)
    }
}
#endif
