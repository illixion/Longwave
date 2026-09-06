#if os(visionOS)
import SwiftUI
import UIKit

/// Catches *indirect* scroll input — a Bluetooth mouse's wheel, a trackpad's
/// two-finger scroll — over whatever it is layered on, and reports it as
/// view-space deltas.
///
/// SwiftUI has no gesture for this. The stream views scroll with
/// `MagnifyGesture`, which is the gaze pinch, and a wheel notch never becomes
/// one — so a paired mouse could scroll the SSH terminal and nothing else.
/// UIKit does have it, but only through a pan recognizer explicitly told to
/// accept scroll events (`allowedScrollTypesMask`), which is exactly what
/// `VisionTerminalView.enableScrollGesture()` does and why the terminal was
/// the one place it worked.
///
/// `allowedTouchTypes = []` makes the recognizer scroll-only: it never claims
/// a touch, so the tap / drag / long-press gestures underneath still see every
/// finger and every gaze pinch. The view itself handles no touches either, so
/// they travel up the responder chain to the SwiftUI recognizers on its
/// ancestors as if it weren't there.
struct IndirectScrollSurface: UIViewRepresentable {
    /// Scroll travel in view points since the last callback. Positive `height`
    /// = the content should move down (a wheel rolled away from you), matching
    /// the natural-scrolling sense UIKit reports for a pan.
    var onScroll: (CGSize) -> Void

    /// The gesture ended — a good moment to drop any partial travel.
    var onScrollEnded: () -> Void = {}

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleScroll(_:))
        )
        pan.allowedTouchTypes = []
        pan.allowedScrollTypesMask = .all
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Refresh the closures every render so they capture the current
        // session and touch mode rather than whatever they were at make time.
        context.coordinator.onScroll = onScroll
        context.coordinator.onScrollEnded = onScrollEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll, onScrollEnded: onScrollEnded)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onScroll: (CGSize) -> Void
        var onScrollEnded: () -> Void

        init(onScroll: @escaping (CGSize) -> Void, onScrollEnded: @escaping () -> Void) {
            self.onScroll = onScroll
            self.onScrollEnded = onScrollEnded
        }

        @objc func handleScroll(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                pan.setTranslation(.zero, in: pan.view)
                return
            case .changed:
                break
            case .ended, .cancelled, .failed:
                onScrollEnded()
                return
            default:
                return
            }

            // Consume the translation each time so it reads as a delta.
            let translation = pan.translation(in: pan.view)
            pan.setTranslation(.zero, in: pan.view)
            guard translation != .zero else { return }
            onScroll(CGSize(width: translation.x, height: translation.y))
        }

        /// Never take a gesture away from the view underneath — this one only
        /// ever handles scroll events, which nothing else here wants.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
