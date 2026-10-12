#if os(visionOS) && DEBUG
import DebugTrace
import SwiftUI
import UniformTypeIdentifiers

/// Developer lab for the depth screen: the synthetic corridor or a still
/// capture on the relief mesh, with every knob exposed. Opened from Settings
/// (debug builds) or at launch with `-LongwaveDepthScreenLab`:
///
///     xcrun simctl launch booted pro.longwave.oss -LongwaveDepthScreenLab
///
/// `-DepthLabTurn <degrees>`, `-DepthLabEdges stretch|fill|cut`,
/// `-DepthLabTime <seconds>`, `-DepthLabPaused YES` and
/// `-DepthLabCutscene YES` (depth marked empty) preset the lab, for screenshots from the simulator's
/// fixed viewpoint.
struct DepthScreenLabView: View {
    static let windowID = "depth-screen-lab"
    /// Metres across; the volume leaves room behind it for the relief.
    static let screenWidth: Float = 1.1

    enum Source: String, CaseIterable, Identifiable {
        case synthetic, still
        var id: String { rawValue }
        var title: String { self == .synthetic ? "Corridor" : "Still" }
    }

    @State private var controller = DepthScreenController()
    @State private var synthetic: DepthSyntheticSource?
    @State private var source = Source.synthetic
    @State private var yaw: Float = 0
    @State private var usesSuggestedConvergence = true
    @State private var convergence: Float = 2.5
    @State private var emptyDepth = false
    @State private var dropRate = 0.0
    @State private var quarterDepth = true
    @State private var paused = false
    @State private var showStillPicker = false
    @State private var stillName: String?
    @State private var stillError: String?

    var body: some View {
        DepthScreenView(controller: controller, width: Self.screenWidth, yawDegrees: yaw)
            .ornament(attachmentAnchor: .scene(.bottomFront), contentAlignment: .top) {
                controls
                    .padding(20)
                    .frame(width: 760)
                    .glassBackgroundEffect()
            }
            .fileImporter(
                isPresented: $showStillPicker,
                allowedContentTypes: [.image, .json],
                allowsMultipleSelection: true
            ) { result in
                loadStill(result)
            }
            .task {
                applyLaunchPresets()
                startSynthetic()
            }
            .onDisappear {
                synthetic?.stop()
            }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                if source == .still {
                    Button(stillName == nil ? "Pick Files\u{2026}" : "Change\u{2026}") { showStillPicker = true }
                }
                Spacer()
                Picker("Edges", selection: settingsBinding(\.edgeMode)) {
                    ForEach(DepthEdgeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            slider("Strength", settingsBinding(\.strength), 0...0.5, format: "%.2f")
            slider("Pop-out", settingsBinding(\.popOutLimit), 0...1, format: "%.2f")
            HStack {
                Toggle("Suggested convergence", isOn: $usesSuggestedConvergence)
                    .frame(width: 300)
                if !usesSuggestedConvergence {
                    Slider(value: $convergence, in: 0.3...20)
                    Text(String(format: "%.1f", convergence)).monospacedDigit().frame(width: 50)
                }
            }
            slider("Edge slope", settingsBinding(\.maxSlope), 0.5...12, format: "%.1f")
            slider("Turn", $yaw, -40...40, format: "%.0f°")
            if source == .synthetic {
                HStack(spacing: 20) {
                    Toggle("Cutscene", isOn: $emptyDepth)
                    Toggle("Quarter depth", isOn: $quarterDepth)
                    Toggle("Pause", isOn: $paused)
                    Text("Drop").foregroundStyle(.secondary)
                    Slider(value: $dropRate, in: 0...0.5).frame(width: 120)
                }
            }
            if let stillError {
                Text(stillError).foregroundStyle(.red)
            }
            statsLine
        }
        .onChange(of: usesSuggestedConvergence) { applyConvergence() }
        .onChange(of: convergence) { applyConvergence() }
        .onChange(of: emptyDepth) { synthetic?.emptyDepth = emptyDepth }
        .onChange(of: dropRate) { synthetic?.depthDropRate = dropRate }
        .onChange(of: paused) { synthetic?.isPaused = paused }
        .onChange(of: quarterDepth) { synthetic?.configuration.depthDivisor = quarterDepth ? 4 : 2 }
        .onChange(of: source) {
            if source == .synthetic {
                startSynthetic()
            } else {
                synthetic?.stop()
                if stillName == nil { showStillPicker = true }
            }
        }
    }

    private var statsLine: some View {
        let stats = controller.stats
        return Text(
            "\(stats.grid.columns)×\(stats.grid.rows) mesh · depth \(stats.source.rawValue) · "
                + String(format: "update %.2f ms CPU, %.2f ms GPU", stats.encodeMilliseconds, stats.gpuMilliseconds)
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, format: String) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 50)
        }
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<DepthScreenSettings, Value>) -> Binding<Value> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { controller.settings[keyPath: keyPath] = $0 }
        )
    }

    private func applyLaunchPresets() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "DepthLabTurn") != nil {
            yaw = defaults.float(forKey: "DepthLabTurn")
        }
        if let edges = defaults.string(forKey: "DepthLabEdges").flatMap(DepthEdgeMode.init(rawValue:)) {
            controller.settings.edgeMode = edges
        }
        paused = defaults.bool(forKey: "DepthLabPaused")
        emptyDepth = defaults.bool(forKey: "DepthLabCutscene")
    }

    private func applyConvergence() {
        controller.settings.convergenceOverride = usesSuggestedConvergence ? nil : convergence
    }

    private func startSynthetic() {
        let source = synthetic ?? DepthSyntheticSource(feed: controller.feed)
        source.emptyDepth = emptyDepth
        source.depthDropRate = dropRate
        source.isPaused = paused
        if synthetic == nil, UserDefaults.standard.object(forKey: "DepthLabTime") != nil {
            source.sceneTime = UserDefaults.standard.double(forKey: "DepthLabTime")
        }
        source.configuration.depthDivisor = quarterDepth ? 4 : 2
        controller.feed.reset()
        source.start()
        synthetic = source
    }

    private func loadStill(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        do {
            let still = try DepthStillLoader.load(urls)
            synthetic?.stop()
            controller.feed.reset()
            // One frame number for both halves, as the stream pairs them.
            controller.feed.submit(depth: still.depth, range: still.range, frameNumber: 1)
            controller.feed.submit(colour: still.colour, frameNumber: 1)
            stillName = DepthStillLoader.classify(urls)?.colour.lastPathComponent
            stillError = nil
            if let suggested = still.range.convergence { convergence = suggested }
        } catch {
            stillError = error.localizedDescription
            AppLog.depthScreen.error("Depth screen: still load failed: \(error.localizedDescription)")
        }
    }
}

/// Opens the lab at launch for `-LongwaveDepthScreenLab`.
struct DepthScreenLabLaunch: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard ProcessInfo.processInfo.arguments.contains("-LongwaveDepthScreenLab") else { return }
            openWindow(id: DepthScreenLabView.windowID)
        }
    }
}
#endif
