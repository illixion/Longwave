#if os(visionOS)
import SwiftUI
import AVFoundation
import UIKit
import RAVEMedia

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

    // Remote-control gesture state (mirrors RemoteDesktopView's absolute-mode
    // handling — Native has no touchpad/relative mode, the video is always a
    // 1:1 tap-to-click surface).
    @State private var viewSize: CGSize = .zero
    @State private var isDragging = false
    @State private var dragLocked = false
    @State private var lastPointerPoint: (x: UInt16, y: UInt16)?
    @State private var previousDragTranslation: CGSize = .zero
    @State private var clickCadence = DoubleClickCadence()
    @State private var dragLockStartedAt: Date?
    @State private var scrollSteps = ScrollStepAccumulator()
    /// True while both hands are pinched (and briefly after), so the one-hand
    /// gestures stand down — see `TwoHandPointerGesture`.
    @State private var twoHandEngaged = false

    /// This session's own audio, injected by the scene. Several sessions can
    /// stream at once and they mix; only Music mode is exclusive, and that is
    /// arbitrated inside `AudioStreamManager`.
    private var audioLive: Bool { audioManager.liveEnabled }

    /// The Audio toggle. Turning it on points this session's player at this
    /// session's host — `prepareTarget` first, because the window can be
    /// opened with Audio off and the player then has nothing to reconnect to.
    private var audioBinding: Binding<Bool> {
        Binding(
            get: { audioLive },
            set: { on in
                guard on else {
                    audioManager.liveEnabled = false
                    return
                }
                if let connection = screenManager.connection {
                    audioManager.prepareTarget(
                        hostname: connection.hostname,
                        port: AudioStreamProtocol.defaultPort,
                        token: connection.companionToken,
                        title: connection.displayName,
                        lowLatency: connection.lowLatencyAudio
                    )
                }
                audioManager.liveEnabled = true
            }
        )
    }

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
        .ornament(attachmentAnchor: .scene(.bottom)) {
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
                controls(screenOn: $screenManager.liveEnabled, audioOn: audioBinding)
            }
        }
        // The music widget beside the window rather than on top of it: over
        // the video it hid a corner of the Mac's desktop for nothing.
        .ornament(
            visibility: showsAudioOrnament ? .visible : .hidden,
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
        ZStack {
            // Invisible (1×1) hardware keyboard capture — bottommost so it
            // never intercepts gestures. See `HardwareKeyboardView` (VNC's
            // equivalent) for why 1×1-and-transparent beats zero-size.
            MacNativeHardwareKeyboardView(screenManager: screenManager)
                .frame(width: 1, height: 1)

            GeometryReader { geometry in
                ZStack {
                    if curvature != .off {
                        if let curve = activeCurve {
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
                    }
                }
                .overlay {
                    // Topmost, and deliberately hit-testable: a scroll event is
                    // routed to the view under the pointer, so it has to be the
                    // one that's there. It claims no touches, which leaves the
                    // gestures below untouched.
                    IndirectScrollSurface(
                        onScroll: indirectScroll,
                        onScrollEnded: { scrollSteps.reset() }
                    )
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                // Press and hold = begin click+drag lock; single tap = left click
                // (or release a drag lock). Right click is the toolbar button.
                // On the curved desktop the mesh takes these itself, as hits
                // on its surface — see `curvedDesktop`.
                .gesture(dragLockGesture, including: flatInputMask)
                .gesture(tapGesture(), including: flatInputMask)
                .gesture(dragGesture(), including: flatInputMask)
                // Both hands: pinch-drag scrolls, pinch-and-release right-clicks.
                .twoHandPointerGesture(
                    isEngaged: $twoHandEngaged,
                    onEngage: cancelImplicitDrag,
                    onScroll: indirectScroll,
                    onSecondaryClick: rightClickAtCursor
                )
                .onContinuousHover { phase in
                    // A mouse hovering the window plane; on the curve it
                    // follows the ray from the circle's centre.
                    if let curve = activeCurve {
                        hover(phase, curve.flatPoint(forPlanePoint:))
                    } else {
                        hover(phase)
                    }
                }
                .onAppear {
                    viewSize = geometry.size
                    screenManager.setCurvedSurface(curvature != .off)
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewSize = newSize
                }
                .onChange(of: curvatureSetting) {
                    screenManager.setCurvedSurface(curvature != .off)
                }
            }

            // Local pointer dot for trackpad mode — the Mac's own cursor
            // isn't visible until the pointer actually lands there.
            if screenManager.touchMode == .relative, screenManager.streamSize.width > 0 {
                cursorOverlay
            }
        }
        .overlay(alignment: .top) {
            if dragLocked {
                dragLockBadge
            } else if let message = inputWarningMessage {
                inputWarningBadge(message)
            }
        }
        // The desktop stream is opaque now, so this scene is a solid slab in
        // a `.plain` window that draws no chrome of its own. Round it, or the
        // Mac's display arrives as a hard-cornered rectangle pasted into the
        // room. (When the composition was transparent there were no edges to
        // round.)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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

    private static let screenIdealWidth: CGFloat = 1440
    private static let screenIdealHeight: CGFloat = 900

    // MARK: - Screen remote control (mouse + keyboard)

    private var translator: GestureTranslator? {
        guard screenManager.streamSize.width > 0 else { return nil }
        return GestureTranslator(framebufferSize: screenManager.streamSize, viewSize: viewSize)
    }

    private var curvature: NativeScreenCurvature {
        NativeScreenCurvature(rawValue: curvatureSetting) ?? .standard
    }

    /// The curve the desktop is drawn on — every size once curving is on, so
    /// it bends continuously with the window — or nil when flat or before the
    /// stream's size is known.
    private var activeCurve: NativeScreenCurve? {
        guard let meters = curvature.radiusMeters, screenManager.streamSize.width > 0 else { return nil }
        return NativeScreenCurve(
            contentRect: NativeScreenCurve.fittedRect(stream: screenManager.streamSize, in: viewSize),
            radius: Double(physicalMetrics.convert(meters, from: .meters))
        )
    }

    /// The window-wide pointer gestures run only on the flat desktop; on the
    /// curved one they stand aside for the mesh's own.
    private var flatInputMask: GestureMask {
        curvature == .off ? .all : .subviews
    }

    /// The desktop on a curved mesh, with tap, press-and-hold and drag
    /// taken as hits on the mesh itself — see `NativeCurvedScreenView`.
    private func curvedDesktop(_ curve: NativeScreenCurve) -> some View {
        NativeCurvedScreenView(
            surface: screenManager.frameSurface,
            curve: curve,
            onTap: handleTap(at:),
            onLongPress: beginDragLockAtCursor,
            onDragChanged: handleDragChanged(at:translation:),
            onDragEnded: handleDragEnded(at:)
        )
    }

    /// Bluetooth-mouse / gaze pointer motion without a button held — a
    /// DragGesture only fires while a button is down.
    private func hover(_ phase: HoverPhase, _ toFlat: (CGPoint) -> CGPoint = { $0 }) {
        if case .active(let location) = phase, let point = framebufferPoint(toFlat(location)) {
            lastPointerPoint = point
            screenManager.moveCursorAbsolute(x: point.x, y: point.y)
        }
    }

    /// A point on the flat picture (view coordinates) to a stream pixel.
    private func framebufferPoint(_ location: CGPoint) -> (x: UInt16, y: UInt16)? {
        translator?.viewToFramebuffer(location)
    }

    private var desktopStatusText: String {
        if screenManager.state == .connected {
            return "Waiting for the first frame…"
        }
        return screenManager.state.statusText
    }

    /// Single tap = left click (absolute) or click at the virtual cursor
    /// (trackpad), or release an active drag lock.
    private func tapGesture() -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in handleTap(at: value.location) }
    }

    /// `location` is on the flat picture, in view points — from the flat
    /// gesture surface directly, or mapped off the curved mesh.
    private func handleTap(at location: CGPoint) {
        guard !twoHandEngaged else { return }
        if dragLocked {
            // Lifting off the press-and-hold that *started* the lock
            // can arrive here as a tap; that would release it instantly.
            if let started = dragLockStartedAt, Date().timeIntervalSince(started) < 0.4 { return }
            releaseLeft(at: location)
            dragLocked = false
        } else {
            leftClick(at: location)
        }
    }

    /// Press and hold = grab: holds the left button down so the next drag
    /// drags, released by the next tap. This was a double-tap, which left no
    /// way to double-click — the second tap grabbed instead of clicking.
    private var dragLockGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55)
            .onEnded { _ in beginDragLockAtCursor() }
    }

    /// Drag moves the cursor; the left button stays down for the duration
    /// (or, while a drag lock is held, for as long as the lock lasts).
    private func dragGesture() -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in handleDragChanged(at: value.location, translation: value.translation) }
            .onEnded { value in handleDragEnded(at: value.location) }
    }

    /// Points on the flat picture, in view points, like `handleTap`.
    private func handleDragChanged(at location: CGPoint, translation: CGSize) {
        guard !twoHandEngaged else { return }
        if screenManager.touchMode == .absolute {
            guard let point = framebufferPoint(location) else { return }
            if dragLocked {
                screenManager.sendMouseMove(x: point.x, y: point.y)
            } else if !isDragging {
                isDragging = true
                screenManager.sendMouseDown(button: .left, x: point.x, y: point.y)
            } else {
                screenManager.sendMouseMove(x: point.x, y: point.y)
            }
        } else {
            let dx = translation.width - previousDragTranslation.width
            let dy = translation.height - previousDragTranslation.height
            previousDragTranslation = translation
            if let delta = translator?.viewDeltaToFramebufferDelta(dx: dx, dy: dy) {
                screenManager.moveVirtualCursor(dx: delta.dx, dy: delta.dy)
            }
        }
    }

    private func handleDragEnded(at location: CGPoint) {
        guard !twoHandEngaged else { return }
        if screenManager.touchMode == .absolute, isDragging, !dragLocked,
           let point = framebufferPoint(location) {
            screenManager.sendMouseUp(button: .left, x: point.x, y: point.y)
        }
        isDragging = false
        previousDragTranslation = .zero
    }

    /// A second hand arriving turns whatever the first one was doing into a
    /// two-hand gesture, so let go of the button an absolute drag pressed on
    /// its own. A deliberate drag *lock* is left held — scrolling mid-drag is a
    /// real thing to want.
    private func cancelImplicitDrag() {
        guard isDragging, !dragLocked else { return }
        if screenManager.touchMode == .absolute {
            if let point = lastPointerPoint {
                screenManager.sendMouseUp(button: .left, x: point.x, y: point.y)
            }
        } else {
            screenManager.releaseMouseAtVirtualCursor(button: .left)
        }
        isDragging = false
        previousDragTranslation = .zero
    }

    /// Scroll travel in view points — a mouse wheel's, a trackpad's, or both
    /// hands' midpoint — turned into the line steps the host takes. The wheel
    /// reaches us through `IndirectScrollSurface`, since SwiftUI surfaces it to
    /// no gesture at all; the hands through `TwoHandPointerGesture`.
    private func indirectScroll(_ delta: CGSize) {
        guard screenManager.streamSize.width > 0 else { return }
        let steps = scrollSteps.steps(for: delta)
        guard steps.dx != 0 || steps.dy != 0 else { return }
        if screenManager.touchMode == .absolute {
            // Wherever the pointer is, which with a mouse is exactly where the
            // user meant to scroll — the pinch has to settle for the middle.
            let point = lastPointerPoint ?? (
                x: UInt16(clamping: Int(screenManager.streamSize.width / 2)),
                y: UInt16(clamping: Int(screenManager.streamSize.height / 2))
            )
            screenManager.sendScroll(x: point.x, y: point.y, deltaX: steps.dx, deltaY: steps.dy)
        } else {
            screenManager.scrollAtVirtualCursor(deltaX: steps.dx, deltaY: steps.dy)
        }
    }

    private func leftClick(at location: CGPoint) {
        if screenManager.touchMode == .absolute {
            guard let raw = framebufferPoint(location) else { return }
            // Snap a quick second tap onto the first one's pixel so the host
            // reads the pair as a double-click (see DoubleClickCadence).
            let point = clickCadence.resolve(raw)
            screenManager.sendMouseDown(button: .left, x: point.x, y: point.y)
            screenManager.sendMouseUp(button: .left, x: point.x, y: point.y)
        } else {
            // Trackpad mode already clicks twice at the same virtual cursor.
            screenManager.clickAtVirtualCursor(button: .left)
        }
    }

    /// Press and hold the left button so the next drag drags, at the tracked
    /// pointer — the same "wherever the cursor is" rule the Right-click button
    /// uses, since a long press carries no location of its own.
    private func beginDragLockAtCursor() {
        guard !twoHandEngaged, !dragLocked else { return }
        if screenManager.touchMode == .absolute {
            guard let point = lastPointerPoint else { return }
            screenManager.sendMouseDown(button: .left, x: point.x, y: point.y)
        } else {
            screenManager.pressMouseAtVirtualCursor(button: .left)
        }
        dragLocked = true
        dragLockStartedAt = Date()
    }

    /// Release the held left button (ends a drag lock).
    private func releaseLeft(at location: CGPoint) {
        if screenManager.touchMode == .absolute {
            guard let point = framebufferPoint(location) else { return }
            screenManager.sendMouseUp(button: .left, x: point.x, y: point.y)
        } else {
            screenManager.releaseMouseAtVirtualCursor(button: .left)
        }
    }

    /// Right click at the last known pointer position (absolute) or the
    /// virtual cursor (trackpad) — a toolbar button, since there's no gesture
    /// free to dedicate to it, matching RemoteDesktopView's approach.
    private func rightClickAtCursor() {
        screenManager.rightClickAtDesktopCursor()
    }

    private var dragLockBadge: some View {
        Label("Dragging — tap to drop", systemImage: "hand.draw")
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassBackgroundEffect()
            .padding(.top, 8)
    }

    /// Local pointer dot drawn at the virtual cursor, for trackpad mode.
    private var cursorOverlay: some View {
        let flat = translator?.framebufferToView(
            x: screenManager.virtualCursorX,
            y: screenManager.virtualCursorY
        ) ?? .zero
        // On a curved desktop the dot sits on the curve itself, depth and
        // all, rather than on the window plane behind it.
        let surface: (point: CGPoint, depth: Double) =
            activeCurve?.surfacePoint(forFlatPoint: flat) ?? (point: flat, depth: 0)

        return Circle()
            .fill(.white.opacity(0.7))
            .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 1))
            .frame(width: 12, height: 12)
            .position(surface.point)
            .offset(z: CGFloat(surface.depth) + 1)
            .allowsHitTesting(false)
    }

    private var inputWarningMessage: String? {
        switch screenManager.mouseAvailability {
        case .disabled: return "Mouse control is off — enable it in the Mac companion's Native settings."
        case .accessibilityDenied: return "Mouse control needs Accessibility permission on the Mac."
        case .available, .unknown: return nil
        }
    }

    private func inputWarningBadge(_ message: String) -> some View {
        Label(message, systemImage: "computermouse")
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassBackgroundEffect()
            .padding(.top, 8)
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

    // MARK: - Controls ornament

    private func controls(screenOn: Binding<Bool>, audioOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Button {
                openWindow(id: "main", value: MainWindowID.shared)
            } label: {
                Label("Connections", systemImage: "house")
            }

            Toggle(isOn: screenOn) {
                Label("Screen", systemImage: "macwindow.on.rectangle")
            }
            .toggleStyle(.button)

            if screenManager.liveEnabled {
                Button {
                    screenManager.touchMode = screenManager.touchMode == .absolute ? .relative : .absolute
                } label: {
                    Label(
                        screenManager.touchMode == .absolute ? "Direct" : "Touchpad",
                        systemImage: screenManager.touchMode == .absolute
                            ? "hand.tap" : "rectangle.and.hand.point.up.left"
                    )
                }

                Button(action: rightClickAtCursor) {
                    Label("Right-click", systemImage: "cursorarrow.click.2")
                }

                displayMenu

                Button(action: toggleKeyboardWindow) {
                    Label("Keyboard", systemImage: isKeyboardWindowOpen ? "keyboard.fill" : "keyboard")
                }
                .tint(isKeyboardWindowOpen ? .accentColor : nil)
            }

            Toggle(isOn: audioOn) {
                Label(
                    "Audio",
                    systemImage: screenManager.hostServesAudio ? "speaker.wave.2" : "speaker.slash"
                )
            }
            .toggleStyle(.button)
            .disabled(!screenManager.hostServesAudio)

            Button(action: disconnectAll) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
        .glassBackgroundEffect()
    }

    /// Switches the desktop the host streams — its virtual display or one of
    /// its monitors — without a trip to the Mac's companion window.
    private var displayMenu: some View {
        Menu {
            if screenManager.displays.count > 1 {
                Picker("Desktop", selection: Binding(
                    get: { screenManager.selectedDisplayID ?? "" },
                    set: { screenManager.selectDisplay($0) }
                )) {
                    ForEach(screenManager.displays) { display in
                        Label(
                            display.name,
                            systemImage: display.isVirtual ? "rectangle.on.rectangle" : "display"
                        )
                        .tag(display.id)
                    }
                }
                .pickerStyle(.inline)
            }
            Picker("Curve", selection: $curvatureSetting) {
                ForEach(NativeScreenCurvature.allCases) { curvature in
                    Text(curvature.title).tag(curvature.rawValue)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Label("Display", systemImage: "display.2")
        }
        .help("Choose which Mac desktop to show, and how much it curves around you")
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
    /// decoration rather than the only way back to the screen.
    private var homeOnlyControls: some View {
        HStack(spacing: 10) {
            Button {
                openWindow(id: "main", value: MainWindowID.shared)
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
        }
        .padding(8)
        .glassBackgroundEffect()
    }

    // MARK: - Keyboard Window

    /// True while the on-screen keyboard has been opened in its own window —
    /// tracked live off `WindowSessionRegistry`, so the button reads as a real
    /// toggle instead of only ever opening it (mirrors `RemoteDesktopView`).
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
            closing: [keyboardWindowKey, streamWindowKey, unityControlsWindowKey, audioWindowKey],
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
