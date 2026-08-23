import SwiftUI
import UIKit

/// Multi-touch input surface for the remote desktop.
///
/// SwiftUI gestures cannot express this: `DragGesture` does not report how many
/// fingers are down, and one-finger-drag (drag the remote pointer) versus
/// two-finger-drag (turn the remote's scroll wheel) versus three-finger-drag (pan
/// the zoomed viewport) is exactly that distinction. So the touch handling is
/// UIKit recognizers reporting semantic events in view coordinates; the caller
/// owns the view→framebuffer mapping, because it owns zoom and pan.
///
/// The mapping matches what iOS remote-desktop clients have settled on, so
/// muscle memory transfers:
///
/// | gesture           | effect                          |
/// |-------------------|---------------------------------|
/// | tap               | left click                      |
/// | two-finger tap    | right click                     |
/// | one-finger drag   | drag with the left button held  |
/// | two-finger drag   | remote scroll wheel             |
/// | pinch             | zoom                            |
/// | three-finger drag | pan the zoomed viewport         |
/// | double tap        | toggle fit ⇄ 1:1                |
struct MobilePointerSurface: UIViewRepresentable {
    var onClick: (CGPoint) -> Void
    var onSecondaryClick: (CGPoint) -> Void
    var onDragBegan: (CGPoint) -> Void
    var onDragMoved: (CGPoint) -> Void
    var onDragEnded: (CGPoint) -> Void
    /// `delta` is the two-finger movement since the last callback, in points.
    var onScroll: (CGPoint, CGSize) -> Void
    /// Incremental pinch scale (1.0 = no change) about `anchor`.
    var onZoom: (CGFloat, CGPoint) -> Void
    /// Three-finger viewport pan, in points since the last callback.
    var onViewportPan: (CGSize) -> Void
    var onDoubleTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // Without this the recognizers below never see the second and third
        // fingers, and every multi-touch gesture degrades to a one-finger drag.
        view.isMultipleTouchEnabled = true

        let coordinator = context.coordinator

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        // A single tap must not fire while a double tap is still possible, or
        // every double tap also clicks the remote.
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)

        let secondaryTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSecondaryTap(_:)))
        secondaryTap.numberOfTouchesRequired = 2
        view.addGestureRecognizer(secondaryTap)

        let drag = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDrag(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        // Let a tap win when the finger barely moves, so a slightly sloppy tap is
        // still a click rather than a zero-distance drag.
        tap.require(toFail: drag)
        view.addGestureRecognizer(drag)

        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        view.addGestureRecognizer(scroll)

        let viewportPan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleViewportPan(_:)))
        viewportPan.minimumNumberOfTouches = 3
        viewportPan.maximumNumberOfTouches = 3
        view.addGestureRecognizer(viewportPan)

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        // Pinch and two-finger scroll both claim two fingers. Deliberately NOT
        // simultaneous: whichever the motion starts as wins, so a spread zooms
        // without also scrolling and a parallel slide scrolls without also
        // zooming. Letting both run makes every zoom scroll the remote window.
        coordinator.pinch = pinch
        coordinator.scroll = scroll
        pinch.delegate = coordinator
        scroll.delegate = coordinator

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Refresh the closures every render so they capture the current zoom and
        // pan rather than whatever they were when the view was made.
        context.coordinator.owner = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: MobilePointerSurface
        weak var pinch: UIPinchGestureRecognizer?
        weak var scroll: UIPanGestureRecognizer?

        init(owner: MobilePointerSurface) {
            self.owner = owner
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            owner.onClick(recognizer.location(in: view))
        }

        @objc func handleSecondaryTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            owner.onSecondaryClick(recognizer.location(in: view))
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            owner.onDoubleTap()
        }

        @objc func handleDrag(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            switch recognizer.state {
            case .began: owner.onDragBegan(point)
            case .changed: owner.onDragMoved(point)
            case .ended, .cancelled, .failed: owner.onDragEnded(point)
            default: break
            }
        }

        @objc func handleScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, recognizer.state == .changed else { return }
            let translation = recognizer.translation(in: view)
            // Report deltas, not cumulative translation: a scroll wheel has no
            // absolute position, and resetting keeps the two in step.
            recognizer.setTranslation(.zero, in: view)
            owner.onScroll(
                recognizer.location(in: view),
                CGSize(width: translation.x, height: translation.y)
            )
        }

        @objc func handleViewportPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, recognizer.state == .changed else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            owner.onViewportPan(CGSize(width: translation.x, height: translation.y))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view, recognizer.state == .changed else { return }
            let scale = recognizer.scale
            recognizer.scale = 1
            owner.onZoom(scale, recognizer.location(in: view))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // See the note in makeUIView: pinch and two-finger scroll are
            // mutually exclusive. Everything else may overlap freely.
            guard let pinch, let scroll else { return true }
            let pair = Set([ObjectIdentifier(gestureRecognizer), ObjectIdentifier(other)])
            let exclusive = Set([ObjectIdentifier(pinch), ObjectIdentifier(scroll)])
            return pair != exclusive
        }
    }
}
