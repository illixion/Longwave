#if FOVEATED_ENABLED && DEBUG && os(visionOS)
import RAVECompanion
import StreamWire
import SwiftData
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
    @Query(sort: \SavedConnection.lastConnected, order: .reverse) private var connections: [SavedConnection]
    @AppStorage("pcvrShellSource") private var sourceRaw = Source.fake.rawValue
    @AppStorage("pcvrShellV3Connection") private var pcConnectionIDRaw = ""
    @AppStorage("pcvrShellV3Host") private var hostAddress = ""

    private enum Source: String, Hashable {
        case fake, v3
    }

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

                sourceSection

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

    // MARK: Source

    /// Paired Companions this headset holds a per-device token for: the only
    /// credentials a v3 session can use.
    private var pairedCompanions: [SavedConnection] {
        connections.filter { $0.connectionType == .native && $0.companionCredential?.deviceID != nil }
    }

    /// The PCVR tab's saved address, the default for the v3 host.
    private var pcvrAddress: String {
        connections.first { $0.connectionType == .foveated && !$0.hostname.isEmpty }?.hostname ?? ""
    }

    private var selectedCompanion: SavedConnection? {
        let companions = pairedCompanions
        if let chosen = companions.first(where: { $0.id.uuidString == pcConnectionIDRaw }) { return chosen }
        // Default: the Companion at the PCVR tab's address, else the newest.
        let address = pcvrAddress
        return companions.first { !address.isEmpty && $0.hostname == address } ?? companions.first
    }

    private var effectiveHost: String {
        if !hostAddress.isEmpty { return hostAddress }
        if !pcvrAddress.isEmpty { return pcvrAddress }
        return selectedCompanion?.companionHost ?? ""
    }

    @ViewBuilder private var sourceSection: some View {
        Section {
            Picker("Frame source", selection: $sourceRaw) {
                Text("Fake remote").tag(Source.fake.rawValue)
                Text("PC over v3").tag(Source.v3.rawValue)
            }
            .pickerStyle(.segmented)
            .disabled(session.isPresenting)
            if sourceRaw == Source.v3.rawValue {
                let companions = pairedCompanions
                if companions.isEmpty {
                    Text("No paired Companion. Pair this headset with the PC's Longwave Companion first (Connections → add → Native), then come back.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Credential", selection: Binding(
                        get: { selectedCompanion?.id.uuidString ?? "" },
                        set: { pcConnectionIDRaw = $0 })) {
                        ForEach(companions) { connection in
                            Text(connection.label.isEmpty ? connection.hostname : connection.label)
                                .tag(connection.id.uuidString)
                        }
                    }
                    .disabled(session.isPresenting)
                }
                TextField("PC address (default \(pcvrAddress.isEmpty ? "the Companion's" : pcvrAddress))", text: $hostAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(session.isPresenting)
                if let status = session.v3Status {
                    LabeledContent("State", value: status.state)
                    LabeledContent("Picture", value: status.picture)
                    LabeledContent("Decoded / lost / errors", value: "\(status.framesDecoded) / \(status.framesLost) / \(status.decodeErrors)")
                    LabeledContent("Bitrate", value: String(format: "%.1f Mbps", status.megabitsPerSecond))
                    LabeledContent("RTT", value: Self.milliseconds(status.rttMilliseconds))
                    LabeledContent("Decode", value: Self.milliseconds(status.decodeMilliseconds))
                    LabeledContent("Poses sent", value: String(format: "%.0f/s", status.posesPerSecond))
                }
            }
        } header: {
            Text("Source")
        } footer: {
            if sourceRaw == Source.v3.rawValue {
                Text("Streams from the PC's v3 PCVR host on UDP \(PCVRProfile.port), using the credential from pairing with its Companion (it needs the screen grant). Takes effect when the space opens.")
            }
        }
    }

    /// The v3 target for the space about to open, or nil for the fake remote.
    private func makeV3Target() -> PCVRV3Target? {
        guard sourceRaw == Source.v3.rawValue, let companion = selectedCompanion,
              let credential = companion.companionCredential else { return nil }
        let host = effectiveHost
        guard !host.isEmpty else { return nil }
        return PCVRV3Target(host: host, credential: credential, deviceName: DeviceName.current)
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
            session.v3Target = makeV3Target()
            if sourceRaw == Source.v3.rawValue, session.v3Target == nil {
                openError = "Pick a paired Companion and a PC address for the v3 source."
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
