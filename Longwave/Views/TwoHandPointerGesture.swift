#if os(visionOS)
import SwiftUI

/// The two-hand half of a streamed pointer surface's gestures, written once for
/// all four of them — VNC, the Native desktop, a Native window, Moonlight.
///
/// - Both hands pinched, held still, released → **secondary click**.
/// - Both hands pinched and moved → **scroll**, along whichever axes they moved.
///
/// The two open identically, so what separates them is travel: the midpoint of
/// the hands has to stay within `clickSlop` for the release to read as a click,
/// and past it every further move is scroll. Scroll used to be `MagnifyGesture`
/// — the *distance* between the hands — which gave one axis and left no way to
/// tell a right-click from the beginning of a scroll.
///
/// The one-hand gestures (tap, drag, long press) stay on the views, because the
/// pinch that opens a two-hand gesture is an ordinary single pinch until the
/// second hand arrives and SwiftUI has already told the view about it. So this
/// reports engagement instead of trying to own everything: while `isEngaged` is
/// true — and for a moment after the hands lift, so the release can't land as a
/// stray tap — the view must not send anything of its own. `onEngage` fires at
/// the moment the second hand arrives, for undoing whatever the first one
/// already started (a held mouse button, most importantly).
struct TwoHandPointerGesture: ViewModifier {
    @Binding var isEngaged: Bool
    var onEngage: () -> Void
    /// Travel of the hands' midpoint in view points since the last callback —
    /// the same shape a wheel or trackpad reports, so both feed one
    /// `ScrollStepAccumulator`.
    var onScroll: (CGSize) -> Void
    var onSecondaryClick: () -> Void

    /// Midpoint travel that still counts as "held still".
    private static let clickSlop: CGFloat = 14
    /// A pair held longer than this is a scroll that never moved, not a click.
    private static let clickTimeout: TimeInterval = 1.5
    /// How long the one-hand gestures stay muted after the hands lift.
    private static let releaseGrace: Duration = .milliseconds(450)

    @State private var isTracking = false
    @State private var lastMidpoint: CGPoint?
    @State private var travel: CGFloat = 0
    @State private var startedAt: Date?
    @State private var disengageTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        // Simultaneous rather than `.gesture`: the view's own tap, drag and long
        // press must keep being recognized, since the one-hand behavior is
        // still theirs.
        content.simultaneousGesture(
            SpatialEventGesture(coordinateSpace: .local)
                .onChanged { events in track(events) }
                .onEnded { _ in release() }
        )
    }

    private func track(_ events: SpatialEventCollection) {
        let hands = events.filter { $0.phase == .active && Self.isHand($0) }
        guard let midpoint = Self.midpoint(of: hands) else {
            // One hand left (or a pointer took over) — the gesture is over the
            // moment the pair breaks, so a click doesn't wait on the second
            // hand also lifting.
            if isTracking { release() }
            return
        }

        guard isTracking else {
            engage(at: midpoint)
            return
        }

        guard let previous = lastMidpoint else {
            lastMidpoint = midpoint
            return
        }
        let delta = CGSize(
            width: midpoint.x - previous.x,
            height: midpoint.y - previous.y
        )
        lastMidpoint = midpoint
        travel += (delta.width * delta.width + delta.height * delta.height).squareRoot()
        // Nothing is emitted inside the slop, so the hand-jitter of a
        // right-click can't scroll the remote a line before it fires.
        guard travel > Self.clickSlop else { return }
        onScroll(delta)
    }

    private func engage(at midpoint: CGPoint) {
        disengageTask?.cancel()
        disengageTask = nil
        isTracking = true
        lastMidpoint = midpoint
        travel = 0
        startedAt = Date()
        isEngaged = true
        onEngage()
    }

    private func release() {
        guard isTracking else { return }
        let heldStill = travel <= Self.clickSlop
        let inTime = startedAt.map { Date().timeIntervalSince($0) < Self.clickTimeout } ?? false
        isTracking = false
        lastMidpoint = nil
        travel = 0
        startedAt = nil

        if heldStill, inTime {
            onSecondaryClick()
        }

        disengageTask?.cancel()
        disengageTask = Task { @MainActor in
            try? await Task.sleep(for: Self.releaseGrace)
            guard !Task.isCancelled else { return }
            isEngaged = false
        }
    }

    /// A pinching hand, as opposed to a mouse or trackpad pointer — those have
    /// real buttons and a real wheel, and must not be read as a hand gesture.
    private static func isHand(_ event: SpatialEventCollection.Event) -> Bool {
        switch event.kind {
        case .indirectPinch, .directPinch, .touch: true
        default: false
        }
    }

    /// The point between two hands, or nil when there aren't two of them. Two
    /// events that report the *same* hand aren't a pair, so a hand plus a stray
    /// touch from it can't stand in for the second hand.
    private static func midpoint(of hands: [SpatialEventCollection.Event]) -> CGPoint? {
        guard hands.count >= 2 else { return nil }
        let first = hands[0]
        guard let second = hands[1...].first(where: { other in
            guard let a = first.chirality, let b = other.chirality else { return true }
            return a != b
        }) else { return nil }

        return CGPoint(
            x: (first.location.x + second.location.x) / 2,
            y: (first.location.y + second.location.y) / 2
        )
    }
}

extension View {
    /// Adds both-hands-pinch secondary click and two-axis scroll to a streamed
    /// pointer surface. See `TwoHandPointerGesture` for what the view still
    /// owns and what it has to suppress while `isEngaged`.
    func twoHandPointerGesture(
        isEngaged: Binding<Bool>,
        onEngage: @escaping () -> Void = {},
        onScroll: @escaping (CGSize) -> Void,
        onSecondaryClick: @escaping () -> Void
    ) -> some View {
        modifier(
            TwoHandPointerGesture(
                isEngaged: isEngaged,
                onEngage: onEngage,
                onScroll: onScroll,
                onSecondaryClick: onSecondaryClick
            )
        )
    }
}
#endif
