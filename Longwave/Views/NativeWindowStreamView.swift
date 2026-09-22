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
    /// Which session's window this scene shows — the scene's value, carried
    /// whole so the view can dismiss itself by the same key it was opened with.
    let streamID: MacNativeWindowStreamID

    private var windowID: UInt32 { streamID.windowID }

    @Environment(MacNativeStreamManager.self) private var screenManager
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewSize: CGSize = .zero
    @State private var isDragging = false
    @State private var dragLocked = false
    @State private var lastPointerPoint: (x: UInt16, y: UInt16)?
    @State private var clickCadence = DoubleClickCadence()
    @State private var dragLockStartedAt: Date?
    @State private var previousDragTranslation: CGSize = .zero
    @State private var scrollSteps = ScrollStepAccumulator()
    /// True while both hands are pinched (and briefly after). The one-hand
    /// gestures below all stand down — see `TwoHandPointerGesture`.
    @State private var twoHandEngaged = false

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
        }
        .onDisappear {
            screenManager.closeWindowStream(windowID)
            screenManager.unityWindowSceneDidClose(windowID)
        }
        .onChange(of: session?.closedReason) { _, reason in
            // The host ended this stream (window closed, app quit, budget) —
            // take the scene down with it so no orphan window lingers.
            guard reason != nil else { return }
            dismissWindow(id: "mac-native-window", value: streamID)
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

                // Topmost, and deliberately not `allowsHitTesting(false)`: a
                // scroll event is routed to the view under the pointer, so it
                // has to be the one that's there. It claims no touches, which
                // leaves the gestures below untouched.
                IndirectScrollSurface(
                    onScroll: { delta in indirectScroll(delta, session) },
                    onScrollEnded: { scrollSteps.reset() }
                )

                // Local pointer dot for trackpad mode — the Mac's own cursor
                // isn't visible until the pointer actually lands there.
                if screenManager.touchMode == .relative, session.streamSize.width > 0 {
                    cursorOverlay(session)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(dragLockGesture)
            .gesture(tapGesture(session))
            .gesture(dragGesture(session))
            // Both hands: pinch-drag scrolls, pinch-and-release right-clicks.
            .twoHandPointerGesture(
                isEngaged: $twoHandEngaged,
                onEngage: { cancelImplicitDrag(session) },
                onScroll: { delta in indirectScroll(delta, session) },
                onSecondaryClick: { rightClick(session) }
            )
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

    // MARK: - Input (mirrors NativeStreamView, per-window)

    private func translator(_ session: MacNativeWindowSession) -> GestureTranslator? {
        guard session.streamSize.width > 0 else { return nil }
        return GestureTranslator(framebufferSize: session.streamSize, viewSize: viewSize)
    }

    /// Where the pointer currently is in this window's framebuffer. Each
    /// window scene tracks its own — the manager's virtual cursor lives in the
    /// desktop stream's coordinate space, which is a different picture.
    private func pointer(_ session: MacNativeWindowSession) -> (x: UInt16, y: UInt16) {
        lastPointerPoint ?? (
            x: UInt16(clamping: Int(session.streamSize.width / 2)),
            y: UInt16(clamping: Int(session.streamSize.height / 2))
        )
    }

    /// Trackpad-mode motion: move the tracked pointer by a framebuffer-space
    /// delta and tell the host about it.
    private func movePointer(_ session: MacNativeWindowSession, dx: CGFloat, dy: CGFloat) {
        guard session.streamSize.width > 0, session.streamSize.height > 0 else { return }
        let current = pointer(session)
        let newX = max(0, min(CGFloat(current.x) + dx, session.streamSize.width - 1))
        let newY = max(0, min(CGFloat(current.y) + dy, session.streamSize.height - 1))
        let point = (x: UInt16(clamping: Int(newX)), y: UInt16(clamping: Int(newY)))
        lastPointerPoint = point
        screenManager.sendWindowMouseMove(windowID: windowID, x: point.x, y: point.y)
    }

    private func tapGesture(_ session: MacNativeWindowSession) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard !twoHandEngaged else { return }
                let isAbsolute = screenManager.touchMode == .absolute
                // In trackpad mode the tap is a click of the button, not an
                // aim — it lands wherever the pointer already is.
                let resolved: (x: UInt16, y: UInt16)? = isAbsolute
                    ? translator(session)?.viewToFramebuffer(value.location)
                    : pointer(session)
                guard let raw = resolved else { return }
                if dragLocked {
                    // Lifting off the press-and-hold that started the lock can
                    // arrive here as a tap; that would release it instantly.
                    if let started = dragLockStartedAt, Date().timeIntervalSince(started) < 0.4 { return }
                    screenManager.sendWindowMouseUp(windowID: windowID, button: .left, x: raw.x, y: raw.y)
                    dragLocked = false
                } else {
                    // Snap a quick second tap onto the first one's pixel so the
                    // host reads the pair as a double-click. Trackpad mode
                    // already clicks twice at the same pointer.
                    let point = isAbsolute ? clickCadence.resolve(raw) : raw
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
                guard !twoHandEngaged else { return }
                if screenManager.touchMode == .absolute {
                    guard let point = translator(session)?.viewToFramebuffer(value.location) else { return }
                    lastPointerPoint = point
                    if dragLocked {
                        screenManager.sendWindowMouseMove(windowID: windowID, x: point.x, y: point.y)
                    } else if !isDragging {
                        isDragging = true
                        screenManager.sendWindowMouseDown(windowID: windowID, button: .left, x: point.x, y: point.y)
                    } else {
                        screenManager.sendWindowMouseMove(windowID: windowID, x: point.x, y: point.y)
                    }
                } else {
                    // Trackpad mode: the drag pushes the pointer around; the
                    // button only comes down for a drag lock, which is already
                    // held by the time we get here.
                    let dx = value.translation.width - previousDragTranslation.width
                    let dy = value.translation.height - previousDragTranslation.height
                    previousDragTranslation = value.translation
                    if let delta = translator(session)?.viewDeltaToFramebufferDelta(dx: dx, dy: dy) {
                        movePointer(session, dx: delta.dx, dy: delta.dy)
                    }
                }
            }
            .onEnded { value in
                guard !twoHandEngaged else { return }
                if screenManager.touchMode == .absolute, isDragging, !dragLocked,
                   let point = translator(session)?.viewToFramebuffer(value.location) {
                    screenManager.sendWindowMouseUp(windowID: windowID, button: .left, x: point.x, y: point.y)
                }
                isDragging = false
                previousDragTranslation = .zero
            }
    }

    /// Secondary click at the tracked pointer — both hands pinched and
    /// released, or the same thing the ornament's button does on the desktop.
    private func rightClick(_ session: MacNativeWindowSession) {
        guard session.streamSize.width > 0 else { return }
        let point = pointer(session)
        screenManager.sendWindowMouseDown(windowID: windowID, button: .right, x: point.x, y: point.y)
        screenManager.sendWindowMouseUp(windowID: windowID, button: .right, x: point.x, y: point.y)
    }

    /// A second hand arriving turns whatever the first one was doing into a
    /// two-hand gesture, so let go of the button an absolute drag pressed on its
    /// own — a deliberate drag *lock* is left held, since scrolling mid-drag is
    /// a real thing to want.
    private func cancelImplicitDrag(_ session: MacNativeWindowSession) {
        guard isDragging, !dragLocked else { return }
        let point = pointer(session)
        screenManager.sendWindowMouseUp(windowID: windowID, button: .left, x: point.x, y: point.y)
        isDragging = false
        previousDragTranslation = .zero
    }

    /// Scroll travel in view points — a wheel's, a trackpad's, or both hands'
    /// — turned into the line steps the host takes.
    private func indirectScroll(_ delta: CGSize, _ session: MacNativeWindowSession) {
        guard session.streamSize.width > 0 else { return }
        let steps = scrollSteps.steps(for: delta)
        guard steps.dx != 0 || steps.dy != 0 else { return }
        sendScroll(session, deltaX: steps.dx, deltaY: steps.dy)
    }

    private func sendScroll(_ session: MacNativeWindowSession, deltaX: Int16, deltaY: Int16) {
        let point = pointer(session)
        screenManager.sendWindowScroll(
            windowID: windowID,
            x: point.x,
            y: point.y,
            deltaX: deltaX,
            deltaY: deltaY
        )
    }

    /// Press and hold the left button so the next drag drags.
    private func beginDragLockAtCursor() {
        guard !twoHandEngaged, !dragLocked, let session, session.streamSize.width > 0 else { return }
        // A long press carries no location of its own. Direct mode waits for a
        // pointer it has actually seen rather than grabbing at the middle of
        // the window; trackpad mode always has one.
        if screenManager.touchMode == .absolute, lastPointerPoint == nil { return }
        let point = pointer(session)
        screenManager.sendWindowMouseDown(windowID: windowID, button: .left, x: point.x, y: point.y)
        dragLocked = true
        dragLockStartedAt = Date()
    }

    /// Local pointer dot drawn at the tracked pointer, for trackpad mode.
    private func cursorOverlay(_ session: MacNativeWindowSession) -> some View {
        let point = pointer(session)
        let location = translator(session)?.framebufferToView(x: point.x, y: point.y) ?? .zero

        return Circle()
            .fill(.white.opacity(0.7))
            .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 1))
            .frame(width: 12, height: 12)
            .position(location)
            .allowsHitTesting(false)
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
