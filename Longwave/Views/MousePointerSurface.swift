#if os(visionOS)
import SwiftUI
import UIKit
import DebugTrace

/// A Bluetooth/USB mouse over whatever this is layered on, read through
/// UIKit's pointer events: where it hovers, which buttons go down and up
/// where, and the wheel. Locations are in this view's points.
///
/// UIKit, not GameController: in a window, visionOS hands `GCMouse` events
/// to the app only while a button is held. A plain click then arrives too
/// late to land, and the pointer can't be moved without a button down. It
/// would need pointer lock, and visionOS doesn't grant that to a window.
/// UIKit's events reach the view whatever the lock state.
///
/// Only `.indirectPointer` touches are taken, so a hand's pinch or poke is
/// left to the gestures underneath.
struct MousePointerSurface: UIViewRepresentable {
    enum Button: Hashable {
        case left, right, middle
    }

    var onHover: (CGPoint) -> Void
    var onButton: (_ button: Button, _ pressed: Bool, _ location: CGPoint) -> Void
    var onDrag: (CGPoint) -> Void
    /// Scroll travel in view points, signed like `IndirectScrollSurface`'s.
    var onScroll: (CGSize) -> Void
    var onScrollEnded: () -> Void = {}

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let hover = UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHover(_:))
        )
        view.addGestureRecognizer(hover)

        let buttons = PointerButtonRecognizer(coordinator: context.coordinator)
        buttons.delegate = context.coordinator
        view.addGestureRecognizer(buttons)

        let scroll = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleScroll(_:))
        )
        scroll.allowedTouchTypes = []
        scroll.allowedScrollTypesMask = .all
        scroll.delegate = context.coordinator
        view.addGestureRecognizer(scroll)

        // The Mac draws its own cursor into the stream right where this one
        // is; two of them is one too many.
        view.addInteraction(UIPointerInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.surface = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
        var surface: MousePointerSurface

        init(surface: MousePointerSurface) {
            self.surface = surface
        }

        @objc func handleHover(_ hover: UIHoverGestureRecognizer) {
            switch hover.state {
            case .began:
                AppLog.macNativeMouse.info("Pointer entered the desktop")
                surface.onHover(hover.location(in: hover.view))
            case .changed:
                surface.onHover(hover.location(in: hover.view))
            case .ended, .cancelled:
                AppLog.macNativeMouse.info("Pointer left the desktop")
            default:
                break
            }
        }

        @objc func handleScroll(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                pan.setTranslation(.zero, in: pan.view)
            case .changed:
                let translation = pan.translation(in: pan.view)
                pan.setTranslation(.zero, in: pan.view)
                if translation != .zero {
                    surface.onScroll(CGSize(width: translation.x, height: translation.y))
                }
            case .ended, .cancelled, .failed:
                surface.onScrollEnded()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func pointerInteraction(
            _ interaction: UIPointerInteraction,
            styleFor region: UIPointerRegion
        ) -> UIPointerStyle? {
            .hidden()
        }
    }

    /// Turns pointer touches into button presses and releases. A press of a
    /// second button while one is held arrives as a change in the event's
    /// button mask on the same touch, not as a new touch, so every callback
    /// diffs the mask against the last one.
    final class PointerButtonRecognizer: UIGestureRecognizer {
        private weak var coordinator: Coordinator?
        private var held: Set<Button> = []

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(target: nil, action: nil)
            allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            update(touches, event, ending: false)
            state = .began
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            update(touches, event, ending: false)
            if let location = location(touches) {
                coordinator?.surface.onDrag(location)
            }
            state = .changed
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            update(touches, event, ending: true)
            state = .ended
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            update(touches, event, ending: true)
            state = .cancelled
        }

        override func reset() {
            super.reset()
            held.removeAll()
        }

        private func location(_ touches: Set<UITouch>) -> CGPoint? {
            touches.first.map { $0.location(in: view) }
        }

        private func update(_ touches: Set<UITouch>, _ event: UIEvent, ending: Bool) {
            guard let coordinator, let location = location(touches) else { return }
            var now: Set<Button> = []
            if !ending {
                let mask = event.buttonMask
                // A touch with no button bits is a primary click.
                if mask.contains(.primary) || mask.isEmpty { now.insert(.left) }
                if mask.contains(.secondary) { now.insert(.right) }
                if mask.contains(.button(3)) { now.insert(.middle) }
            }
            for button in held.subtracting(now) {
                coordinator.surface.onButton(button, false, location)
            }
            for button in now.subtracting(held) {
                AppLog.macNativeMouse.debug("Button down: \(String(describing: button), privacy: .public)")
                coordinator.surface.onButton(button, true, location)
            }
            held = now
        }
    }
}
#endif
