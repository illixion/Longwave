#if os(visionOS)
import SwiftUI
import AVFoundation
import UIKit
import RAVEMedia
import GameController

private final class MacNativeLayerView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        // Opaque: the desktop stream carries the host's entire display, so
        // there is nothing behind it to see through to.
        isOpaque = true
        backgroundColor = .black
        layer.isOpaque = true
        layer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct MacNativeVideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> MacNativeLayerView {
        MacNativeLayerView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: MacNativeLayerView, context: Context) {}
}

/// The one window for a Native connection: Screen and Audio toggle
/// independently and live (an `.onChange` on each manager's `liveEnabled`
/// drives the actual connect/disconnect), with the layout adapting to
/// what's currently on — full-bleed video with a compact audio overlay
/// when both are on, the full audio mini-player when only Audio is on, the
/// per-window picker when Screen and Audio are both off on a v2 host, or a
/// placeholder when nothing is available at all.
struct NativeStreamView: View {
    /// Which Native session this window belongs to — the scene's value. The
    /// manager below is this session's, injected by the scene.
    let sessionID: MacNativeSessionID

    @Environment(MacNativeStreamManager.self) private var screenManager
    @Environment(MacNativeSessionStore.self) private var sessions
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var showEQ = false
    /// Mac Virtual Display-style curving for a wide desktop; off keeps it flat
    /// at every size.
    @AppStorage("nativeScreenCurvature.v3") private var curvatureSetting = NativeScreenCurvature.standard.rawValue
    @Environment(\.physicalMetrics) private var physicalMetrics

    // Pinned to the exact ideal size for one layout pass right after Screen
    // is turned back on from a small fixed-size panel — see the `onChange`
    // of `screenManager.liveEnabled` below for why.
    @State private var forceScreenIdealSize = false

    /// Hands, hover and the wheel on the desktop — the same controller VNC
    /// and Moonlight use.
    @State private var pointer = StreamPointerController()
    /// A Bluetooth/USB mouse, read raw and sent straight to the Mac — see
    /// `StreamMouseBridge`. The session's, shared with its controls.
    private var mouseBridge: StreamMouseBridge { .shared(for: screenManager) }

    /// This session's own audio, injected by the scene. Several sessions can
    /// stream at once and they mix; only Music mode is exclusive, and that is
    /// arbitrated inside `AudioStreamManager`.
    private var audioLive: Bool { audioManager.liveEnabled }

    /// Registry keys for this session's windows — `mac-native-stream` alone
    /// would answer for every session's.
    private var streamWindowKey: String {
        WindowSessionRegistry.key("mac-native-stream", instance: sessionID.registryInstance)
    }

    private var keyboardWindowKey: String {
        WindowSessionRegistry.key("mac-native-keyboard", instance: sessionID.registryInstance)
    }

    private var unityControlsWindowKey: String {
        WindowSessionRegistry.key("mac-native-unity-controls", instance: sessionID.registryInstance)
    }

    private var audioWindowKey: String {
        WindowSessionRegistry.key("mac-native-audio", instance: sessionID.registryInstance)
    }

    var body: some View {
        @Bindable var screenManager = screenManager
        @Bindable var audioManager = audioManager

        ZStack {
            // No filler view here on purpose: a `Color.clear` sibling would
            // report an unconstrained, always-flexible size, which under
            // `.contentSize` would make every state resizable and pinned to
            // the scene's oversized video default — the exact dead-space/
            // stray-resize-handle bug this state machine is meant to avoid
            // for the fixed-size panels (audio mini player, window picker,
            // empty placeholder). Each branch below sizes the window by
            // itself.
            if screenManager.liveEnabled {
                screenContent
            } else if audioLive {
                if audioPoppedOut {
                    audioPoppedOutContent
                } else {
                    audioOnlyContent
                }
            } else if windowsModeAvailable {
                windowPickerContent
            } else {
                emptyContent
            }
        }
        .background {
            WindowSceneReader { scene in
                audioManager.setPresenterScene(scene?.session.persistentIdentifier, presenter: Self.audioPresenterID)
            }
            .frame(width: 1, height: 1)
        }
        // Below the window, not straddling its bottom edge: half the bar
        // covered the bottom of the desktop, the Dock or the Start menu.
        .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            if screenManager.unityEnabled {
                EmptyView()
            } else if audioLive, !screenManager.liveEnabled {
                // Audio-only (or popped out): the Screen/Audio toggles and
                // Disconnect don't apply to this compact view — matches the
                // old standalone Audio Stream window, which had no ornament
                // at all beyond a home button (Disconnect lives inline in
                // `audioUtilityRow` instead, as it did there).
                homeOnlyControls
            } else {
                NativeDesktopControls(sessionID: sessionID)
            }
        }
        // The music widget beside the window rather than on top of it: over
        // the video it hid a corner of the Mac's desktop for nothing.
        .ornament(
            visibility: showsAudioOrnament && !mouseOwnsPointer ? .visible : .hidden,
            attachmentAnchor: .scene(.bottomTrailing),
            contentAlignment: .bottomLeading
        ) {
            Group {
                if audioPoppedOut {
                    poppedOutAudioChip
                } else {
                    compactAudioPanel
                }
            }
            .padding(.leading, 16)
        }
        .onAppear {
            audioManager.presenterAppeared(Self.audioPresenterID)
            resumeIfNeeded()
        }
        .onDisappear {
            // Soft teardown only — visionOS also fires this on transient
            // hides (space restore, snapping); a full forget happens only
            // from the explicit Disconnect button below.
            if !screenManager.unityEnabled {
                screenManager.disconnect()
                audioManager.windowDisappeared(presenter: Self.audioPresenterID)
            }
        }
        .onChange(of: audioPoppedOut) { _, poppedOut in
            // The pop-out closing (its own close button, or Bring Back) hands
            // the player back to this window, which should just keep playing.
            guard !poppedOut, audioLive, !screenManager.unityEnabled else { return }
            audioManager.ensureConnected()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            resumeIfNeeded()
        }
        .onChange(of: screenManager.liveEnabled) { _, on in
            guard !screenManager.unityEnabled else { return }
            screenManager.desktopToggleChanged(on)
            if on {
                // Turning Screen back on always comes from one of the small
                // fixed-size panels (audio mini player, window picker, empty
                // placeholder) — `screenContent` only shows while `on`. Under
                // `.contentSize` resizability the window only forces a resize
                // when the new content's size range excludes the current
                // size; `screenContent`'s free 400...∞ range trivially
                // contains that small size, so the window would otherwise
                // stay stuck at it instead of growing back to 16:9. Pin the
                // frame to the exact ideal size for one layout pass to force
                // the resize, then relax it so the window stays freely
                // resizable by hand afterward.
                forceScreenIdealSize = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    forceScreenIdealSize = false
                }
            }
        }
        .onChange(of: audioManager.liveEnabled) { _, on in
            // Every open Native window sees this change; only the session that
            // owns the player acts on it.
            guard !screenManager.unityEnabled else { return }
            if on {
                // A host that serves no audio would leave this on
                // "Connecting…" forever; refuse the toggle instead.
                guard screenManager.hostServesAudio else {
                    audioManager.liveEnabled = false
                    return
                }
                audioManager.reconnectLast()
            } else {
                audioManager.disconnect()
            }
        }
        .onChange(of: screenManager.hostServesAudio) { _, servesAudio in
            applyAudioAvailability(servesAudio)
        }
    }

    /// Names the host so the missing control reads as a platform limit rather
    /// than a failure the user should try to fix.
    private var audioUnavailableText: String {
        screenManager.serverPlatform == "windows"
            ? "Audio streaming isn't available from Windows hosts."
            : "This host doesn't stream audio."
    }

    /// The handshake tells us whether this host has an audio companion at all.
    /// Windows hosts don't, so drop a hopeful audio connection rather than
    /// leaving the player spinning on "Connecting…".
    private func applyAudioAvailability(_ servesAudio: Bool) {
        guard !servesAudio else { return }
        if audioManager.liveEnabled { audioManager.liveEnabled = false }
        audioManager.disconnect()
    }

    /// Recovers a toggle that's on but not actually connected — the normal
    /// case after a scene reactivation or a full space-restoration relaunch
    /// (a fresh manager with no in-memory state). A no-op when already
    /// running, so this is safe to call on every appear/activation.
    private func resumeIfNeeded() {
        if audioLive {
            if screenManager.hostServesAudio {
                audioManager.ensureConnected()
            } else {
                applyAudioAvailability(false)
            }
        }
        if screenManager.liveEnabled, !screenManager.isEnabled, let connection = screenManager.connection {
            screenManager.connect(to: connection)
        } else {
            // Even with the desktop stream off, keep the session up so the
            // window inventory and per-window streams work.
            screenManager.ensureSessionConnected()
        }
    }

    // MARK: - Per-window (Unity-style) streaming

    /// Whether this session can act as the controller for per-window scenes:
    /// a live v2 connection that publishes an inventory.
    private var windowsModeAvailable: Bool {
        screenManager.isEnabled && screenManager.supportsWindowStreams
    }

    /// The controller face of the Native window while the desktop stream and
    /// Audio are both off: connection status plus the host's window
    /// inventory, each row opening (or closing) that window as its own
    /// chrome-free scene. Audio being on takes over the whole window instead
    /// (see `body`), so there's no inline audio row to show here.
    private var windowPickerContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "macwindow.on.rectangle")
                    .foregroundStyle(.secondary)
                Text(screenManager.title)
                    .font(.headline)
                Spacer()
                Text(screenManager.state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if screenManager.windowInventory.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for the window list…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(screenManager.windowInventory) { window in
                            windowRow(window)
                        }
                    }
                }
                .frame(maxHeight: 460)
            }

            if !screenManager.hostServesAudio {
                Divider()
                Label(audioUnavailableText, systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 560)
        .glassBackgroundEffect()
    }

    private func windowRow(_ window: MacNativeStreamProtocol.WindowInfo) -> some View {
        let isOpen = screenManager.windowSessions[window.id] != nil
        return HStack(spacing: 12) {
            Image(systemName: window.isFocused ? "macwindow.badge.plus" : "macwindow")
                .foregroundStyle(window.isFocused ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title.isEmpty ? window.appName : window.title)
                    .lineLimit(1)
                Text(window.title.isEmpty
                     ? "\(Int(window.width))×\(Int(window.height))"
                     : "\(window.appName) · \(Int(window.width))×\(Int(window.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(isOpen ? "Close" : "Open") {
                if isOpen {
                    dismissWindow(
                        id: "mac-native-window",
                        value: MacNativeWindowStreamID(session: sessionID, windowID: window.id)
                    )
                } else {
                    openWindow(
                        id: "mac-native-window",
                        value: MacNativeWindowStreamID(session: sessionID, windowID: window.id)
                    )
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Audio pop-out

    /// True while the audio player has been popped out to its own
    /// "Audio Stream" window (`AudioStreamView`) — tracked live off
    /// `WindowSessionRegistry`, so the inline audio UI here stays hidden for
    /// exactly as long as that window remains open, and reappears the
    /// instant it's closed, with no separate persisted flag to fall out of
    /// sync.
    private var audioPoppedOut: Bool {
        WindowSessionRegistry.shared.isOpen("mac-native-audio", instance: sessionID.registryInstance)
    }

    /// This window's entry in the player's presenter set, so closing the
    /// pop-out doesn't stop audio the mini player here still shows.
    private static let audioPresenterID = "native-stream"

    private var showsAudioOrnament: Bool {
        screenManager.liveEnabled && audioLive && !screenManager.unityEnabled
    }

    private func popOutAudio() {
        openWindow(id: "mac-native-audio", value: sessionID)
    }

    private func foldAudioBackIn() {
        dismissWindow(id: "mac-native-audio", value: sessionID)
    }

    private var audioPoppedOutContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Audio is playing in its own window")
                .font(.headline)
            Button("Bring Back", action: foldAudioBackIn)
        }
        .padding(24)
        .glassBackgroundEffect()
    }

    // MARK: - Screen (with an optional compact Audio overlay)

    @ViewBuilder
    private var screenContent: some View {
        let curve = activeCurve
        ZStack {
            // Invisible (1×1) hardware keyboard capture — bottommost so it
            // never intercepts gestures. See `HardwareKeyboardView` (VNC's
            // equivalent) for why 1×1-and-transparent beats zero-size.
            MacNativeHardwareKeyboardView(screenManager: screenManager)
                .frame(width: 1, height: 1)

            // In mouse mode the desktop is one tile of a padded layout — see
            // `StreamMouseLayout`. Everything below sizes from the pane's
            // geometry, so the curve and the pointer mapping follow the pane.
            StreamPane(mouseOwnsPointer: mouseOwnsPointer) {
                ZStack {
                    if curvature != .off {
                        if let curve {
                            curvedDesktop(curve)
                        }
                    } else if let displayLayer = screenManager.displayLayer {
                        MacNativeVideoView(displayLayer: displayLayer)
                            .ignoresSafeArea()
                    }

                    if screenManager.state != .streaming {
                        VStack(spacing: 16) {
                            if case .disconnected = screenManager.state {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 42))
                                    .foregroundStyle(.orange)
                            } else {
                                ProgressView()
                                    .controlSize(.large)
                            }
                            Text(desktopStatusText)
                                .font(.headline)
                        }
                        .padding(24)
                        .glassBackgroundEffect()
                        // In front of the curve's forward edges, or a dropped
                        // session showed only as a frozen frame.
                        .offset(z: (curve?.sagitta ?? 0) + 8)
                    }
                }
                // On the curved desktop the mesh takes tap, press-and-hold and
                // drag itself, as hits on its surface — see `curvedDesktop`;
                // hover and both hands follow the ray from the circle's centre.
                .streamPointerInput(
                    pointer,
                    mouseOwnsPointer: mouseOwnsPointer,
                    hitTargetHidden: mouseBridge.menuOpen,
                    hitRect: mouseHitRect(curve),
                    oneHandGestures: curvature == .off ? .all : .subviews,
                    cursorPlacement: curve.map { curve in
                        { flat in
                            // On a curved desktop the dot sits on the curve
                            // itself, depth and all.
                            let surface = curve.surfacePoint(forFlatPoint: flat)
                            return (point: surface.point, depth: CGFloat(surface.depth))
                        }
                    },
                    planeToFlat: curve.map { curve in { curve.flatPoint(forPlanePoint: $0) } }
                )
                .onAppear { screenManager.setCurvedSurface(curvature != .off) }
                .onChange(of: curvatureSetting) {
                    screenManager.setCurvedSurface(curvature != .off)
                }
            } strip: {
                connectionStrip
            }
            .streamAspectLock(desktopAspect, paneSize: pointer.viewSize, mouseOwnsPointer: mouseOwnsPointer)
            .onAppear {
                pointer.target = screenManager
                startMouseBridge()
            }
            .onChange(of: screenManager.state) {
                mouseBridge.streaming = screenManager.state == .streaming
            }
            .onDisappear {
                mouseBridge.stop()
            }
        }
        .overlay(alignment: .top) {
            if pointer.dragLocked {
                StreamBadge.dragLock
            } else if let message = inputWarningMessage {
                StreamBadge(message, systemImage: "computermouse")
            }
        }
        // The desktop stream is opaque now, so this scene is a solid slab in
        // a `.plain` window that draws no chrome of its own. Round it, or the
        // Mac's display arrives as a hard-cornered rectangle pasted into the
        // room. (When the composition was transparent there were no edges to
        // round.)
        .clipShape(RoundedRectangle(cornerRadius: StreamMouseLayout.windowCornerRadius, style: .continuous))
        // As on Moonlight's stream view, whose mouse locks the way this one
        // didn't with the modifier only on the mouse hit target: the whole
        // content claims game-controller events.
        .handlesGameControllerEvents(matching: .gamepad)
        // Explicit flex range so this stays freely resizable under the
        // window group's `.contentSize` resizability — without it, a plain
        // ZStack reports no size preference of its own and the window would
        // collapse to the fixed-size panels' dimensions instead. Pinned tight
        // to the ideal size for one pass right after Screen comes back on —
        // see `forceScreenIdealSize`.
        .frame(
            minWidth: forceScreenIdealSize ? Self.screenIdealWidth : 400,
            idealWidth: Self.screenIdealWidth,
            maxWidth: forceScreenIdealSize ? Self.screenIdealWidth : .infinity,
            minHeight: forceScreenIdealSize ? Self.screenIdealHeight : 300,
            idealHeight: Self.screenIdealHeight,
            maxHeight: forceScreenIdealSize ? Self.screenIdealHeight : .infinity
        )
    }

    /// What streams, for the strip under the desktop in mouse mode.
    private var connectionStrip: some View {
        StreamConnectionStrip(
            status: screenManager.state.statusText,
            streamSize: screenManager.streamSize,
            mouse: mouseBridge
        ) {
            // The audio controls live in the strip, not in a tile beside the
            // desktop or a bar of their own: a tile let the pointer cross
            // onto it and off the window, and a second bar below a dead one
            // didn't help either (headset, 2026-10-08). visionOS pulls the
            // pointer onto the window bar by proximity, not by what is
            // targetable, so no layout of ours is a complete guard.
            if showsAudioOrnament, !audioPoppedOut {
                Text(compactAudioStatusText)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .trailing)
                AudioVolumeRow()
                    .frame(width: 170)
                HStack(spacing: 26) {
                    Button {
                        audioManager.toggleAudioMode()
                    } label: {
                        Image(systemName: audioManager.audioModeSymbol)
                    }
                    #if canImport(UIKit)
                    MicrophoneToggleButton(onPushToTalk: screenManager.setPushToTalkKey(held:))
                    #endif
                    Button {
                        showEQ.toggle()
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .tint(audioManager.eqSettings.enabled ? .accentColor : nil)
                    Button(action: popOutAudio) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .sheet(isPresented: $showEQ) {
            @Bindable var audioManager = audioManager
            EQEditorView(settings: $audioManager.eqSettings)
        }
    }

    private static let screenIdealWidth: CGFloat = 1440
    private static let screenIdealHeight: CGFloat = 900

    // MARK: - Screen remote control (mouse + keyboard)

    private var curvature: NativeScreenCurvature {
        NativeScreenCurvature(rawValue: curvatureSetting) ?? .standard
    }

    /// The curve the desktop is drawn on — every size once curving is on, so
    /// it bends continuously with the window — or nil when flat or before the
    /// stream's size is known.
    private var activeCurve: NativeScreenCurve? {
        guard let meters = curvature.radiusMeters, screenManager.streamSize.width > 0 else { return nil }
        return NativeScreenCurve.fitted(
            stream: screenManager.streamSize,
            in: pointer.viewSize,
            radius: Double(physicalMetrics.convert(meters, from: .meters))
        )
    }

    /// The window's aspect, so it can only be resized into shapes the desktop
    /// fills: the curve's outline as seen from its centre, or the picture's
    /// own aspect when flat. A window of any other shape left room for the
    /// curve's forward corners to run over the ornaments and resize handles.
    private var desktopAspect: Double? {
        guard screenManager.streamSize.width > 0, screenManager.streamSize.height > 0 else { return nil }
        if let curve = activeCurve { return curve.outlineAspect }
        return screenManager.streamSize.width / screenManager.streamSize.height
    }

    /// The desktop on a curved mesh, with tap, press-and-hold and drag
    /// taken as hits on the mesh itself — see `NativeCurvedScreenView`.
    private func curvedDesktop(_ curve: NativeScreenCurve) -> some View {
        NativeCurvedScreenView(
            surface: screenManager.frameSurface,
            curve: curve,
            acceptsInput: !mouseOwnsPointer,
            onTap: pointer.tap(at:),
            onLongPress: pointer.beginDragLock,
            onDragChanged: pointer.dragChanged(at:translation:),
            onDragEnded: pointer.dragEnded(at:)
        )
    }

    /// Whether a physical mouse drives the Mac's cursor: the view's own
    /// taps, drags and hover then stand aside, since visionOS also delivers
    /// each physical click to them.
    private var mouseOwnsPointer: Bool { mouseBridge.ownsPointer }

    private func startMouseBridge() {
        let bridge = mouseBridge
        bridge.streaming = screenManager.state == .streaming
        bridge.start()
    }

    /// The hit target is the picture's outline and nothing more, on the
    /// window plane, flat or curved. It used to stand in front of the curve's
    /// forward edges, so it would be found before the mesh; but a pointer
    /// leaving a target at that depth landed on whatever lay behind it at
    /// once (the strip, then the ornament), whatever dead space lay between.
    /// With the mesh taking no input in mouse mode, the plane is enough
    /// (headset, 2026-10-08). On the curve the outline is the one in the
    /// plane of its forward edges; flat, the fitted picture (the default).
    private func mouseHitRect(_ curve: NativeScreenCurve?) -> CGRect? {
        guard let curve else { return nil }
        let width = 2 * curve.radius * sin(curve.halfAngle)
        return CGRect(
            x: curve.contentRect.midX - width / 2,
            y: curve.contentRect.minY,
            width: width,
            height: curve.contentRect.height
        )
    }

    private var desktopStatusText: String {
        if screenManager.state == .connected {
            return "Waiting for the first frame…"
        }
        if case .disconnected = screenManager.state, screenManager.liveEnabled {
            // The manager retries on its own; say so, so the notice doesn't
            // read as the end of the session.
            return screenManager.state.statusText + " Reconnecting…"
        }
        return screenManager.state.statusText
    }

    private var inputWarningMessage: String? {
        switch screenManager.mouseAvailability {
        case .disabled: return "Mouse control is off — enable it in the Mac companion's Native settings."
        case .accessibilityDenied: return "Mouse control needs Accessibility permission on the Mac."
        case .available, .unknown: return nil
        }
    }

    /// Shown over the video in place of `compactAudioPanel` once Audio has
    /// been popped out — a small reminder it's still playing, with a way to
    /// fold it back in without hunting down the separate window.
    private var poppedOutAudioChip: some View {
        Button(action: foldAudioBackIn) {
            Label("Audio in its own window", systemImage: "macwindow.on.rectangle")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .padding(12)
        .glassBackgroundEffect()
    }

    /// Slim floating status/volume cluster for when Audio plays alongside
    /// video — the full album-art mini player would compete with it.
    private var compactAudioPanel: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Text(compactAudioStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            AudioVolumeRow()
                .frame(width: 200)

            HStack(spacing: 16) {
                Button {
                    audioManager.toggleAudioMode()
                } label: {
                    Image(systemName: audioManager.audioModeSymbol)
                }
                .help(audioManager.audioModeLabel)

                #if canImport(UIKit)
                MicrophoneToggleButton(onPushToTalk: screenManager.setPushToTalkKey(held:))
                #endif

                Button {
                    showEQ.toggle()
                } label: {
                    Image(systemName: "waveform")
                }
                .tint(audioManager.eqSettings.enabled ? .accentColor : nil)
                .help("Equalizer")

                Button(action: popOutAudio) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Pop out to its own window")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .glassBackgroundEffect()
        .sheet(isPresented: $showEQ) {
            @Bindable var audioManager = audioManager
            EQEditorView(settings: $audioManager.eqSettings)
        }
    }

    private var compactAudioStatusText: String {
        if let title = audioManager.nowPlaying?.title, !title.isEmpty {
            return title
        }
        switch audioManager.state {
        case .streaming: return "Audio Streaming"
        case .connecting: return "Connecting Audio…"
        case .error(let message): return message
        case .idle: return "Audio"
        }
    }

    // MARK: - Audio only (full mini player)

    private static let audioOnlyWidth: CGFloat = 400

    private var audioOnlyContent: some View {
        VStack(spacing: 0) {
            // Transparent slack outside the glass, so this window keeps one
            // height while the artwork changes shape and the panel only ever
            // grows upward. The window is `.plain`, so this shows nothing.
            Spacer(minLength: 0)
                .frame(height: AudioPlayerPanel.topSlack(
                    for: audioManager.artworkImage, width: Self.audioOnlyWidth))

            VStack(spacing: 0) {
                AudioPlayerPanel(width: Self.audioOnlyWidth)

                AudioVolumeRow()
                    .padding(.horizontal, 28)
                    .padding(.top, 22)

                audioUtilityRow
                    .padding(.top, 22)
                    .padding(.bottom, 22)
            }
            .frame(width: Self.audioOnlyWidth)
            .glassBackgroundEffect()
        }
        .frame(width: Self.audioOnlyWidth)
        .sheet(isPresented: $showEQ) {
            @Bindable var audioManager = audioManager
            EQEditorView(settings: $audioManager.eqSettings)
        }
    }

    private var audioUtilityRow: some View {
        HStack(spacing: 28) {
            Button(role: .destructive, action: disconnectAll) {
                Image(systemName: "xmark.circle")
            }
            .help("Disconnect")

            Button {
                audioManager.reconnectLast()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .disabled(audioManager.state == .connecting)
            .help("Reconnect the audio stream")

            Button {
                audioManager.toggleAudioMode()
            } label: {
                Image(systemName: audioManager.audioModeSymbol)
            }
            .help(audioManager.isForcedToSpeaker
                  ? audioManager.audioModeLabel
                  : audioManager.effectiveAudioMode == .music
                    ? "Music Mode — exclusive playback with Control Center; pauses on interruption"
                    : "Speaker Mode — mixes with other audio and auto-recovers")

            #if canImport(UIKit)
            MicrophoneToggleButton(onPushToTalk: screenManager.setPushToTalkKey(held:))
            #endif

            Button {
                showEQ.toggle()
            } label: {
                Image(systemName: "waveform")
            }
            .tint(audioManager.eqSettings.enabled ? .accentColor : nil)
            .help("Equalizer")

            Button {
                audioManager.toggleSpatialAudio()
            } label: {
                Image(systemName: audioManager.spatialAudioMode == .off
                      ? "person.spatialaudio.stereo.fill"
                      : "person.spatialaudio.fill")
            }
            .tint(audioManager.spatialAudioMode == .off ? nil : .accentColor)
            .help(spatialAudioHelp)
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    private var spatialAudioHelp: String {
        switch audioManager.spatialAudioMode {
        case .auto: return "Spatial Audio: Auto — follows the system default"
        case .on: return "Spatial Audio On — head-tracked rendering"
        case .off: return "Spatial Audio Off — flat stereo playback"
        }
    }

    // MARK: - Nothing enabled

    private var emptyContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Screen and Audio are both off")
                .font(.headline)
            Text("Turn one on below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .glassBackgroundEffect()
    }


    /// Minimal ornament for the audio-only views — the old standalone Audio
    /// Stream window had no ornament at all, just a home button alongside its
    /// own inline utility row (see `audioUtilityRow`'s Disconnect icon).
    /// Tightly padded, matching `HomeOrnament` (the shared home button every
    /// other pop-out window uses), so it reads as a small badge hugging the
    /// player rather than a second full-size control bar. A second button,
    /// split off by a divider, restores Screen — otherwise there's no way
    /// back to the desktop view once it's minimized down to this widget
    /// short of reopening the connection from the list. It carries its own
    /// text label (unlike the icon-only home button, matching the `controls`
    /// ornament's own "Screen" toggle) since a bare icon here reads as
    /// decoration rather than the only way back to the screen. Keyboard
    /// follows, as on the full bar, since typing needs no screen.
    private var homeOnlyControls: some View {
        HStack(spacing: 10) {
            Button {
                WindowSessionRegistry.surface("main", using: openWindow)
            } label: {
                Label("Connections", systemImage: "house")
                    .labelStyle(.iconOnly)
            }
            .help("Open the connection manager")

            Divider().frame(height: 20)

            Button {
                screenManager.liveEnabled = true
            } label: {
                Label("Screen", systemImage: "macwindow.on.rectangle")
            }
            .help("Show the screen again")

            Button(action: toggleKeyboardWindow) {
                Label("Keyboard", systemImage: isKeyboardWindowOpen ? "keyboard.fill" : "keyboard")
                    .labelStyle(.iconOnly)
            }
            .tint(isKeyboardWindowOpen ? .accentColor : nil)
            .help("Type on the Mac")
        }
        .padding(8)
        .glassBackgroundEffect()
    }

    private var isKeyboardWindowOpen: Bool {
        WindowSessionRegistry.shared.sessions[keyboardWindowKey] != nil
    }

    private func toggleKeyboardWindow() {
        if isKeyboardWindowOpen {
            dismissWindow(id: "mac-native-keyboard", value: sessionID)
        } else {
            openWindow(id: "mac-native-keyboard", value: sessionID)
        }
    }

    // MARK: - Disconnect

    private func disconnectAll() {
        // Take the per-window scenes down first — their sessions die with
        // the manager's forget() below.
        for windowID in screenManager.windowSessions.keys {
            dismissWindow(
                id: "mac-native-window",
                value: MacNativeWindowStreamID(session: sessionID, windowID: windowID)
            )
        }
        screenManager.unityEnabled = false
        // Ends this session only: another host's Native window keeps streaming,
        // audio included. `end` disconnects this session's player.
        sessions.end(sessionID)
        WindowSessionRegistry.shared.closeAfterSurfacingMain(
            closing: [
                keyboardWindowKey, streamWindowKey, unityControlsWindowKey, audioWindowKey,
            ],
            using: openWindow
        ) {
            dismissWindow(id: "mac-native-keyboard", value: sessionID)
            dismissWindow(id: "mac-native-stream", value: sessionID)
            dismissWindow(id: "mac-native-unity-controls", value: sessionID)
            dismissWindow(id: "mac-native-audio", value: sessionID)
        }
    }
}
#endif
