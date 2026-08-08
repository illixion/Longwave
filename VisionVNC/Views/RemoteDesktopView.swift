import SwiftUI
import RoyalVNCKit

struct RemoteDesktopView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewSize: CGSize = .zero
    @State private var isDragging = false
    @State private var previousDragTranslation: CGSize = .zero
    @State private var showAudioPanel = false
    // Gaze "drag lock": a press-and-hold holds the left button down so a
    // subsequent pinch-drag drags; a single tap releases it. (It was a
    // double-tap, which left no gesture free to double-click with.)
    @State private var dragLocked = false
    @State private var clickCadence = DoubleClickCadence()
    @State private var dragLockStartedAt: Date?

    var body: some View {
        Group {
            if connectionManager.isTrackpadOnly {
                // Trackpad-only: no NavigationStack — its glass background blocks transparency
                coreContent
                    .overlay(alignment: .bottom) {
                        toolbar
                            .padding(.bottom, 16)
                    }
            } else {
                NavigationStack {
                    coreContent
                        .navigationTitle(connectionManager.connectionTitle)
                        .overlay(alignment: .bottom) {
                            toolbar
                                .padding(.bottom, 16)
                        }
                }
                .glassBackgroundEffect()
            }
        }
        .sheet(isPresented: Bindable(connectionManager).isCredentialPromptPresented) {
            CredentialPromptView()
        }
        .onDisappear {
            // When the window is closed (by system close button or programmatically),
            // ensure the VNC connection is torn down and keyboard window is closed.
            dismissWindow(id: "keyboard")
            if connectionManager.connectionState.isActive {
                connectionManager.disconnect()
            }
        }
        .onChange(of: connectionManager.connectionState) { _, newValue in
            if case .disconnected = newValue {
                // Server-initiated disconnect: close windows after a brief delay
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    // Surface the connection manager and wait for it: visionOS
                    // won't let an app close its own last window.
                    WindowSessionRegistry.shared.closeAfterSurfacingMain(using: openWindow) {
                        dismissWindow(id: "keyboard")
                        dismissWindow(id: "remote-desktop")
                    }
                }
            }
        }
    }

    // MARK: - Core Content

    @ViewBuilder
    private var coreContent: some View {
        ZStack {
            // Invisible (1×1) hardware keyboard capture. A zero-size / zero-alpha
            // view can't reliably become first responder on visionOS, so keep it
            // 1×1 and transparent-but-present instead. It's the bottommost ZStack
            // child, so it never intercepts gestures.
            HardwareKeyboardView(connectionManager: connectionManager)
                .frame(width: 1, height: 1)

            GeometryReader { geometry in
                ZStack {
                    if connectionManager.isTrackpadOnly {
                        if connectionManager.connectionState == .connected {
                            Color.white.opacity(0.001) // Near-invisible but captures taps
                            cornerBrackets
                        } else {
                            statusView
                        }
                    } else if let cgImage = connectionManager.framebufferImage {
                        Image(uiImage: UIImage(cgImage: cgImage))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Virtual cursor indicator for touchpad mode. macOS Screen
                        // Sharing doesn't draw the remote cursor, so in relative
                        // mode this local dot is the only pointer indicator.
                        if connectionManager.touchMode == .relative,
                           connectionManager.framebufferSize.width > 0 {
                            cursorOverlay
                        }
                    } else {
                        statusView
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                // Press and hold = begin click+drag lock; single tap = left
                // click (or release a drag lock), and two quick taps
                // double-click. Right click is the toolbar button.
                .gesture(dragLockGesture)
                .gesture(tapGesture)
                .gesture(dragGesture)
                .gesture(scrollGesture)
                .onContinuousHover { phase in
                    // Bluetooth-mouse / pointer motion without a button held.
                    // A DragGesture only fires while a button is down, so plain
                    // moves were never transmitted — hover fills that gap. Use
                    // only the absolute location (gaze can warp the pointer, so
                    // derived deltas would jump). Click-drag still uses dragGesture.
                    if case .active(let location) = phase,
                       let point = translator?.viewToFramebuffer(location) {
                        connectionManager.moveCursorAbsolute(x: point.x, y: point.y)
                    }
                }
                .onAppear {
                    viewSize = geometry.size
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewSize = newSize
                }
            }
        }
        .overlay(alignment: .top) {
            if dragLocked { dragLockBadge }
        }
    }

    /// Shown while a gaze drag lock holds the left button down.
    private var dragLockBadge: some View {
        Label("Dragging — tap to drop", systemImage: "hand.draw")
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassBackgroundEffect()
            .padding(.top, 8)
    }

    // MARK: - Status View

    private var statusView: some View {
        VStack(spacing: 20) {
            if case .disconnected(let error) = connectionManager.connectionState {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text(error ?? "Disconnected")
                    .font(.headline)
                Button("Close") {
                    WindowSessionRegistry.shared.closeAfterSurfacingMain(using: openWindow) {
                        dismissWindow(id: "remote-desktop")
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                Text(connectionManager.connectionState.statusText)
                    .font(.headline)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 20) {
            Button(action: {
                connectionManager.touchMode = connectionManager.touchMode == .absolute
                    ? .relative : .absolute
            }) {
                Label(
                    connectionManager.touchMode == .absolute ? "Direct" : "Touchpad",
                    systemImage: connectionManager.touchMode == .absolute
                        ? "hand.tap" : "rectangle.and.hand.point.up.left"
                )
            }

            Button(action: rightClickAtCursor) {
                Label("Right-click", systemImage: "cursorarrow.click.2")
            }

            Button(action: { openWindow(id: "keyboard") }) {
                Label("Keyboard", systemImage: "keyboard")
            }

            if connectionManager.hasCompanionAudio {
                Button(action: { showAudioPanel.toggle() }) {
                    Label(
                        "Audio",
                        systemImage: audioManager.state == .streaming
                            ? "speaker.wave.2.fill" : "speaker.wave.2"
                    )
                }
                .tint(audioManager.state == .streaming ? .accentColor : nil)
                .popover(isPresented: $showAudioPanel, arrowEdge: .bottom) {
                    AudioPlayerPanel(width: 360, showsVolume: true)
                        .padding(.vertical, 8)
                        .environment(audioManager)
                }
            }

            Button(action: sendCtrlAltDel) {
                Label("Ctrl+Alt+Del", systemImage: "power")
            }

            Button(action: { openWindow(id: "main", value: MainWindowID.shared) }) {
                Label("Connections", systemImage: "house")
            }
            .labelStyle(.iconOnly)
            .help("Open the connection manager")

            Button(action: {
                connectionManager.disconnect()
                WindowSessionRegistry.shared.closeAfterSurfacingMain(using: openWindow) {
                    dismissWindow(id: "keyboard")
                    dismissWindow(id: "remote-desktop")
                }
            }) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
            .help("Disconnect")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
        .clipShape(Capsule())
    }

    // MARK: - Gestures

    /// Single tap = left click, or release an active drag lock.
    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                if dragLocked {
                    // Lifting off the press-and-hold that started the lock can
                    // arrive here as a tap; that would release it instantly.
                    if let started = dragLockStartedAt, Date().timeIntervalSince(started) < 0.4 { return }
                    releaseLeft(at: value.location)
                    dragLocked = false
                } else {
                    leftClick(at: value.location)
                }
            }
    }

    /// Press and hold = grab: holds the left button down so the next drag
    /// drags. Was a double-tap, which left no way to double-click. The hover
    /// handler keeps the virtual cursor synced in both modes, so this needs no
    /// location of its own — same rule as the Right-click button.
    private var dragLockGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55)
            .onEnded { _ in beginDragLockAtCursor() }
    }

    /// Drag: moves the cursor. While a drag lock is held (or a plain absolute
    /// click-and-drag is in progress), the left button stays down so this drags.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if connectionManager.touchMode == .absolute {
                    guard let point = translator?.viewToFramebuffer(value.location) else { return }
                    if dragLocked {
                        // Button already held by the drag lock — just move.
                        connectionManager.sendMouseMove(x: point.x, y: point.y)
                    } else if !isDragging {
                        isDragging = true
                        connectionManager.sendMouseDown(button: .left, x: point.x, y: point.y)
                    } else {
                        connectionManager.sendMouseMove(x: point.x, y: point.y)
                    }
                } else {
                    // Relative: compute incremental deltas
                    let dx = value.translation.width - previousDragTranslation.width
                    let dy = value.translation.height - previousDragTranslation.height
                    previousDragTranslation = value.translation

                    if let delta = translator?.viewDeltaToFramebufferDelta(dx: dx, dy: dy) {
                        connectionManager.moveVirtualCursor(dx: delta.dx, dy: delta.dy)
                    }
                }
            }
            .onEnded { value in
                // Plain click-and-drag releases on lift; a drag lock stays held
                // until a single tap releases it.
                if connectionManager.touchMode == .absolute && isDragging && !dragLocked {
                    if let point = translator?.viewToFramebuffer(value.location) {
                        connectionManager.sendMouseUp(button: .left, x: point.x, y: point.y)
                    }
                }
                isDragging = false
                previousDragTranslation = .zero
            }
    }

    // MARK: - Click Helpers

    /// Left click at a tapped location (absolute) or the virtual cursor (relative).
    private func leftClick(at location: CGPoint) {
        if connectionManager.touchMode == .absolute {
            guard let raw = translator?.viewToFramebuffer(location) else { return }
            // Snap a quick second tap onto the first one's pixel so the remote
            // desktop reads the pair as a double-click (see DoubleClickCadence).
            let point = clickCadence.resolve(raw)
            connectionManager.sendMouseDown(button: .left, x: point.x, y: point.y)
            connectionManager.sendMouseUp(button: .left, x: point.x, y: point.y)
        } else {
            connectionManager.clickAtVirtualCursor(button: .left)
        }
    }

    /// Right click at the current cursor position (toolbar button).
    private func rightClickAtCursor() {
        connectionManager.clickAtVirtualCursor(button: .right)
    }

    /// Press and hold the left button so the next drag drags.
    private func beginDragLockAtCursor() {
        guard !dragLocked else { return }
        connectionManager.pressMouseAtVirtualCursor(button: .left)
        dragLocked = true
        dragLockStartedAt = Date()
    }

    /// Release the held left button (ends a drag lock).
    private func releaseLeft(at location: CGPoint) {
        if connectionManager.touchMode == .absolute {
            if let point = translator?.viewToFramebuffer(location) {
                connectionManager.sendMouseUp(button: .left, x: point.x, y: point.y)
            }
        } else {
            connectionManager.releaseMouseAtVirtualCursor(button: .left)
        }
    }

    /// Pinch = scroll wheel
    private var scrollGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification - 1.0
                guard abs(delta) > 0.01 else { return }

                let wheel: VNCMouseWheel = delta > 0 ? .up : .down
                let steps = UInt32(max(1, abs(delta) * 10))

                if connectionManager.touchMode == .absolute {
                    let centerX = UInt16(connectionManager.framebufferSize.width / 2)
                    let centerY = UInt16(connectionManager.framebufferSize.height / 2)
                    connectionManager.sendScroll(wheel: wheel, x: centerX, y: centerY, steps: steps)
                } else {
                    connectionManager.scrollAtVirtualCursor(wheel: wheel, steps: steps)
                }
            }
    }

    // MARK: - Helpers

    private var translator: GestureTranslator? {
        guard connectionManager.framebufferSize.width > 0 else { return nil }
        return GestureTranslator(
            framebufferSize: connectionManager.framebufferSize,
            viewSize: viewSize,
            trackpadOnly: connectionManager.isTrackpadOnly
        )
    }

    /// Local pointer dot for relative/touchpad mode, drawn at the virtual cursor.
    private var cursorOverlay: some View {
        let point = translator?.framebufferToView(
            x: connectionManager.virtualCursorX,
            y: connectionManager.virtualCursorY
        ) ?? .zero

        return Circle()
            .fill(.white.opacity(0.7))
            .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 1))
            .frame(width: 12, height: 12)
            .position(point)
            .allowsHitTesting(false)
    }

    /// L-shaped corner brackets indicating the trackpad boundary
    private var cornerBrackets: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let arm: CGFloat = 40

            Path { path in
                // Top-left
                path.move(to: CGPoint(x: 0, y: arm))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: arm, y: 0))

                // Top-right
                path.move(to: CGPoint(x: w - arm, y: 0))
                path.addLine(to: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: w, y: arm))

                // Bottom-left
                path.move(to: CGPoint(x: 0, y: h - arm))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.addLine(to: CGPoint(x: arm, y: h))

                // Bottom-right
                path.move(to: CGPoint(x: w - arm, y: h))
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: w, y: h - arm))
            }
            .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .allowsHitTesting(false)
    }

    private func sendCtrlAltDel() {
        connectionManager.sendKeyDown(.control)
        connectionManager.sendKeyDown(.option)
        connectionManager.sendKeyDown(.forwardDelete)
        connectionManager.sendKeyUp(.forwardDelete)
        connectionManager.sendKeyUp(.option)
        connectionManager.sendKeyUp(.control)
    }
}
