import SwiftUI
import RoyalVNCKit

/// A VNC desktop, on the same window chrome, hand gestures and Mouse mode as
/// the Native desktop and Moonlight (`StreamPointerController`,
/// `StreamMouseBridge`, `StreamControlsBar`).
struct RemoteDesktopView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @Environment(\.scenePhase) private var scenePhase

    @State private var showAudioPanel = false
    /// Pending teardown after the window disappeared; cancelled if it comes back.
    @State private var teardownTask: Task<Void, Never>?
    @State private var pointer = StreamPointerController()

    /// A Bluetooth/USB mouse, read raw and driving the remote cursor — see
    /// `StreamMouseBridge`.
    private var mouseBridge: StreamMouseBridge { .shared(for: connectionManager) }
    private var mouseOwnsPointer: Bool { mouseBridge.ownsPointer }

    var body: some View {
        coreContent
            // Below the window, not over the bottom of the desktop.
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                toolbar
            }
            .sheet(isPresented: Bindable(connectionManager).isCredentialPromptPresented) {
                CredentialPromptView()
            }
            .onAppear {
                teardownTask?.cancel()
                teardownTask = nil
                pointer.target = connectionManager
                pointer.trackpadOnly = connectionManager.isTrackpadOnly
                mouseBridge.streaming = connectionManager.connectionState == .connected
                mouseBridge.start()
            }
            .onDisappear {
                mouseBridge.stop()
                // visionOS also fires this on transient hides: the app being
                // suspended and resumed, a space restore, a window push. Tearing
                // the session down then flips the state to `.disconnected`, which
                // closes this window and the keyboard a second later — the desktop
                // just vanishes on resume. So only a window closed while the app
                // is active disconnects, and after a grace period the window can
                // cancel by reappearing.
                guard scenePhase == .active else { return }
                teardownTask?.cancel()
                teardownTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    dismissWindow(id: "keyboard")
                    if connectionManager.connectionState.isActive {
                        connectionManager.disconnect()
                    }
                }
            }
            .onChange(of: connectionManager.isTrackpadOnly) { _, trackpadOnly in
                pointer.trackpadOnly = trackpadOnly
            }
            .onChange(of: connectionManager.connectionState) { _, newValue in
                mouseBridge.streaming = newValue == .connected
                if case .disconnected = newValue {
                    // Server-initiated disconnect: close windows after a brief delay
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        // Surface the connection manager and wait for it: visionOS
                        // won't let an app close its own last window.
                        WindowSessionRegistry.shared.closeAfterSurfacingMain(
                            closing: ["keyboard", "remote-desktop"],
                            using: openWindow
                        ) {
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

            StreamPane(mouseOwnsPointer: mouseOwnsPointer) {
                ZStack {
                    if connectionManager.isTrackpadOnly {
                        if connectionManager.connectionState == .connected {
                            Color.white.opacity(0.001) // Near-invisible but takes the pointer
                            cornerBrackets
                        } else {
                            statusView
                        }
                    } else if let cgImage = connectionManager.framebufferImage {
                        Color.black
                        Image(uiImage: UIImage(cgImage: cgImage))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        statusView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .glassBackgroundEffect()
                    }
                }
                // macOS Screen Sharing doesn't draw the remote cursor, so the
                // surface draws the local dot in Touchpad mode and whenever
                // the mouse drives.
                .streamPointerInput(
                    pointer,
                    mouseOwnsPointer: mouseOwnsPointer,
                    hitTargetHidden: mouseBridge.menuOpen
                )
            } strip: {
                StreamConnectionStrip(
                    status: connectionManager.connectionTitle,
                    streamSize: connectionManager.framebufferSize,
                    mouse: mouseBridge
                ) {
                    EmptyView()
                }
            }
            // Trackpad-only has no picture to fit, and keeps its window free.
            .streamAspectLock(
                connectionManager.isTrackpadOnly ? nil : framebufferAspect,
                paneSize: pointer.viewSize,
                mouseOwnsPointer: mouseOwnsPointer
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: StreamMouseLayout.windowCornerRadius, style: .continuous))
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                if pointer.dragLocked { StreamBadge.dragLock }
                if !connectionManager.stickyModifiers.isEmpty { stickyModifierBadge }
            }
        }
    }

    private var framebufferAspect: Double? {
        let size = connectionManager.framebufferSize
        guard size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    /// Shown while a hardware modifier is latched sticky by a double-tap
    /// (see `KeyCaptureView`) — held down at the remote past its own key's
    /// release, until the same key is pressed again.
    private var stickyModifierBadge: some View {
        StreamBadge("\(stickyModifierGlyphs) held — press again to release", systemImage: "keyboard.badge.ellipsis")
    }

    private var stickyModifierGlyphs: String {
        connectionManager.stickyModifiers.ordered.map(modifierGlyph).joined(separator: " ")
    }

    private func modifierGlyph(_ modifier: VirtualModifiers) -> String {
        switch modifier {
        case .shift:   return "⇧"
        case .control: return "⌃"
        case .option:  return "⌥"
        case .command: return "⌘"
        default:       return ""
        }
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
                    WindowSessionRegistry.shared.closeAfterSurfacingMain(
                        closing: ["remote-desktop"],
                        using: openWindow
                    ) {
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
        StreamControlsBar(
            target: connectionManager,
            mouse: mouseBridge,
            keyboardOpen: isKeyboardWindowOpen,
            toggleKeyboard: toggleKeyboardWindow,
            // The companion's player, from the same Audio button the Native
            // desktop uses for its own player. Left out without a companion.
            audio: connectionManager.hasCompanionAudio
                ? StreamAudioButton(
                    isOn: $showAudioPanel,
                    systemImage: audioManager.state == .streaming ? "speaker.wave.2.fill" : "speaker.wave.2",
                    help: "The Mac's audio, through its companion",
                    popover: AnyView(
                        AudioPlayerPanel(width: 360, showsVolume: true)
                            .padding(.vertical, 8)
                            .environment(audioManager)
                    )
                )
                : nil,
            disconnect: disconnect
        ) {
            EmptyView()
        } display: {
            EmptyView()
        }
    }

    private func disconnect() {
        connectionManager.disconnect()
        WindowSessionRegistry.shared.closeAfterSurfacingMain(
            closing: ["keyboard", "remote-desktop"],
            using: openWindow
        ) {
            dismissWindow(id: "keyboard")
            dismissWindow(id: "remote-desktop")
        }
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

    // MARK: - Keyboard Window

    /// True while the on-screen keyboard has been opened in its own window —
    /// tracked live off `WindowSessionRegistry`, so the toolbar button reads
    /// as a real toggle instead of only ever opening it.
    private var isKeyboardWindowOpen: Bool {
        WindowSessionRegistry.shared.sessions["keyboard"] != nil
    }

    private func toggleKeyboardWindow() {
        if isKeyboardWindowOpen {
            dismissWindow(id: "keyboard")
        } else {
            openWindow(id: "keyboard")
        }
    }
}
