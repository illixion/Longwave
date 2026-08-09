import SwiftUI

/// DAW-style parametric EQ editor for the audio stream, presented as a
/// popover from the audio window's utility row. Two modes:
/// - **Bands**: tap the graph to add a band, drag its handle to set
///   frequency/gain, tap to select (footer Q slider), context menu or the
///   × badge to delete.
/// - **Draw**: freehand-draw a target curve; on release it's fitted to
///   graphic-EQ-style bands and the editor returns to Bands mode for
///   fine-tuning.
/// All edits flow through `AudioStreamManager.eqSettings`, which pushes
/// them to the live engine per drag tick — you hear the curve as you
/// shape it.
struct EQEditorView: View {
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.dismiss) private var dismiss

    private enum EditorMode: Hashable { case bands, draw }
    @State private var mode: EditorMode = .bands
    @State private var selectedBandID: UUID?
    /// In-flight freehand stroke (graph coordinates), Draw mode only.
    @State private var drawStroke: [CGPoint] = []
    @State private var customPresets: [EQPreset] = EQPreset.loadCustom()
    @State private var showSavePreset = false
    @State private var newPresetName = ""

    private let editorWidth: CGFloat = 810
    private let graphHeight: CGFloat = 345
    private var gainRange: Double { EQSettings.gainRange }

    var body: some View {
        @Bindable var audioManager = audioManager
        VStack(spacing: 12) {
            header(settings: $audioManager.eqSettings)
            graph
                .frame(height: graphHeight)
            footer(settings: $audioManager.eqSettings)
        }
        .padding(20)
        .frame(width: editorWidth)
    }

    // MARK: - Header

    private func header(settings: Binding<EQSettings>) -> some View {
        HStack(spacing: 14) {
            Toggle("Equalizer", isOn: settings.enabled)
                .toggleStyle(.switch)
                .fixedSize()

            Spacer()

            Picker("Mode", selection: $mode) {
                Text("Bands").tag(EditorMode.bands)
                Text("Draw").tag(EditorMode.draw)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()

            presetsMenu(settings: settings)

            Button("Reset") {
                selectedBandID = nil
                drawStroke = []
                settings.wrappedValue.bands = []
                settings.wrappedValue.preampDB = 0
            }
            .disabled(settings.wrappedValue.bands.isEmpty && settings.wrappedValue.preampDB == 0)

            // Sheet presentation has no tap-outside dismissal.
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close")
        }
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Name", text: $newPresetName)
            Button("Save") { saveCurrentAsPreset() }
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Saves the current bands as a custom preset.")
        }
    }

    private func presetsMenu(settings: Binding<EQSettings>) -> some View {
        Menu {
            Section("Presets") {
                ForEach(EQPreset.builtIns) { preset in
                    Button(preset.name) { apply(preset, to: settings) }
                }
            }
            if !customPresets.isEmpty {
                Section("Custom") {
                    ForEach(customPresets) { preset in
                        Button(preset.name) { apply(preset, to: settings) }
                    }
                }
            }
            Divider()
            Button {
                showSavePreset = true
            } label: {
                Label("Save as Preset…", systemImage: "square.and.arrow.down")
            }
            .disabled(settings.wrappedValue.bands.isEmpty)
            if !customPresets.isEmpty {
                Menu("Delete Custom Preset") {
                    ForEach(customPresets) { preset in
                        Button(preset.name, role: .destructive) {
                            customPresets.removeAll { $0.id == preset.id }
                            EQPreset.saveCustom(customPresets)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .help("Presets")
    }

    private func apply(_ preset: EQPreset, to settings: Binding<EQSettings>) {
        selectedBandID = nil
        var updated = settings.wrappedValue
        updated.bands = preset.bands
        updated.enabled = true
        settings.wrappedValue = updated // preamp auto-trims in the manager
    }

    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        newPresetName = ""
        guard !name.isEmpty else { return }
        customPresets.append(EQPreset(name: name, bands: audioManager.eqSettings.bands))
        EQPreset.saveCustom(customPresets)
    }

    // MARK: - Graph

    private var graph: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                gridAndCurve(size: size)
                    .contentShape(Rectangle())
                    .gesture(mode == .bands ? addBandGesture(size: size) : nil)

                if mode == .bands {
                    ForEach(audioManager.eqSettings.bands) { band in
                        bandHandle(band, size: size)
                    }
                } else {
                    drawOverlay(size: size)
                }
            }
        }
        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(audioManager.eqSettings.enabled ? 1 : 0.5)
    }

    private func gridAndCurve(size: CGSize) -> some View {
        let settings = audioManager.eqSettings
        return Canvas { context, _ in
            // Frequency grid (1-2-5 series) with decade labels.
            for hz in [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] {
                let gx = x(hz: hz, in: size)
                let major = hz == 100 || hz == 1_000 || hz == 10_000
                var line = Path()
                line.move(to: CGPoint(x: gx, y: 0))
                line.addLine(to: CGPoint(x: gx, y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(major ? 0.35 : 0.15)), lineWidth: 1)
                if major {
                    let label = hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))"
                    context.draw(Text(label).font(.caption2).foregroundStyle(.secondary),
                                 at: CGPoint(x: gx + 2, y: size.height - 8), anchor: .leading)
                }
            }
            // Gain grid.
            for db in stride(from: -(gainRange - 6), through: gainRange - 6, by: 6) {
                let gy = y(db: db, in: size)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: gy))
                line.addLine(to: CGPoint(x: size.width, y: gy))
                context.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.45 : 0.15)), lineWidth: 1)
                if db != 0 {
                    context.draw(Text("\(Int(db))").font(.caption2).foregroundStyle(.secondary),
                                 at: CGPoint(x: 4, y: gy - 7), anchor: .leading)
                }
            }

            // Combined response curve (+ soft fill to the 0 dB line).
            let samples = settings.responseCurve()
            guard samples.count > 1 else { return }
            var curve = Path()
            curve.move(to: CGPoint(x: x(hz: samples[0].hz, in: size), y: y(db: samples[0].db, in: size)))
            for sample in samples.dropFirst() {
                curve.addLine(to: CGPoint(x: x(hz: sample.hz, in: size), y: y(db: sample.db, in: size)))
            }
            let curveColor: Color = settings.enabled ? .accentColor : .secondary
            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: y(db: 0, in: size)))
            fill.addLine(to: CGPoint(x: 0, y: y(db: 0, in: size)))
            fill.closeSubpath()
            context.fill(fill, with: .color(curveColor.opacity(0.12)))
            context.stroke(curve, with: .color(curveColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: - Bands mode

    private func bandHandle(_ band: EQBandSetting, size: CGSize) -> some View {
        let selected = band.id == selectedBandID
        let position = CGPoint(x: x(hz: band.frequency, in: size), y: y(db: band.gain, in: size))
        return ZStack {
            Circle()
                .fill(selected ? Color.accentColor : Color.accentColor.opacity(0.6))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white.opacity(selected ? 0.9 : 0.4), lineWidth: 1.5))
        }
        .frame(width: 32, height: 32) // comfortable gaze/touch target
        .contentShape(Circle())
        .position(position)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    selectedBandID = band.id
                    guard let idx = audioManager.eqSettings.bands.firstIndex(where: { $0.id == band.id }) else { return }
                    // .local here is the handle's 32×32 frame; translate back
                    // into graph coordinates via the handle's known position.
                    let graphPoint = CGPoint(x: position.x + value.location.x - 16,
                                             y: position.y + value.location.y - 16)
                    var updated = audioManager.eqSettings.bands[idx]
                    updated.frequency = hz(x: graphPoint.x, in: size)
                    updated.gain = db(y: graphPoint.y, in: size)
                    audioManager.eqSettings.bands[idx] = updated.clamped()
                }
        )
        .contextMenu {
            Button(role: .destructive) {
                deleteBand(band.id)
            } label: {
                Label("Delete Band", systemImage: "trash")
            }
        }
        .overlay(alignment: .topLeading) {
            if selected {
                Button {
                    deleteBand(band.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .position(x: position.x + 18, y: position.y - 18)
                .help("Delete this band")
            }
        }
    }

    private func addBandGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                var settings = audioManager.eqSettings
                guard settings.bands.count < EQSettings.maxBands else { return }
                let band = EQBandSetting(frequency: hz(x: value.location.x, in: size),
                                         gain: db(y: value.location.y, in: size)).clamped()
                settings.bands.append(band)
                settings.enabled = true // hearing nothing after adding a band is confusing
                audioManager.eqSettings = settings
                selectedBandID = band.id
            }
    }

    private func deleteBand(_ id: UUID) {
        audioManager.eqSettings.bands.removeAll { $0.id == id }
        if selectedBandID == id { selectedBandID = nil }
    }

    // MARK: - Draw mode

    private func drawOverlay(size: CGSize) -> some View {
        ZStack {
            if drawStroke.count > 1 {
                Path { path in
                    path.move(to: drawStroke[0])
                    for point in drawStroke.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if drawStroke.isEmpty {
                Text("Draw your curve")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    drawStroke.append(value.location)
                }
                .onEnded { _ in
                    let curve = drawStroke.map { (hz: hz(x: $0.x, in: size), db: db(y: $0.y, in: size)) }
                    drawStroke = []
                    let fitted = EQSettings.fit(drawnCurve: curve)
                    guard !fitted.isEmpty else { return }
                    var settings = audioManager.eqSettings
                    settings.bands = fitted
                    settings.enabled = true
                    audioManager.eqSettings = settings
                    selectedBandID = nil
                    mode = .bands // the fit is immediately hand-editable
                }
        )
    }

    // MARK: - Footer

    private func footer(settings: Binding<EQSettings>) -> some View {
        let bands = settings.wrappedValue.bands
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("Preamp")
                    .font(.callout)
                    .frame(width: 64, alignment: .leading)
                Slider(value: settings.preampDB, in: -12...0, step: 0.5)
                    .disabled(settings.wrappedValue.autoPreamp)
                Text(String(format: "%.1f dB", settings.wrappedValue.preampDB))
                    .font(.callout.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
                Toggle("Auto", isOn: settings.autoPreamp)
                    .toggleStyle(.button)
                    .help("Trim headroom automatically so boosts never play louder than flat; turn off for a manual preamp (boosts may clip)")
            }

            HStack(spacing: 12) {
                if let idx = bands.firstIndex(where: { $0.id == selectedBandID }),
                   bands[idx].type == .parametric {
                    Text("Q")
                        .font(.callout)
                        .frame(width: 64, alignment: .leading)
                    Slider(value: qSliderBinding(settings: settings, index: idx), in: -1...1)
                        .frame(maxWidth: 300)
                    Text(String(format: "%.2f", bands[idx].q))
                        .font(.callout.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                } else {
                    Text(mode == .draw
                         ? "Release to fit the drawn curve to bands"
                         : "Tap the graph to add a band · drag to shape")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(bands.count)/\(EQSettings.maxBands)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Q slider works in log₁₀ space (−1…1 → 0.1…10) so the useful
    /// low-Q range isn't crushed into the first sliver of travel.
    private func qSliderBinding(settings: Binding<EQSettings>, index: Int) -> Binding<Double> {
        Binding(
            get: { log10(settings.wrappedValue.bands[index].q) },
            set: { newValue in
                guard settings.wrappedValue.bands.indices.contains(index) else { return }
                settings.wrappedValue.bands[index].q = pow(10, newValue)
            }
        )
    }

    // MARK: - Coordinate mapping (log-frequency x, linear-dB y)

    private func x(hz: Double, in size: CGSize) -> CGFloat {
        let t = log10(hz / EQSettings.minFrequency) / log10(EQSettings.maxFrequency / EQSettings.minFrequency)
        return CGFloat(t) * size.width
    }

    private func hz(x: CGFloat, in size: CGSize) -> Double {
        let t = Double(min(max(x / size.width, 0), 1))
        return EQSettings.minFrequency * pow(EQSettings.maxFrequency / EQSettings.minFrequency, t)
    }

    private func y(db: Double, in size: CGSize) -> CGFloat {
        CGFloat(0.5 - db / (gainRange * 2)) * size.height
    }

    private func db(y: CGFloat, in size: CGSize) -> Double {
        (0.5 - Double(min(max(y / size.height, 0), 1))) * gainRange * 2
    }
}
