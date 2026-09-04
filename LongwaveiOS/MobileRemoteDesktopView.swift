import SwiftUI
import RoyalVNCKit

/// The remote desktop on a phone or tablet.
///
/// Separate from the shared `RemoteDesktopView` rather than a restyle of it,
/// because the input model genuinely differs: visionOS aims a gaze ray and
/// pinches, so its view maps one indirect pointer and needs no zoom at all.
/// Here the screen *is* the pointer, a phone is far smaller than the desktop it
/// is showing, and zoom plus pan are load-bearing. Everything below the input
/// layer — the connection, the framebuffer, credentials, companion audio — is
/// the same shared manager.
struct MobileRemoteDesktopView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.dismiss) private var dismiss

    /// Zoom and pan — shared with the Native desktop view (`MobileViewport`).
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

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // 1×1 and transparent rather than zero-sized: a zero-size view
                // cannot reliably become first responder, and this is what
                // carries a paired Bluetooth keyboard into the session.
                HardwareKeyboardView(connectionManager: connectionManager)
                    .frame(width: 1, height: 1)
                    .opacity(0)

                framebuffer(in: geometry.size)

                if connectionManager.touchMode == .relative {
                    cursorOverlay(in: geometry.size)
                }

                MobilePointerSurface(
                    onClick: { click(at: $0, in: geometry.size, button: .left) },
                    onSecondaryClick: { click(at: $0, in: geometry.size, button: .right) },
                    onDragBegan: { dragBegan(at: $0, in: geometry.size) },
                    onDragMoved: { dragMoved(to: $0, in: geometry.size) },
                    onDragEnded: { dragEnded(at: $0, in: geometry.size) },
                    onScroll: { scroll(at: $0, delta: $1, in: geometry.size) },
                    onZoom: { magnify(by: $0, about: $1, in: geometry.size) },
                    onViewportPan: { panViewport(by: $0, in: geometry.size) },
                    onDoubleTap: { toggleZoom(in: geometry.size) }
                )

                if !connectionManager.connectionState.isActive || connectionManager.framebufferImage == nil {
                    statusOverlay
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
            // framebuffer keeps its geometry and the strip rides above the keys.
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .safeAreaInset(edge: .bottom) {
            if typing {
                MobileKeyboardAccessory(
                    sink: VNCKeyboardSink(manager: connectionManager),
                    isActive: $typing,
                    onOpenFullKeyboard: { showingKeyboard = true }
                )
            }
        }
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .sheet(isPresented: Bindable(connectionManager).isCredentialPromptPresented) {
            CredentialPromptView()
                .environment(connectionManager)
        }
        .sheet(isPresented: $showingKeyboard) { keyboardSheet }
        .sheet(isPresented: $showingAudioPanel) {
            NavigationStack {
                MobileAudioView()
            }
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Framebuffer

    @ViewBuilder
    private func framebuffer(in size: CGSize) -> some View {
        if let image = connectionManager.framebufferImage {
            let layout = self.layout(in: size)
            Image(decorative: image, scale: 1)
                .resizable()
                // Nearest-neighbour past 1:1 — a remote desktop is text, and
                // smoothing it into grey mush is worse than visible pixels.
                .interpolation(layout.scale >= 1 ? .none : .medium)
                .frame(width: layout.drawn.width, height: layout.drawn.height)
                .position(
                    x: layout.origin.x + layout.drawn.width / 2,
                    y: layout.origin.y + layout.drawn.height / 2
                )
                .allowsHitTesting(false)
        }
    }

    /// Local pointer dot for relative mode. macOS Screen Sharing doesn't draw the
    /// remote cursor, so without this there is nothing on screen saying where the
    /// click will land.
    private func cursorOverlay(in size: CGSize) -> some View {
        let layout = self.layout(in: size)
        let point = CGPoint(
            x: layout.origin.x + CGFloat(connectionManager.virtualCursorX) * layout.scale,
            y: layout.origin.y + CGFloat(connectionManager.virtualCursorY) * layout.scale
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
            if connectionManager.connectionState.isActive {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
            Text(connectionManager.connectionState.statusText)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .allowsHitTesting(false)
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
            Button {
                connectionManager.disconnect()
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Disconnect")

            Button {
                typing.toggle()
            } label: {
                Image(systemName: "keyboard")
            }
            .tint(typing ? .accentColor : nil)
            .accessibilityLabel("Keyboard")

            if connectionManager.hasCompanionAudio {
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
                resetZoom()
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
            MobileVirtualKeyboardSheet(sink: VNCKeyboardSink(manager: connectionManager))
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

    // MARK: - Layout and coordinate mapping

    /// Where the framebuffer is drawn, for the current zoom and pan — the single
    /// source of truth for rendering *and* hit-testing (see `MobileViewport`).
    private func layout(in size: CGSize) -> MobileViewport.Layout {
        viewport.layout(content: connectionManager.framebufferSize, in: size)
    }

    /// View point → framebuffer pixel, or nil for a touch outside the desktop.
    private func framebufferPoint(_ point: CGPoint, in size: CGSize) -> (x: UInt16, y: UInt16)? {
        viewport.contentPoint(point, content: connectionManager.framebufferSize, in: size)
    }

    private var isRelative: Bool {
        connectionManager.touchMode == .relative
    }

    // MARK: - Input

    private func click(at point: CGPoint, in size: CGSize, button: VNCMouseButton) {
        if isRelative {
            connectionManager.clickAtVirtualCursor(button: button)
            return
        }
        guard let p = framebufferPoint(point, in: size) else { return }
        connectionManager.sendMouseMove(x: p.x, y: p.y)
        connectionManager.sendMouseDown(button: button, x: p.x, y: p.y)
        connectionManager.sendMouseUp(button: button, x: p.x, y: p.y)
    }

    private func dragBegan(at point: CGPoint, in size: CGSize) {
        lastDragPoint = point
        guard !isRelative else {
            connectionManager.pressMouseAtVirtualCursor(button: .left)
            return
        }
        guard let p = framebufferPoint(point, in: size) else { return }
        connectionManager.sendMouseMove(x: p.x, y: p.y)
        connectionManager.sendMouseDown(button: .left, x: p.x, y: p.y)
    }

    private func dragMoved(to point: CGPoint, in size: CGSize) {
        defer { lastDragPoint = point }
        if isRelative {
            guard let previous = lastDragPoint else { return }
            // Relative mode moves the cursor by the finger's delta, scaled out of
            // screen points into framebuffer pixels so the gain matches the zoom.
            let layout = self.layout(in: size)
            guard layout.scale > 0 else { return }
            connectionManager.moveVirtualCursor(
                dx: (point.x - previous.x) / layout.scale,
                dy: (point.y - previous.y) / layout.scale
            )
            return
        }
        guard let p = framebufferPoint(point, in: size) else { return }
        connectionManager.sendMouseMove(x: p.x, y: p.y)
    }

    private func dragEnded(at point: CGPoint, in size: CGSize) {
        defer { lastDragPoint = nil }
        guard !isRelative else {
            connectionManager.releaseMouseAtVirtualCursor(button: .left)
            return
        }
        guard let p = framebufferPoint(point, in: size) else { return }
        connectionManager.sendMouseUp(button: .left, x: p.x, y: p.y)
    }

    /// One wheel step per this many points of two-finger movement. Tuned so a
    /// comfortable swipe scrolls about as far as it would on a trackpad.
    private static let pointsPerScrollStep: CGFloat = 24
    /// Ignore sub-pixel jitter, which would otherwise emit a wheel step per frame
    /// while two fingers merely rest on the glass.
    private static let scrollDeadZone: CGFloat = 2

    private func scroll(at point: CGPoint, delta: CGSize, in size: CGSize) {
        // Whichever axis dominates wins, so a slightly diagonal swipe doesn't
        // scroll two directions at once.
        let vertical = abs(delta.height) >= abs(delta.width)
        let magnitude = vertical ? abs(delta.height) : abs(delta.width)
        guard magnitude >= Self.scrollDeadZone else { return }
        let steps = UInt32(max(1, (magnitude / Self.pointsPerScrollStep).rounded()))
        let wheel: VNCMouseWheel = vertical
            ? (delta.height > 0 ? .up : .down)
            : (delta.width > 0 ? .left : .right)
        if isRelative {
            connectionManager.scrollAtVirtualCursor(wheel: wheel, steps: steps)
            return
        }
        guard let p = framebufferPoint(point, in: size) else { return }
        connectionManager.sendScroll(wheel: wheel, x: p.x, y: p.y, steps: steps)
    }

    private func magnify(by factor: CGFloat, about anchor: CGPoint, in size: CGSize) {
        viewport.magnify(by: factor, about: anchor, content: connectionManager.framebufferSize, in: size)
    }

    private func panViewport(by delta: CGSize, in size: CGSize) {
        viewport.pan(by: delta, content: connectionManager.framebufferSize, in: size)
    }

    /// Double tap toggles between fitting the desktop and showing it at true
    /// pixel size, which is the zoom that actually matters for reading text.
    private func toggleZoom(in size: CGSize) {
        withAnimation(.smooth(duration: 0.25)) {
            viewport.toggleZoom(content: connectionManager.framebufferSize, in: size)
        }
    }

    private func resetZoom() {
        withAnimation(.smooth(duration: 0.25)) {
            viewport.reset()
        }
    }
}
