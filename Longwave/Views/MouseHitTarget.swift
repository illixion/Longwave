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
/// one), so this one is painted, at an alpha too faint to see.
///
/// Over a plain view the pointer roams the whole window, onto the window bar,
/// the resize corners and the mini player (headset, 2026-10-08). What holds
/// it is dead space: Hypnos's thumbnail grid stops the pointer at the empty
/// gaps between tiles, because nothing there takes a pointer. So in mouse mode
/// `NativeStreamView` lays the desktop out as a tile in a padded window, makes
/// the window-wide layer untargetable, and leaves this hover region as the
/// one thing over the desktop, on the window plane: in front of it, on a curve,
/// the pointer left for whatever lay behind at once. Standing it off the plane
/// on a flat desktop, a frame around it and a bigger gap did nothing.
struct MouseHitTarget: View {
    var body: some View {
        MouseHitSurface()
            .contentShape(.hoverEffect, Rectangle())
            .hoverEffect(InvisibleHoverEffect())
    }
}

/// A hover effect with nothing to see: a 0.1% opacity change on a layer
/// that is itself nearly transparent.
struct InvisibleHoverEffect: CustomHoverEffect {
    func body(content: Content) -> some CustomHoverEffect {
        content.hoverEffect { effect, isActive, _ in
            effect.opacity(isActive ? 1 : 0.999)
        }
    }
}

struct MouseHitSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor(white: 0, alpha: 0.02)
        view.addGestureRecognizer(UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHover(_:))
        ))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        @objc func handleHover(_ hover: UIHoverGestureRecognizer) {
            switch hover.state {
            case .began: AppLog.macNativeMouse.info("Pointer entered the desktop")
            case .ended, .cancelled: AppLog.macNativeMouse.info("Pointer left the desktop")
            default: break
            }
        }
    }
}
#endif
