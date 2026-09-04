#if MOONLIGHT_ENABLED
import SwiftUI
import AVFoundation
import UIKit
import GameController
@preconcurrency import MoonlightCommonC

/// A Moonlight game stream on a phone or tablet.
///
/// Separate from the shared `MoonlightStreamView` for the same reason the VNC
/// desktop is: that view is built around a gaze pointer, an ornament bar and
/// its own window, none of which exist here. The session underneath — the
/// connection manager, the linked copy of moonlight-common-c it streams
/// through, the video layer, the gamepad / mouse / keyboard bridges — is the
/// same. This view supplies the touch model and the chrome.
///
/// Touch mapping follows `MobilePointerSurface` (tap = click, two-finger tap =
/// right click, one-finger drag = drag or move, two-finger drag = scroll). In
/// **Direct** mode the finger is the pointer and every event carries an
/// absolute position on the stream; in **Touchpad** mode a drag moves the host
/// cursor by the finger's delta, which is what a game that captures the mouse
/// needs. No double tap: the tap recognizer would have to wait for a second
/// tap that never comes, and a game notices the delay.
struct MobileMoonlightStreamView: View {
    @Environment(MoonlightConnectionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var showStats = false
    @State private var showDisconnectAlert = false
    /// The system keyboard plus the modifier strip — the everyday typing path.
    @State private var typing = false
    /// The full ANSI grid, for caps a phone keyboard cannot type at all.
    @State private var showingKeyboard = false
    @State private var showsChrome = true
    /// Where the current one-finger drag last was, so Touchpad mode can measure
    /// deltas and Direct mode can hold the button down across the move.
    @State private var lastDragPoint: CGPoint?
    /// Sub-pixel remainders for Touchpad mode, so a slow drag isn't truncated
    /// to nothing.
    @State private var relativeRemainder = CGSize.zero

    /// Finger travel → host cursor travel in Touchpad mode. A little more than
    /// 1:1: a phone screen is a small trackpad.
    private static let touchpadGain: CGFloat = 1.6

    private var sink: MoonlightKeyboardSink { MoonlightKeyboardSink(library: manager.library) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // 1×1 and transparent rather than zero-sized: a zero-size view
                // cannot reliably become first responder. This is the fallback
                // for a paired keyboard when GameController isn't reporting it
                // (the GCKeyboard bridge in the manager takes precedence).
                MoonlightHardwareKeyboardView(library: manager.library)
                    .frame(width: 1, height: 1)
                    .opacity(0)

                if let layer = manager.displayLayer {
                    MobileVideoLayerView(displayLayer: layer)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                MobilePointerSurface(
                    onClick: { click(at: $0, in: geometry.size, button: BUTTON_LEFT) },
                    onSecondaryClick: { click(at: $0, in: geometry.size, button: BUTTON_RIGHT) },
                    onDragBegan: { dragBegan(at: $0, in: geometry.size) },
                    onDragMoved: { dragMoved(to: $0, in: geometry.size) },
                    onDragEnded: { dragEnded(at: $0, in: geometry.size) },
                    onScroll: { _, delta in scroll(delta) },
                    onZoom: { _, _ in },
                    onViewportPan: { _ in },
                    onDoubleTap: nil
                )

                if manager.displayLayer == nil || manager.connectionState != .streaming {
                    statusOverlay
                }

                if showStats {
                    StreamStatsOverlay()
                        .environment(manager)
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
            // The stream must not be resized by the software keyboard — the
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
        .handlesGameControllerEvents(matching: .gamepad)
        .sheet(isPresented: $showingKeyboard) { keyboardSheet }
        .alert("Disconnect", isPresented: $showDisconnectAlert) {
            Button("Keep Running") {
                manager.stopStreaming()
                dismiss()
            }
            Button("End Session", role: .destructive) {
                manager.stopStreamingAndQuit()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to end the session on the server, or keep it running for later?")
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from the background: retry a dropped stream immediately
            // instead of waiting out the backoff timer.
            if phase == .active { manager.sceneBecameActive() }
        }
    }

    // MARK: - Status

    private var statusOverlay: some View {
        VStack(spacing: 16) {
            if case .error = manager.connectionState {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
            Text(manager.statusMessage)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if case .error = manager.connectionState, manager.canReconnect {
                Button("Reconnect Now") { manager.reconnectNow() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .allowsHitTesting(manager.canReconnect)
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
                showDisconnectAlert = true
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Disconnect")

            Button {
                manager.setTouchMode(manager.touchMode == .absolute ? .relative : .absolute)
            } label: {
                Image(systemName: manager.touchMode == .absolute
                      ? "hand.tap" : "rectangle.and.hand.point.up.left")
            }
            .accessibilityLabel(manager.touchMode == .absolute ? "Direct touch" : "Touchpad")

            Button {
                manager.library.clickMouseButton(BUTTON_RIGHT)
            } label: {
                Image(systemName: "cursorarrow.click.2")
            }
            .accessibilityLabel("Right-click")

            Button {
                typing.toggle()
            } label: {
                Image(systemName: "keyboard")
            }
            .tint(typing ? .accentColor : nil)
            .accessibilityLabel("Keyboard")

            Button {
                showStats.toggle()
            } label: {
                Image(systemName: "chart.bar")
            }
            .tint(showStats ? .accentColor : nil)
            .accessibilityLabel("Statistics")
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
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Ctrl+Alt+Del") { sink.sendSecureAttention() }
                            .tint(.red)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingKeyboard = false }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Input

    private var isRelative: Bool { manager.touchMode == .relative }

    /// Direct mode: put the host pointer where the finger is.
    private func position(at point: CGPoint, in size: CGSize) {
        let stream = MoonlightPointerMapping.streamPoint(
            for: point, streamWidth: manager.streamWidth, streamHeight: manager.streamHeight, in: size
        )
        manager.library.sendMousePosition(
            x: stream.x, y: stream.y,
            referenceWidth: Int16(clamping: manager.streamWidth),
            referenceHeight: Int16(clamping: manager.streamHeight)
        )
    }

    private func click(at point: CGPoint, in size: CGSize, button: Int32) {
        if !isRelative { position(at: point, in: size) }
        manager.library.clickMouseButton(button)
    }

    private func dragBegan(at point: CGPoint, in size: CGSize) {
        lastDragPoint = point
        relativeRemainder = .zero
        guard !isRelative else { return }
        position(at: point, in: size)
        manager.library.sendMouseButton(BUTTON_ACTION_PRESS, BUTTON_LEFT)
    }

    private func dragMoved(to point: CGPoint, in size: CGSize) {
        defer { lastDragPoint = point }
        if isRelative {
            guard let previous = lastDragPoint else { return }
            // Carry the fractional part so a slow drag still moves the cursor.
            let dx = (point.x - previous.x) * Self.touchpadGain + relativeRemainder.width
            let dy = (point.y - previous.y) * Self.touchpadGain + relativeRemainder.height
            let ix = dx.rounded(.towardZero)
            let iy = dy.rounded(.towardZero)
            relativeRemainder = CGSize(width: dx - ix, height: dy - iy)
            if ix != 0 || iy != 0 {
                manager.library.sendMouseMove(dx: Int16(clamping: Int(ix)), dy: Int16(clamping: Int(iy)))
            }
            return
        }
        position(at: point, in: size)
    }

    private func dragEnded(at point: CGPoint, in size: CGSize) {
        lastDragPoint = nil
        guard !isRelative else { return }
        position(at: point, in: size)
        manager.library.sendMouseButton(BUTTON_ACTION_RELEASE, BUTTON_LEFT)
    }

    /// Two-finger movement → high-resolution wheel ticks. 120 is one notch of
    /// a physical wheel; a full-screen swipe is a few notches.
    private static let pointsPerNotch: CGFloat = 40

    private func scroll(_ delta: CGSize) {
        let vertical = abs(delta.height) >= abs(delta.width)
        let travel = vertical ? delta.height : delta.width
        let amount = Int(travel / Self.pointsPerNotch * 120)
        guard amount != 0 else { return }
        if vertical {
            manager.library.sendHighResScroll(Int16(clamping: amount))
        } else {
            manager.library.sendHighResHScroll(Int16(clamping: -amount))
        }
    }
}

/// Hosts the session's `AVSampleBufferDisplayLayer`, keeping it sized to the
/// view (same shape as the visionOS and macOS video views).
private final class MobileVideoLayerUIView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
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

private struct MobileVideoLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> MobileVideoLayerUIView {
        MobileVideoLayerUIView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: MobileVideoLayerUIView, context: Context) {}
}
#endif
