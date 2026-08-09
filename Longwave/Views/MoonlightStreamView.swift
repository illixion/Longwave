#if MOONLIGHT_ENABLED
import SwiftUI
import AVFoundation
import UIKit
import GameController
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

/// SwiftUI view that displays the Moonlight video stream and handles input.
struct MoonlightStreamView: View {
    @Environment(MoonlightConnectionManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var showStats = false
    @State private var showDisconnectAlert = false

    // Track previous drag translation to compute incremental deltas (relative mode)
    @State private var previousDragTranslation: CGSize = .zero
    // Track whether a drag is actively holding the mouse button (absolute mode)
    @State private var absoluteDragActive = false
    // Gaze "drag lock": a press-and-hold holds the left button down so a
    // subsequent pinch-drag drags; a single tap releases it. (It was a
    // double-tap, which left no gesture free to double-click with.) Lets gaze users
    // drag (move windows, select) without a physical mouse button.
    @State private var dragLocked = false
    @State private var clickCadence = DoubleClickCadence()
    @State private var dragLockStartedAt: Date?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 1×1 transparent hardware keyboard capture, kept bottommost so it
            // never intercepts gestures. A zero-size / zero-alpha view can't
            // reliably become first responder on visionOS.
            MoonlightHardwareKeyboardView()
                .frame(width: 1, height: 1)

            if let layer = manager.displayLayer {
                GeometryReader { geometry in
                    VideoDisplayView(displayLayer: layer)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .gesture(mouseDragGesture(in: geometry.size))
                        .gesture(scrollGesture)
                        .onContinuousHover { phase in
                            // Track whether the pointer is over the stream content
                            // (vs the app's controls) so GCMouse clicks on the
                            // toolbar aren't sent to the remote. Also, in absolute
                            // mode, position the pointer to match. Relative mode
                            // gets raw deltas from GCMouse instead.
                            switch phase {
                            case .active(let location):
                                manager.setPointerOverContent(true)
                                if manager.touchMode == .absolute {
                                    let (streamX, streamY) = mapToStreamCoordinates(location, in: geometry.size)
                                    LiSendMousePositionEvent(streamX, streamY, Int16(manager.streamWidth), Int16(manager.streamHeight))
                                }
                            case .ended:
                                manager.setPointerOverContent(false)
                            }
                        }
                        // Press and hold = begin click+drag lock; single tap =
                        // left click (or release a drag lock), and two quick
                        // taps double-click. Right click is the toolbar button.
                        // All suppressed when a physical mouse is connected — it
                        // owns clicks via GCMouse, and visionOS would otherwise
                        // double-deliver each click as a tap too.
                        .gesture(dragLockGesture)
                        .gesture(SpatialTapGesture(count: 1).onEnded { value in
                            singleTap(at: value.location, in: geometry.size)
                        })
                }
                .ignoresSafeArea()
            } else {
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

            // Statistics overlay
            if showStats {
                StreamStatsOverlay()
                    .environment(manager)
            }
        }
        .overlay(alignment: .top) {
            if dragLocked {
                Label("Dragging — tap to drop", systemImage: "hand.draw")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassBackgroundEffect()
                    .padding(.top, 8)
            }
        }
        .handlesGameControllerEvents(matching: .gamepad)
        .onChange(of: scenePhase) { _, newPhase in
            // Headset donned / window refocused: retry a dropped stream
            // immediately instead of waiting out the backoff timer.
            if newPhase == .active {
                manager.sceneBecameActive()
            }
        }
        .onDisappear {
            manager.stopStreaming()
            dismissWindow(id: "moonlight-keyboard")
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
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

    // MARK: - Teardown

    /// Hands off to the connection manager, then closes the stream window and
    /// its keyboard. `dismissWindow(id:)` rather than `dismiss()` so the close
    /// targets a known scene, and ordered behind the main window because
    /// visionOS won't let an app close its own last window.
    private func closeStreamWindow() {
        WindowSessionRegistry.shared.closeAfterSurfacingMain(using: openWindow) {
            dismissWindow(id: "moonlight-keyboard")
            dismissWindow(id: "moonlight-stream")
        }
    }

    // MARK: - Tap Handling

    /// Position the pointer for a tap in absolute mode (no-op in relative mode,
    /// where the cursor is wherever prior motion left it).
    private func positionForTap(at location: CGPoint, in viewSize: CGSize) {
        guard manager.touchMode == .absolute else { return }
        let (streamX, streamY) = mapToStreamCoordinates(location, in: viewSize)
        LiSendMousePositionEvent(streamX, streamY, Int16(manager.streamWidth), Int16(manager.streamHeight))
    }

    /// Single tap: left click, or release an active drag lock.
    private func singleTap(at location: CGPoint, in viewSize: CGSize) {
        guard !manager.isMouseConnected else { return }
        if dragLocked {
            // Lifting off the press-and-hold that started the lock can arrive
            // here as a tap; that would release it instantly.
            if let started = dragLockStartedAt, Date().timeIntervalSince(started) < 0.4 { return }
            positionForTap(at: location, in: viewSize)
            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
            dragLocked = false
        } else {
            // Position the second of two quick taps where the first one landed,
            // so the host reads them as a double-click rather than two clicks a
            // few pixels apart (see DoubleClickCadence).
            positionForTap(at: snappedTapLocation(location, in: viewSize), in: viewSize)
            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_LEFT)
            LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
        }
    }

    /// Runs a tap through the double-click cadence in view space — Moonlight
    /// positions via `LiSendMousePositionEvent`, so the snap has to happen
    /// before the coordinate mapping rather than after it.
    private func snappedTapLocation(_ location: CGPoint, in viewSize: CGSize) -> CGPoint {
        guard manager.touchMode == .absolute,
              viewSize.width > 0, viewSize.height > 0,
              location.x >= 0, location.y >= 0,
              location.x <= CGFloat(UInt16.max), location.y <= CGFloat(UInt16.max)
        else { return location }
        let snapped = clickCadence.resolve((x: UInt16(location.x), y: UInt16(location.y)))
        return CGPoint(x: CGFloat(snapped.x), y: CGFloat(snapped.y))
    }

    /// Press and hold = grab. The hover handler already positions the host
    /// cursor in absolute mode, so this presses wherever it is — the same rule
    /// the Right-click button uses.
    private var dragLockGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55)
            .onEnded { _ in
                guard !manager.isMouseConnected, !dragLocked else { return }
                LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_LEFT)
                dragLocked = true
                dragLockStartedAt = Date()
            }
    }

    /// Right click at the host's current cursor position (toolbar button).
    private func rightClickAtCurrentPosition() {
        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_RIGHT)
        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_RIGHT)
    }

    // MARK: - Coordinate Mapping

    /// Maps a view-space point to stream-resolution coordinates, accounting for aspect-ratio letterboxing.
    private func mapToStreamCoordinates(_ point: CGPoint, in viewSize: CGSize) -> (Int16, Int16) {
        let streamW = CGFloat(manager.streamWidth)
        let streamH = CGFloat(manager.streamHeight)
        let streamAspect = streamW / streamH
        let viewAspect = viewSize.width / viewSize.height

        let renderRect: CGRect
        if viewAspect > streamAspect {
            // Letterboxed (pillarboxed) — black bars on left/right
            let renderHeight = viewSize.height
            let renderWidth = renderHeight * streamAspect
            let offsetX = (viewSize.width - renderWidth) / 2
            renderRect = CGRect(x: offsetX, y: 0, width: renderWidth, height: renderHeight)
        } else {
            // Letterboxed — black bars on top/bottom
            let renderWidth = viewSize.width
            let renderHeight = renderWidth / streamAspect
            let offsetY = (viewSize.height - renderHeight) / 2
            renderRect = CGRect(x: 0, y: offsetY, width: renderWidth, height: renderHeight)
        }

        // Clamp point within render rect and normalize to stream coordinates
        let clampedX = min(max(point.x, renderRect.minX), renderRect.maxX)
        let clampedY = min(max(point.y, renderRect.minY), renderRect.maxY)

        let normalizedX = (clampedX - renderRect.minX) / renderRect.width
        let normalizedY = (clampedY - renderRect.minY) / renderRect.height

        let x = Int16(normalizedX * streamW)
        let y = Int16(normalizedY * streamH)
        return (x, y)
    }

    // MARK: - Mouse Drag Gesture

    private func mouseDragGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard !manager.isMouseConnected else { return }
                if manager.touchMode == .absolute {
                    let (streamX, streamY) = mapToStreamCoordinates(value.location, in: viewSize)
                    LiSendMousePositionEvent(streamX, streamY, Int16(manager.streamWidth), Int16(manager.streamHeight))
                    // In drag-lock the button is already held (from a double-tap);
                    // don't re-press. Otherwise this is a plain click-and-drag:
                    // press the button on the first drag update.
                    if !dragLocked && !absoluteDragActive {
                        absoluteDragActive = true
                        LiSendMouseButtonEvent(Int8(BUTTON_ACTION_PRESS), BUTTON_LEFT)
                    }
                } else {
                    // Relative: send incremental deltas (the button, if any, is
                    // held remotely — by drag-lock — so this drags).
                    let dx = value.translation.width - previousDragTranslation.width
                    let dy = value.translation.height - previousDragTranslation.height
                    previousDragTranslation = value.translation
                    LiSendMouseMoveEvent(Int16(dx), Int16(dy))
                }
            }
            .onEnded { value in
                previousDragTranslation = .zero
                guard !manager.isMouseConnected else { return }
                // A plain click-and-drag releases on lift. A drag-lock keeps the
                // button held until a single tap releases it.
                if manager.touchMode == .absolute && absoluteDragActive && !dragLocked {
                    let (streamX, streamY) = mapToStreamCoordinates(value.location, in: viewSize)
                    LiSendMousePositionEvent(streamX, streamY, Int16(manager.streamWidth), Int16(manager.streamHeight))
                    LiSendMouseButtonEvent(Int8(BUTTON_ACTION_RELEASE), BUTTON_LEFT)
                }
                absoluteDragActive = false
            }
    }

    // MARK: - Scroll Gesture

    private var scrollGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification - 1.0
                let scrollAmount = Int16(delta * 120)
                if scrollAmount != 0 {
                    LiSendHighResScrollEvent(scrollAmount)
                }
            }
    }

    // MARK: - Controls Bar (Ornament)

    private var controlsBar: some View {
        HStack(spacing: 16) {
            Button {
                manager.setTouchMode(manager.touchMode == .absolute ? .relative : .absolute)
            } label: {
                Label(
                    manager.touchMode == .absolute ? "Direct" : "Touchpad",
                    systemImage: manager.touchMode == .absolute
                        ? "hand.tap" : "rectangle.and.hand.point.up.left"
                )
            }

            Button {
                rightClickAtCurrentPosition()
            } label: {
                Label("Right-click", systemImage: "cursorarrow.click.2")
            }

            Button {
                openWindow(id: "moonlight-keyboard")
            } label: {
                Label("Keyboard", systemImage: "keyboard")
            }

            Button {
                showStats.toggle()
            } label: {
                Label("Stats", systemImage: "chart.bar")
            }
            .tint(showStats ? .accentColor : nil)

            Button {
                manager.toggleSpatialAudio()
            } label: {
                Label("Spatial Audio", systemImage: "person.spatialaudio.stereo.fill")
            }
            .labelStyle(.iconOnly)
            .tint(manager.spatialAudioEnabled ? .accentColor : nil)
            .help(manager.spatialAudioEnabled
                  ? "Spatial Audio On — head-tracked rendering"
                  : "Spatial Audio Off — flat stereo playback")

            Button {
                openWindow(id: "main", value: MainWindowID.shared)
            } label: {
                Label("Connections", systemImage: "house")
            }
            .labelStyle(.iconOnly)
            .help("Open the connection manager")

            Button(role: .destructive) {
                showDisconnectAlert = true
            } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .help("Disconnect")
        }
        .buttonStyle(.bordered)
        .padding(12)
        .glassBackgroundEffect()
    }
}
#endif
