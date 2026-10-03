#if os(visionOS)
import SwiftUI
import UIKit
import DebugTrace

/// Something for a mouse's system pointer to land on over the desktop, so it
/// leaves the controls ornament. The input itself is read by
/// `MacNativeMouseBridge` through `GCMouse`.
///
/// visionOS puts the pointer wherever the gaze ray hits UI. A view with a
/// clear background didn't catch it (2026-10-03: the pointer never entered
/// one), so this one is painted, at an alpha too faint to see. The pointer
/// is hidden over it: the Mac draws its own cursor into the stream.
struct MouseHitTarget: UIViewRepresentable {
    /// Tints the target so its extent and what the pointer does over it can
    /// be seen — on while the pointer lock is being worked out.
    static let showsOutline = true

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = Self.showsOutline
            ? UIColor.systemBlue.withAlphaComponent(0.18)
            : UIColor(white: 0, alpha: 0.02)
        view.addGestureRecognizer(UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHover(_:))
        ))
        view.addInteraction(UIPointerInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIPointerInteractionDelegate {
        @objc func handleHover(_ hover: UIHoverGestureRecognizer) {
            switch hover.state {
            case .began: AppLog.macNativeMouse.info("Pointer entered the desktop")
            case .ended, .cancelled: AppLog.macNativeMouse.info("Pointer left the desktop")
            default: break
            }
        }

        func pointerInteraction(
            _ interaction: UIPointerInteraction,
            styleFor region: UIPointerRegion
        ) -> UIPointerStyle? {
            .hidden()
        }
    }
}
#endif
