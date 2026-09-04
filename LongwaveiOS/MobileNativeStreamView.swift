import SwiftUI
import AVFoundation
import UIKit

/// The Native desktop stream on a phone or tablet: the host's whole display as
/// HEVC, with touch input forwarded to the companion.
///
/// Same split as the VNC desktop (`MobileRemoteDesktopView`): the shared
/// `NativeStreamView` is a state machine of glass panels and per-window Unity
/// scenes for a spatial window, and none of that exists here. Everything below
/// the input layer — the session, the renderer, the two keyboard channels, the
/// Audio half of the connection — is the same `MacNativeStreamManager`. This
/// view supplies zoom + pan (a phone is far smaller than the Mac it shows), the
/// `MobilePointerSurface` touch model, and the chrome.
struct MobileNativeStreamView: View {
    @Environment(MacNativeStreamManager.self) private var screenManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewport = MobileViewport()
    /// The full ANSI grid, for caps a phone keyboard cannot type at all.
    @State private var showingKeyboard = false
    /// The system keyboard plus the modifier strip — the everyday typing path.
    @State private var typing = false
    @State private var showingAudioPanel = false
    @State private var showsChrome = true
    /// Where the current one-finger drag last was, so relative mode can measure
    /// deltas and absolute mode can hold the button down across the move.
    @State private var lastDragPoint: CGPoint?
    @State private var clickCadence = DoubleClickCadence()

    private var sink: MacNativeKeyboardSink { MacNativeKeyboardSink(manager: screenManager) }
    private var content: CGSize { screenManager.streamSize }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // 1×1 and transparent rather than zero-sized: a zero-size view
                // cannot reliably become first responder, and this is what
                // carries a paired Bluetooth keyboard into the session.
                MacNativeHardwareKeyboardView(screenManager: screenManager)
                    .frame(width: 1, height: 1)
                    .opacity(0)

                video(in: geometry.size)

                if screenManager.touchMode == .relative, content.width > 0 {
                    cursorOverlay(in: geometry.size)
                }

                MobilePointerSurface(
                    onClick: { click(at: $0, in: geometry.size, button: .left) },
                    onSecondaryClick: { click(at: $0, in: geometry.size, button: .right) },
                    onDragBegan: { dragBegan(at: $0, in: geometry.size) },
                    onDragMoved: { dragMoved(to: $0, in: geometry.size) },
                    onDragEnded: { dragEnded(at: $0, in: geometry.size) },
                    onScroll: { scroll(at: $0, delta: $1, in: geometry.size) },
                    onZoom: { viewport.magnify(by: $0, about: $1, content: content, in: geometry.size) },
                    onViewportPan: { viewport.pan(by: $0, content: content, in: geometry.size) },
                    onDoubleTap: {
                        withAnimation(.smooth(duration: 0.25)) {
                            viewport.toggleZoom(content: content, in: geometry.size)
                        }
                    }
                )

                if screenManager.state != .streaming {
                    statusOverlay
                }
            }
            .overlay(alignment: .top) {
                if let message = inputWarningMessage {
                    Label(message, systemImage: "computermouse")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(in: .capsule)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if showsChrome {
                    toolbar
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) { chromeToggle }
            // The desktop must not be resized by the software keyboard — the
            // video keeps its geometry and the strip rides above the keys.
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .safeAreaInset(edge: .bottom) {
            if typing {
                MobileKeyboardAccessory(
                    sink: sink,
                    isActive: $typing,
                    onOpenFullKeyboard: { showingKeyboard = true }
                )
            }
        }
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .sheet(isPresented: $showingKeyboard) { keyboardSheet }
        .sheet(isPresented: $showingAudioPanel) {
            NavigationStack {
                MobileAudioView()
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear { resumeIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { resumeIfNeeded() }
        }
        .onChange(of: screenManager.hostServesAudio) { _, servesAudio in
            guard !servesAudio else { return }
            if audioManager.liveEnabled { audioManager.liveEnabled = false }
            audioManager.disconnect()
        }
    }

    // MARK: - Session

    /// Recovers a stream that is on but not actually connected — the normal
    /// case after the app comes back from the background. A no-op when already
    /// running, so this is safe to call on every appear/activation.
    private func resumeIfNeeded() {
        if audioManager.liveEnabled, screenManager.hostServesAudio {
            audioManager.ensureConnected()
        }
        if screenManager.liveEnabled, !screenManager.isEnabled, let connection = screenManager.connection {
            screenManager.connect(to: connection)
        }
    }

    private func disconnectAll() {
        screenManager.forget()
        audioManager.userDisconnect()
        dismiss()
    }

    // MARK: - Video

    @ViewBuilder
    private func video(in size: CGSize) -> some View {
        if let layer = screenManager.displayLayer, content.width > 0 {
            let layout = viewport.layout(content: content, in: size)
            MobileNativeVideoView(displayLayer: layer)
                .frame(width: layout.drawn.width, height: layout.drawn.height)
                .position(
                    x: layout.origin.x + layout.drawn.width / 2,
                    y: layout.origin.y + layout.drawn.height / 2
                )
                .allowsHitTesting(false)
        }
    }

    /// Local pointer dot for relative mode — the host's own cursor is where
    /// the click will land, but nothing on screen says where that is until it
    /// moves.
    private func cursorOverlay(in size: CGSize) -> some View {
        let point = viewport.viewPoint(
            x: screenManager.virtualCursorX, y: screenManager.virtualCursorY,
            content: content, in: size
        )
        return Circle()
            .fill(.white.opacity(0.7))
            .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 1))
            .frame(width: 12, height: 12)
            .position(point)
            .allowsHitTesting(false)
    }

    private var statusOverlay: some View {
        VStack(spacing: 12) {
            if case .disconnected = screenManager.state {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
            Text(screenManager.state == .connected ? "Waiting for the first frame…" : screenManager.state.statusText)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .allowsHitTesting(false)
    }

    private var inputWarningMessage: String? {
        switch screenManager.mouseAvailability {
        case .disabled: return "Mouse control is off — enable it in the host's Native settings."
        case .accessibilityDenied: return "Mouse control needs Accessibility permission on the Mac."
        case .available, .unknown: return nil
        }
    }

    // MARK: - Chrome

    private var chromeToggle: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { showsChrome.toggle() }
        } label: {
            Image(systemName: showsChrome ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                .font(.title2)
                .foregroundStyle(.white, .black.opacity(0.35))
        }
        .padding(12)
        .accessibilityLabel(showsChrome ? "Hide controls" : "Show controls")
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            Button(action: disconnectAll) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Disconnect")

            Button {
                screenManager.touchMode = screenManager.touchMode == .absolute ? .relative : .absolute
            } label: {
                Image(systemName: screenManager.touchMode == .absolute
                      ? "hand.tap" : "rectangle.and.hand.point.up.left")
            }
            .accessibilityLabel(screenManager.touchMode == .absolute ? "Direct touch" : "Touchpad")

            Button(action: screenManager.rightClickAtDesktopCursor) {
                Image(systemName: "cursorarrow.click.2")
            }
            .disabled(!screenManager.canRightClickDesktop)
            .accessibilityLabel("Right-click")

            Button {
                typing.toggle()
            } label: {
                Image(systemName: "keyboard")
            }
            .tint(typing ? .accentColor : nil)
            .accessibilityLabel("Keyboard")

            if screenManager.hostServesAudio, audioManager.liveEnabled || audioManager.state != .idle {
                Button {
                    showingAudioPanel = true
                } label: {
                    Image(systemName: "hifispeaker")
                }
                .tint(audioManager.state == .streaming ? .accentColor : nil)
                .accessibilityLabel("Audio")
            }

            Divider().frame(height: 20)

            Text("\(Int((viewport.zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)

            Button {
                withAnimation(.smooth(duration: 0.25)) { viewport.reset() }
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .disabled(viewport.isDefault)
            .accessibilityLabel("Fit to screen")
        }
        .font(.title3)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(in: .capsule)
    }

    @ViewBuilder
    private var keyboardSheet: some View {
        NavigationStack {
            MobileVirtualKeyboardSheet(sink: sink)
                .navigationTitle("Keyboard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingKeyboard = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Input

    private var isRelative: Bool { screenManager.touchMode == .relative }

    private func point(_ p: CGPoint, in size: CGSize) -> (x: UInt16, y: UInt16)? {
        viewport.contentPoint(p, content: content, in: size)
    }

    private func click(at p: CGPoint, in size: CGSize, button: MacNativeStreamProtocol.MouseButton) {
        if isRelative {
            screenManager.clickAtVirtualCursor(button: button)
            return
        }
        guard let raw = point(p, in: size) else { return }
        // Snap a quick second tap onto the first one's pixel so the host reads
        // the pair as a double-click (see DoubleClickCadence).
        let target = button == .left ? clickCadence.resolve(raw) : raw
        screenManager.sendMouseDown(button: button, x: target.x, y: target.y)
        screenManager.sendMouseUp(button: button, x: target.x, y: target.y)
    }

    private func dragBegan(at p: CGPoint, in size: CGSize) {
        lastDragPoint = p
        guard !isRelative else {
            screenManager.pressMouseAtVirtualCursor(button: .left)
            return
        }
        guard let fb = point(p, in: size) else { return }
        screenManager.sendMouseDown(button: .left, x: fb.x, y: fb.y)
    }

    private func dragMoved(to p: CGPoint, in size: CGSize) {
        defer { lastDragPoint = p }
        if isRelative {
            guard let previous = lastDragPoint else { return }
            // Relative mode moves the cursor by the finger's delta, scaled out of
            // screen points into stream pixels so the gain matches the zoom.
            let layout = viewport.layout(content: content, in: size)
            guard layout.scale > 0 else { return }
            screenManager.moveVirtualCursor(
                dx: (p.x - previous.x) / layout.scale,
                dy: (p.y - previous.y) / layout.scale
            )
            return
        }
        guard let fb = point(p, in: size) else { return }
        screenManager.sendMouseMove(x: fb.x, y: fb.y)
    }

    private func dragEnded(at p: CGPoint, in size: CGSize) {
        defer { lastDragPoint = nil }
        guard !isRelative else {
            screenManager.releaseMouseAtVirtualCursor(button: .left)
            return
        }
        guard let fb = point(p, in: size) else { return }
        screenManager.sendMouseUp(button: .left, x: fb.x, y: fb.y)
    }

    /// One scroll line per this many points of two-finger movement. Tuned so a
    /// comfortable swipe scrolls about as far as it would on a trackpad.
    private static let pointsPerScrollLine: CGFloat = 24
    /// Ignore sub-pixel jitter, which would otherwise emit a line per frame
    /// while two fingers merely rest on the glass.
    private static let scrollDeadZone: CGFloat = 2

    private func scroll(at p: CGPoint, delta: CGSize, in size: CGSize) {
        // Whichever axis dominates wins, so a slightly diagonal swipe doesn't
        // scroll two directions at once.
        let vertical = abs(delta.height) >= abs(delta.width)
        let magnitude = vertical ? abs(delta.height) : abs(delta.width)
        guard magnitude >= Self.scrollDeadZone else { return }
        let lines = Int16(clamping: Int(max(1, (magnitude / Self.pointsPerScrollLine).rounded())))
        // Finger down = content follows = wheel up; the wire carries +Y as up.
        let deltaY: Int16 = vertical ? (delta.height > 0 ? lines : -lines) : 0
        let deltaX: Int16 = vertical ? 0 : (delta.width > 0 ? lines : -lines)
        if isRelative {
            screenManager.scrollAtVirtualCursor(deltaX: deltaX, deltaY: deltaY)
            return
        }
        guard let fb = point(p, in: size) else { return }
        screenManager.sendScroll(x: fb.x, y: fb.y, deltaX: deltaX, deltaY: deltaY)
    }
}

/// Hosts the desktop stream's `AVSampleBufferDisplayLayer`, kept sized to the
/// view so zoom and pan can be expressed as the view's frame.
private final class MobileNativeLayerView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .black
        displayLayer.videoGravity = .resize
        layer.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct MobileNativeVideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> MobileNativeLayerView {
        MobileNativeLayerView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: MobileNativeLayerView, context: Context) {}
}
