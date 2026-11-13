#if os(visionOS)
import SwiftUI
import UIKit

// MARK: - Controller

/// The hand and hover half of every visionOS remote-desktop window — VNC, the
/// Native desktop, Moonlight — written once over `RemotePointerTarget`. It
/// used to be three copies that had drifted apart (drag thresholds, how a
/// drag lock released off the picture, where a hand scroll landed).
///
/// - Tap: left click where it landed (Direct) or at the cursor (Touchpad);
///   two quick taps double-click (`DoubleClickCadence`).
/// - Press and hold: drag lock — the left button stays down until the next tap.
/// - Drag: click-and-drag (Direct) or cursor motion (Touchpad).
/// - Both hands: scroll, or pinch-and-release for a right click.
/// - Hover (a mouse left to visionOS): the cursor follows the pointer.
///
/// All of it stands aside while a mouse drives the remote
/// (`mouseOwnsPointer`): visionOS also delivers each physical click as a tap.
/// Points are on the flat picture, in view points; a curved surface maps its
/// own hits there before calling in, and sets `planeToFlat` for the
/// window-plane gestures (hover, both hands).
@MainActor
@Observable
final class StreamPointerController {
    @ObservationIgnored weak var target: (any RemotePointerTarget)?
    /// The surface's size, from `StreamPointerInput`'s geometry.
    var viewSize: CGSize = .zero
    /// The whole surface is the input area, with no picture to fit (VNC's
    /// trackpad-only connections).
    @ObservationIgnored var trackpadOnly = false
    /// Window-plane point to flat-picture point; a curve's mapping on a
    /// curved desktop.
    @ObservationIgnored var planeToFlat: (CGPoint) -> CGPoint = { $0 }

    /// Mouse mode — set by `StreamPointerInput` from the bridge.
    @ObservationIgnored private(set) var mouseOwnsPointer = false
    private(set) var dragLocked = false
    /// True while both hands are pinched (and briefly after), so the one-hand
    /// gestures stand down — see `TwoHandPointerGesture`.
    var twoHandEngaged = false

    @ObservationIgnored private var isDragging = false
    @ObservationIgnored private var previousDragTranslation: CGSize = .zero
    @ObservationIgnored private var clickCadence = DoubleClickCadence()
    @ObservationIgnored private var dragLockStartedAt: Date?
    @ObservationIgnored private var scrollSteps = ScrollStepAccumulator()
    @ObservationIgnored private var lastPointerPoint: (x: UInt16, y: UInt16)?

    /// One-hand input is live: neither both hands nor a mouse own the pointer.
    private var acceptsHands: Bool { !twoHandEngaged && !mouseOwnsPointer }

    // MARK: Geometry

    func translator(in size: CGSize) -> GestureTranslator? {
        guard let stream = target?.pointerStreamSize, stream.width > 0, stream.height > 0,
              size.width > 0, size.height > 0 else { return nil }
        return GestureTranslator(framebufferSize: stream, viewSize: size, trackpadOnly: trackpadOnly)
    }

    private var translator: GestureTranslator? { translator(in: viewSize) }

    /// The picture's outline inside a surface of `size` (aspect-fit), where
    /// the mouse's pointer may sit.
    func pictureRect(in size: CGSize) -> CGRect? {
        guard let translator = translator(in: size) else { return nil }
        return CGRect(origin: translator.imageOffset, size: translator.displayedImageSize)
    }

    /// The flat-picture point the local cursor dot is drawn at, when one
    /// should be: Touchpad mode by hand, or a mouse driving a host that draws
    /// no cursor of its own.
    func cursorDotPoint(mouseOwnsPointer: Bool) -> CGPoint? {
        guard let target, let cursor = target.pointerCursor, let translator else { return nil }
        let shows = mouseOwnsPointer ? !target.hostDrawsCursor : target.touchMode == .relative
        guard shows else { return nil }
        return translator.framebufferToView(x: cursor.x, y: cursor.y)
    }

    private func streamPoint(_ flat: CGPoint) -> (x: UInt16, y: UInt16)? {
        translator?.viewToFramebuffer(flat)
    }

    private func move(to point: (x: UInt16, y: UInt16)) {
        lastPointerPoint = point
        target?.pointerMove(to: point)
    }

    // MARK: Mouse mode

    func setMouseOwnsPointer(_ owns: Bool) {
        guard owns != mouseOwnsPointer else { return }
        mouseOwnsPointer = owns
        guard owns else { return }
        // The mouse takes over: let go of anything a hand was holding.
        if dragLocked || isDragging {
            target?.pointerButton(.left, pressed: false)
        }
        dragLocked = false
        isDragging = false
        previousDragTranslation = .zero
    }

    // MARK: One hand

    /// Single tap: left click, or release an active drag lock.
    func tap(at location: CGPoint) {
        guard acceptsHands, let target else { return }
        if dragLocked {
            // Lifting off the press-and-hold that started the lock can
            // arrive here as a tap; that would release it instantly.
            if let started = dragLockStartedAt, Date().timeIntervalSince(started) < 0.4 { return }
            if target.touchMode == .absolute, let point = streamPoint(location) {
                move(to: point)
            }
            // Released even off the picture, so the button never sticks.
            target.pointerButton(.left, pressed: false)
            dragLocked = false
        } else if target.touchMode == .absolute {
            guard let raw = streamPoint(location) else { return }
            // Snap a quick second tap onto the first one's pixel so the host
            // reads the pair as a double-click (see DoubleClickCadence).
            move(to: clickCadence.resolve(raw))
            target.pointerClick(.left)
        } else {
            // Touchpad mode already clicks twice at the same cursor.
            target.pointerClick(.left)
        }
    }

    /// Press and hold = grab: holds the left button down wherever the cursor
    /// is, so the next drag drags; the next tap drops it. A long press
    /// carries no location of its own — the same rule as Right-click.
    func beginDragLock() {
        guard acceptsHands, !dragLocked, let target else { return }
        target.pointerButton(.left, pressed: true)
        dragLocked = true
        dragLockStartedAt = Date()
    }

    func dragChanged(at location: CGPoint, translation: CGSize) {
        guard acceptsHands, let target else { return }
        if target.touchMode == .absolute {
            guard let point = streamPoint(location) else { return }
            move(to: point)
            // A drag lock already holds the button; otherwise this is a plain
            // click-and-drag, pressed on the first update.
            if !dragLocked, !isDragging {
                isDragging = true
                target.pointerButton(.left, pressed: true)
            }
        } else {
            let dx = translation.width - previousDragTranslation.width
            let dy = translation.height - previousDragTranslation.height
            previousDragTranslation = translation
            if let delta = translator?.viewDeltaToFramebufferDelta(dx: dx, dy: dy) {
                target.pointerMove(dx: delta.dx, dy: delta.dy)
            }
        }
    }

    func dragEnded(at location: CGPoint) {
        defer {
            isDragging = false
            previousDragTranslation = .zero
        }
        guard !twoHandEngaged, let target else { return }
        // A plain click-and-drag releases on lift; a drag lock stays held
        // until a tap releases it.
        if target.touchMode == .absolute, isDragging, !dragLocked {
            if let point = streamPoint(location) { move(to: point) }
            target.pointerButton(.left, pressed: false)
        }
    }

    // MARK: Both hands, wheel, hover

    /// A second hand arriving turns whatever the first one was doing into a
    /// two-hand gesture, so let go of the button an absolute drag pressed on
    /// its own. A deliberate drag *lock* is left held — scrolling mid-drag is
    /// a real thing to want.
    func cancelImplicitDrag() {
        guard isDragging, !dragLocked else { return }
        target?.pointerButton(.left, pressed: false)
        isDragging = false
        previousDragTranslation = .zero
    }

    /// Scroll travel in view points — a mouse wheel's or a trackpad's through
    /// `IndirectScrollSurface` — as line steps at the cursor, which hover keeps
    /// on the pointer.
    func wheelScroll(_ delta: CGSize) {
        let steps = scrollSteps.steps(for: delta)
        guard steps.dx != 0 || steps.dy != 0 else { return }
        target?.pointerScroll(dx: Int(steps.dx), dy: Int(steps.dy))
    }

    func wheelScrollEnded() {
        scrollSteps.reset()
    }

    /// Both hands' scroll. Touchpad mode scrolls at the cursor, as the wheel
    /// does. Direct mode scrolls where the pinch landed — where the user was
    /// looking — since gaze produces no hover and the cursor would otherwise
    /// sit wherever it last was.
    func handScroll(_ delta: CGSize, anchor: CGPoint) {
        if target?.touchMode == .absolute, !mouseOwnsPointer,
           let point = streamPoint(planeToFlat(anchor)),
           lastPointerPoint.map({ $0 != point }) ?? true {
            move(to: point)
        }
        wheelScroll(delta)
    }

    /// Right click at the cursor: the ornament button and the two-hand pinch.
    func rightClick() {
        target?.pointerClick(.right)
    }

    /// A mouse left to visionOS hovering the picture: the cursor follows it.
    /// A DragGesture only fires while a button is down, so plain moves need
    /// this. Absolute positions only — gaze can warp the pointer, so derived
    /// deltas would jump.
    func hover(_ phase: HoverPhase) {
        guard !mouseOwnsPointer, case .active(let location) = phase,
              let point = streamPoint(planeToFlat(location)) else { return }
        move(to: point)
    }

    // MARK: Gestures

    var tapGesture: some Gesture {
        SpatialTapGesture().onEnded { [self] value in tap(at: value.location) }
    }

    var dragLockGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55).onEnded { [self] _ in beginDragLock() }
    }

    var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { [self] value in dragChanged(at: value.location, translation: value.translation) }
            .onEnded { [self] value in dragEnded(at: value.location) }
    }
}

// MARK: - Input modifier

/// Puts `StreamPointerController`'s gestures, the wheel, hover and — in mouse
/// mode — the mouse's hit target on a stream's picture. The content fills the
/// surface; the picture inside it is aspect-fit.
struct StreamPointerInput: ViewModifier {
    let pointer: StreamPointerController
    let mouseOwnsPointer: Bool
    /// Takes the hit target down while a popover from the controls is open,
    /// so the mouse can work it.
    var hitTargetHidden = false
    /// Where the mouse's pointer may sit; the fitted picture by default.
    var hitRect: CGRect?
    /// `.all` on a flat picture; `.subviews` when the content takes taps,
    /// holds and drags itself (Native's curved mesh).
    var oneHandGestures: GestureMask = .all
    /// Where the local cursor dot goes for a flat-picture point; the point
    /// itself on the window plane by default. A curve lifts it onto itself.
    var cursorPlacement: ((CGPoint) -> (point: CGPoint, depth: CGFloat))?
    /// Window-plane point to flat-picture point, for hover and both hands;
    /// a curve's mapping on a curved desktop.
    var planeToFlat: ((CGPoint) -> CGPoint)?
    /// A pointer arrived over the picture (hover, or the hit target).
    var onPointerEntered: (() -> Void)?

    func body(content: Content) -> some View {
        @Bindable var pointer = pointer
        // Refreshed every update, so it always holds the current curve.
        let _ = pointer.planeToFlat = planeToFlat ?? { $0 }
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                // The picture and its gestures take no pointer while a mouse
                // drives the remote: the hit target below is the only thing
                // the pointer may land on, and the dead space around it is
                // what keeps it off the window bar and the resize corners.
                .allowsHitTesting(!mouseOwnsPointer)
                .overlay {
                    if mouseOwnsPointer {
                        if !hitTargetHidden, let rect = hitRect ?? pointer.pictureRect(in: geometry.size) {
                            MouseHitTarget(onEnter: onPointerEntered)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    } else {
                        // Topmost, and deliberately hit-testable: a scroll
                        // event is routed to the view under the pointer, so it
                        // has to be the one that's there. It claims no
                        // touches, which leaves the gestures below untouched.
                        IndirectScrollSurface(
                            onScroll: pointer.wheelScroll,
                            onScrollEnded: pointer.wheelScrollEnded
                        )
                    }
                }
                .overlay {
                    if let flat = pointer.cursorDotPoint(mouseOwnsPointer: mouseOwnsPointer) {
                        let placed = cursorPlacement?(flat) ?? (point: flat, depth: 0)
                        StreamCursorDot()
                            .position(placed.point)
                            .offset(z: placed.depth + 1)
                    }
                }
                .contentShape(mouseOwnsPointer ? Path() : Path(CGRect(origin: .zero, size: geometry.size)))
                .gesture(pointer.dragLockGesture, including: oneHandGestures)
                .gesture(pointer.tapGesture, including: oneHandGestures)
                .gesture(pointer.dragGesture, including: oneHandGestures)
                .twoHandPointerGesture(
                    isEngaged: $pointer.twoHandEngaged,
                    onEngage: pointer.cancelImplicitDrag,
                    onScroll: pointer.handScroll,
                    onSecondaryClick: pointer.rightClick
                )
                .onContinuousHover { phase in
                    if case .active = phase, !mouseOwnsPointer { onPointerEntered?() }
                    pointer.hover(phase)
                }
                .onAppear { pointer.viewSize = geometry.size }
                .onChange(of: geometry.size) { _, size in pointer.viewSize = size }
        }
        .onChange(of: mouseOwnsPointer, initial: true) { _, owns in
            pointer.setMouseOwnsPointer(owns)
        }
    }
}

extension View {
    func streamPointerInput(
        _ pointer: StreamPointerController,
        mouseOwnsPointer: Bool,
        hitTargetHidden: Bool = false,
        hitRect: CGRect? = nil,
        oneHandGestures: GestureMask = .all,
        cursorPlacement: ((CGPoint) -> (point: CGPoint, depth: CGFloat))? = nil,
        planeToFlat: ((CGPoint) -> CGPoint)? = nil,
        onPointerEntered: (() -> Void)? = nil
    ) -> some View {
        modifier(StreamPointerInput(
            pointer: pointer,
            mouseOwnsPointer: mouseOwnsPointer,
            hitTargetHidden: hitTargetHidden,
            hitRect: hitRect,
            oneHandGestures: oneHandGestures,
            cursorPlacement: cursorPlacement,
            planeToFlat: planeToFlat,
            onPointerEntered: onPointerEntered
        ))
    }
}

/// The local pointer dot, for when the host's own cursor isn't in the picture.
struct StreamCursorDot: View {
    var body: some View {
        Circle()
            .fill(.white.opacity(0.7))
            .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 1))
            .frame(width: 12, height: 12)
            .allowsHitTesting(false)
    }
}
#endif
