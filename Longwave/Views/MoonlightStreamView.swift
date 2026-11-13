#if MOONLIGHT_ENABLED
import SwiftUI
import AVFoundation
import UIKit
import GameController
import RAVEMedia
@preconcurrency import MoonlightCommonC

// MARK: - Video Display View

/// UIView subclass that hosts an AVSampleBufferDisplayLayer, keeping the layer
/// frame in sync via layoutSubviews (not reliant on SwiftUI update cycles).
private class VideoLayerView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

/// UIViewRepresentable that hosts an AVSampleBufferDisplayLayer for hardware-accelerated
/// video decode and display with native HDR support.
private struct VideoDisplayView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> VideoLayerView {
        VideoLayerView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: VideoLayerView, context: Context) {}
}

// MARK: - Stream View

/// SwiftUI view that displays the Moonlight video stream and handles input —
/// on the same window chrome, hand gestures and Mouse mode as VNC and the
/// Native desktop (`StreamPointerController`, `StreamMouseBridge`,
/// `StreamControlsBar`).
struct MoonlightStreamView: View {
    @Environment(MoonlightConnectionManager.self) private var manager
    @Environment(MoonlightSessionStore.self) private var sessions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var showStats = false
    @State private var showDisconnectAlert = false
    @State private var pointer = StreamPointerController()
    @Environment(\.physicalMetrics) private var physicalMetrics
    /// The same curve the Native desktop offers; flat unless chosen, since
    /// most of what streams here is a game.
    @AppStorage("moonlightScreenCurvature") private var curvatureSetting = NativeScreenCurvature.off.rawValue

    /// A Bluetooth/USB mouse, read raw and sent to the host as relative
    /// motion — the session's, shared with its controls.
    private var mouseBridge: StreamMouseBridge { .shared(for: manager) }
    private var mouseOwnsPointer: Bool { mouseBridge.ownsPointer }

    var body: some View {
        // No backdrop behind the pane: in Mouse mode the padding around the
        // picture and the gap above the strip have to be empty, as on the
        // Native desktop. A black slab there was something the pointer could
        // land on, and it slid across it onto the window bar. The pane paints
        // its own black.
        ZStack {
            // 1×1 transparent hardware keyboard capture, kept bottommost so it
            // never intercepts gestures. A zero-size / zero-alpha view can't
            // reliably become first responder on visionOS.
            MoonlightHardwareKeyboardView(library: manager.library)
                .frame(width: 1, height: 1)

            StreamPane(mouseOwnsPointer: mouseOwnsPointer) {
                let curve = activeCurve
                ZStack {
                    // A curved picture stands in front of the window plane;
                    // black behind it would show around its outline.
                    if curvature == .off { Color.black }
                    if let layer = manager.displayLayer {
                        Group {
                            if curvature != .off {
                                if let curve { curvedPicture(curve) } else { Color.clear }
                            } else {
                                VideoDisplayView(displayLayer: layer)
                                    // How a layer declares HDR video on
                                    // visionOS; without it the picture is
                                    // dimmed as a whole once it plays. The
                                    // curve draws through RealityKit and
                                    // needs none.
                                    .raveDisplayCriteria(
                                        format: manager.isHDRActive ? manager.videoFormatDescription : nil,
                                        refreshRate: Double(max(manager.streamStats.configuredFPS, 1))
                                    )
                            }
                        }
                        // On the curve the mesh takes tap, press-and-hold
                        // and drag itself, as hits on its surface.
                        .streamPointerInput(
                            pointer,
                            mouseOwnsPointer: mouseOwnsPointer,
                            hitTargetHidden: mouseBridge.menuOpen,
                            hitRect: curve.map(Self.mouseHitRect),
                            oneHandGestures: curvature == .off ? .all : .subviews,
                            cursorPlacement: curve.map { curve in
                                { flat in
                                    let surface = curve.surfacePoint(forFlatPoint: flat)
                                    return (point: surface.point, depth: CGFloat(surface.depth))
                                }
                            },
                            planeToFlat: curve.map { curve in { curve.flatPoint(forPlanePoint: $0) } },
                            // Looking at (or pointing into) this stream is
                            // what routes the gamepad, the mouse and the
                            // keyboard here when more than one is running.
                            onPointerEntered: { sessions.focus(manager.slot) }
                        )
                    } else {
                        statusView
                    }
                }
                .onAppear { manager.setCurvedSurface(curvature != .off) }
                .onChange(of: curvatureSetting) { manager.setCurvedSurface(curvature != .off) }
            } strip: {
                StreamConnectionStrip(
                    status: stripStatus,
                    streamSize: manager.pointerStreamSize,
                    mouse: mouseBridge
                ) {
                    EmptyView()
                }
            }
            .streamAspectLock(streamAspect, paneSize: pointer.viewSize, mouseOwnsPointer: mouseOwnsPointer)

            // Statistics overlay
            if showStats {
                StreamStatsOverlay()
                    .environment(manager)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: StreamMouseLayout.windowCornerRadius, style: .continuous))
        .background {
            WindowSceneReader { scene in
                manager.audioSceneIdentifier = scene?.session.persistentIdentifier
            }
            .frame(width: 1, height: 1)
        }
        .overlay(alignment: .top) {
            if pointer.dragLocked {
                StreamBadge.dragLock
            } else if sessions.streamingSessions.count > 1, sessions.focusedSlot != manager.slot {
                // Physical inputs are going to another stream right now.
                StreamBadge("Controller and mouse are on another stream — look here to take them", systemImage: "gamecontroller")
            }
        }
        // Keep the live gamepad readout with the stream's Stats display.
        .overlay(alignment: .topLeading) {
            if showStats {
                GamepadVisualizerView(place: "moonlight").padding(24)
            }
        }
        .handlesGameControllerEvents(matching: .gamepad)
        .onAppear {
            pointer.target = manager
            mouseBridge.streaming = manager.displayLayer != nil
            mouseBridge.start()
        }
        .onChange(of: manager.displayLayer != nil) { _, streaming in
            mouseBridge.streaming = streaming
        }
        .onReceive(NotificationCenter.default.publisher(for: MoonlightInputFocus.didChange)) { note in
            // Input focus moved to another stream: let go of anything the
            // mouse was holding down here.
            if note.object as? Int == manager.slot {
                mouseBridge.releaseHeldButtons()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Headset donned / window refocused: retry a dropped stream
            // immediately instead of waiting out the backoff timer.
            if newPhase == .active {
                manager.sceneBecameActive()
            }
        }
        .onDisappear {
            mouseBridge.stop()
            manager.stopStreaming()
            dismissWindow(id: "moonlight-keyboard", value: manager.sessionID)
        }
        // Below the window, not straddling its bottom edge, where half the
        // bar covered the bottom of the picture.
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            controlsBar
        }
        .alert("Disconnect", isPresented: $showDisconnectAlert) {
            Button("Keep Running") {
                manager.stopStreaming()
                closeStreamWindow()
            }
            Button("End Session", role: .destructive) {
                manager.stopStreamingAndQuit()
                closeStreamWindow()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to end the session on the server, or keep it running for later?")
        }
    }

    private var statusView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(manager.statusMessage)
                .foregroundStyle(.secondary)
            if case .error = manager.connectionState, manager.canReconnect {
                Button("Reconnect Now") {
                    manager.reconnectNow()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// The window's aspect: the curve's outline when curved, so its forward
    /// corners can't run over the ornament, else the picture's own.
    private var streamAspect: Double? {
        guard manager.streamWidth > 0, manager.streamHeight > 0 else { return nil }
        if let curve = activeCurve { return curve.outlineAspect }
        return Double(manager.streamWidth) / Double(manager.streamHeight)
    }

    // MARK: - Curved screen

    private var curvature: NativeScreenCurvature {
        NativeScreenCurvature(rawValue: curvatureSetting) ?? .off
    }

    private var activeCurve: NativeScreenCurve? {
        guard let meters = curvature.radiusMeters, manager.displayLayer != nil,
              manager.streamWidth > 0, manager.streamHeight > 0 else { return nil }
        return NativeScreenCurve.fitted(
            stream: manager.pointerStreamSize,
            in: pointer.viewSize,
            radius: Double(physicalMetrics.convert(meters, from: .meters))
        )
    }

    /// The stream on a curved mesh (`NativeCurvedScreenView`), its frames
    /// decoded by the app and drawn into a texture that keeps HDR.
    private func curvedPicture(_ curve: NativeScreenCurve) -> some View {
        NativeCurvedScreenView(
            surface: manager.frameSurface,
            curve: curve,
            acceptsInput: !mouseOwnsPointer,
            onTap: pointer.tap(at:),
            onLongPress: pointer.beginDragLock,
            onDragChanged: pointer.dragChanged(at:translation:),
            onDragEnded: pointer.dragEnded(at:)
        )
    }

    /// The mouse hit target on a curve: the picture's outline as seen from
    /// the front, as on the Native desktop.
    private static func mouseHitRect(_ curve: NativeScreenCurve) -> CGRect {
        let width = 2 * curve.radius * sin(curve.halfAngle)
        return CGRect(
            x: curve.contentRect.midX - width / 2,
            y: curve.contentRect.minY,
            width: width,
            height: curve.contentRect.height
        )
    }

    private var stripStatus: String {
        guard manager.displayLayer != nil else { return manager.statusMessage }
        return manager.isHDRActive ? "Streaming · HDR" : "Streaming"
    }

    // MARK: - Teardown

    /// Hands off to the connection manager, then closes the stream window and
    /// its keyboard. `dismissWindow(id:)` rather than `dismiss()` so the close
    /// targets a known scene, and ordered behind the main window because
    /// visionOS won't let an app close its own last window.
    private func closeStreamWindow() {
        WindowSessionRegistry.shared.closeAfterSurfacingMain(
            closing: ["moonlight-keyboard", "moonlight-stream"],
            using: openWindow
        ) {
            dismissWindow(id: "moonlight-keyboard", value: manager.sessionID)
            dismissWindow(id: "moonlight-stream", value: manager.sessionID)
        }
    }

    // MARK: - Controls Bar (Ornament)

    private var isKeyboardWindowOpen: Bool {
        WindowSessionRegistry.shared.sessions["moonlight-keyboard"] != nil
    }

    private func toggleKeyboardWindow() {
        if isKeyboardWindowOpen {
            dismissWindow(id: "moonlight-keyboard", value: manager.sessionID)
        } else {
            openWindow(id: "moonlight-keyboard", value: manager.sessionID)
        }
    }

    private var controlsBar: some View {
        StreamControlsBar(
            target: manager,
            mouse: mouseBridge,
            keyboardOpen: isKeyboardWindowOpen,
            toggleKeyboard: toggleKeyboardWindow,
            audio: StreamAudioButton(
                isOn: Binding(
                    get: { !manager.audioMuted },
                    set: { manager.audioMuted = !$0 }
                ),
                systemImage: manager.audioMuted ? "speaker.slash" : "speaker.wave.2",
                help: manager.audioMuted ? "Unmute the stream" : "Mute the stream"
            ),
            disconnect: { showDisconnectAlert = true }
        ) {
            EmptyView()
        } display: {
            displaySettings
        }
    }

    /// Moonlight's content for the shared Display popover: the stats overlay
    /// and how the stream's sound is rendered.
    @ViewBuilder
    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Curve").font(.headline)
            Picker("Curve", selection: $curvatureSetting) {
                ForEach(NativeScreenCurvature.allCases) { curvature in
                    Text(curvature.title).tag(curvature.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        Toggle(isOn: $showStats) {
            Label("Stream Statistics", systemImage: "chart.bar")
        }

        Toggle(isOn: Binding(
            get: { manager.spatialAudioEnabled },
            set: { if $0 != manager.spatialAudioEnabled { manager.toggleSpatialAudio() } }
        )) {
            Label("Spatial Audio", systemImage: "person.spatialaudio.fill")
        }
        Text(manager.spatialAudioEnabled
             ? "Head-tracked rendering."
             : "Flat stereo playback of the stream's own mix.")
            .font(.caption)
            .foregroundStyle(.secondary)

        // Surround as virtual speakers on AirPods/headphones: the front is
        // wherever the wearer faced when it started, so offer to move it.
        // On the headset's speakers the stage follows the window instead.
        if manager.canRecenterSpatialAudio {
            Button {
                manager.recenterSpatialAudio()
            } label: {
                Label("Recenter Surround", systemImage: "scope")
            }
            .help("Make where you face now the front")
        }
    }
}
#endif
