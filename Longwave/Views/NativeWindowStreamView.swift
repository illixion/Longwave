#if os(visionOS)
import SwiftUI
import AVFoundation
import UIKit

/// One streamed host window as its own chrome-free visionOS window — the
/// Unity-style presentation. Deliberately no ornament: the scene is nothing
/// but the remote window's pixels (alpha-preserving on macOS hosts), so it
/// reads as "that Mac window, floating here". Session control lives in the
/// Native controller window; closing this scene (window bar) unsubscribes
/// its stream.
struct NativeWindowStreamView: View {
    let windowID: UInt32

    @Environment(MacNativeStreamManager.self) private var screenManager
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewSize: CGSize = .zero
    @State private var isDragging = false
    @State private var dragLocked = false
    @State private var lastPointerPoint: (x: UInt16, y: UInt16)?
    @State private var clickCadence = DoubleClickCadence()
    @State private var dragLockStartedAt: Date?

    private var session: MacNativeWindowSession? {
        screenManager.windowSessions[windowID]
    }

    var body: some View {
        ZStack {
            Color.clear

            // Invisible (1×1) hardware keyboard capture — key events are
            // global on the host; clicking into this window raises it there,
            // so subsequent typing lands in it.
            MacNativeHardwareKeyboardView(screenManager: screenManager)
                .frame(width: 1, height: 1)

            if let session {
                streamContent(session)
            } else {
                statusBadge(text: "This window isn't streaming.", failed: true)
            }
        }
        .onAppear {
            screenManager.ensureSessionConnected()
            screenManager.openWindowStream(windowID)
            screenManager.sendFocusWindow(windowID: windowID)
        }
        .onDisappear {
            screenManager.closeWindowStream(windowID)
        }
        .onChange(of: session?.closedReason) { _, reason in
            // The host ended this stream (window closed, app quit, budget) —
            // take the scene down with it so no orphan window lingers.
            guard reason != nil else { return }
            dismissWindow(id: "mac-native-window", value: MacNativeWindowStreamID(windowID: windowID))
        }
    }

    private func streamContent(_ session: MacNativeWindowSession) -> some View {
        GeometryReader { geometry in
            ZStack {
                MacNativeWindowVideoView(displayLayer: session.displayLayer)
                    .ignoresSafeArea()

                if !session.hasFrame {
                    statusBadge(
                        text: session.closedReason ?? "Connecting to \(sessionTitle(session))…",
                        failed: session.closedReason != nil
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(dragLockGesture)
            .gesture(tapGesture(session))
            .gesture(dragGesture(session))
            .gesture(scrollGesture(session))
            .onContinuousHover { phase in
                if case .active(let location) = phase,
                   let point = translator(session)?.viewToFramebuffer(location) {
                    lastPointerPoint = point
                    screenManager.sendWindowMouseMove(windowID: windowID, x: point.x, y: point.y)
                }
            }
            .onAppear {
                viewSize = geometry.size
            }
            .onChange(of: geometry.size) { _, newSize in
                viewSize = newSize
            }
        }
        .aspectRatio(aspectRatio(session), contentMode: .fit)
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
    }

    private func sessionTitle(_ session: MacNativeWindowSession) -> String {
        if let info = session.info {
            return info.title.isEmpty ? info.appName : info.title
        }
        return "the window"
    }

    private func aspectRatio(_ session: MacNativeWindowSession) -> CGFloat {
        if session.streamSize.width > 0, session.streamSize.height > 0 {
            return session.streamSize.width / session.streamSize.height
        }
        if let info = session.info, info.width > 0, info.height > 0 {
            return info.width / info.height
        }
        return 4.0 / 3.0
    }

    private func statusBadge(text: String, failed: Bool) -> some View {
        VStack(spacing: 16) {
            if failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 42))
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(text)
                .font(.headline)
        }
        .padding(24)
        .glassBackgroundEffect()
    }

    // MARK: - Input (mirrors NativeStreamView's absolute mode, per-window)

    private func translator(_ session: MacNativeWindowSession) -> GestureTranslator? {
        guard session.streamSize.width > 0 else { return nil }
        return GestureTranslator(framebufferSize: session.streamSize, viewSize: viewSize)
    }

    private func tapGesture(_ session: MacNativeWindowSession) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let raw = translator(session)?.viewToFramebuffer(value.location) else { return }
                if dragLocked {
                    // Lifting off the press-and-hold that started the lock can
                    // arrive here as a tap; that would release it instantly.
                    if let started = dragLockStartedAt, Date().timeIntervalSince(started) < 0.4 { return }
                    screenManager.sendWindowMouseUp(windowID: windowID, button: .left, x: raw.x, y: raw.y)
                    dragLocked = false
                } else {
                    // Snap a quick second tap onto the first one's pixel so the
                    // host reads the pair as a double-click.
                    let point = clickCadence.resolve(raw)
                    screenManager.sendWindowMouseDown(windowID: windowID, button: .left, x: point.x, y: point.y)
                    screenManager.sendWindowMouseUp(windowID: windowID, button: .left, x: point.x, y: point.y)
                }
            }
    }

    /// Press and hold = grab, at the tracked pointer. Was a double-tap, which
    /// left no way to double-click.
    private var dragLockGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55)
            .onEnded { _ in beginDragLockAtCursor() }
    }

    private func dragGesture(_ session: MacNativeWindowSession) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let point = translator(session)?.viewToFramebuffer(value.location) else { return }
                if dragLocked {
                    screenManager.sendWindowMouseMove(windowID: windowID, x: point.x, y: point.y)
                } else if !isDragging {
                    isDragging = true
                    screenManager.sendWindowMouseDown(windowID: windowID, button: .left, x: point.x, y: point.y)
                } else {
                    screenManager.sendWindowMouseMove(windowID: windowID, x: point.x, y: point.y)
                }
            }
            .onEnded { value in
                if isDragging, !dragLocked,
                   let point = translator(session)?.viewToFramebuffer(value.location) {
                    screenManager.sendWindowMouseUp(windowID: windowID, button: .left, x: point.x, y: point.y)
                }
                isDragging = false
            }
    }

    private func scrollGesture(_ session: MacNativeWindowSession) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification - 1.0
                guard abs(delta) > 0.01, session.streamSize.width > 0 else { return }
                let steps = Int16(max(1, min(127, abs(delta) * 10)))
                let deltaY: Int16 = delta > 0 ? steps : -steps
                let x = lastPointerPoint?.x ?? UInt16(session.streamSize.width / 2)
                let y = lastPointerPoint?.y ?? UInt16(session.streamSize.height / 2)
                screenManager.sendWindowScroll(windowID: windowID, x: x, y: y, deltaX: 0, deltaY: deltaY)
            }
    }

    /// Press and hold the left button so the next drag drags.
    private func beginDragLockAtCursor() {
        guard !dragLocked, let point = lastPointerPoint else { return }
        screenManager.sendWindowMouseDown(windowID: windowID, button: .left, x: point.x, y: point.y)
        dragLocked = true
        dragLockStartedAt = Date()
    }
}

/// Hosts one window session's `AVSampleBufferDisplayLayer` (same pattern as
/// the desktop stream's `MacNativeLayerView`, private to `NativeStreamView`).
private final class MacNativeWindowLayerView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        layer.backgroundColor = UIColor.clear.cgColor
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

private struct MacNativeWindowVideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> MacNativeWindowLayerView {
        MacNativeWindowLayerView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: MacNativeWindowLayerView, context: Context) {}
}
#endif
