import Foundation
import CoreGraphics

struct GestureTranslator {
    let framebufferSize: CGSize
    let viewSize: CGSize
    /// When true, the entire view is the input surface (no aspect-ratio letterboxing).
    let trackpadOnly: Bool

    init(framebufferSize: CGSize, viewSize: CGSize, trackpadOnly: Bool = false) {
        self.framebufferSize = framebufferSize
        self.viewSize = viewSize
        self.trackpadOnly = trackpadOnly
    }

    /// The actual displayed image size within the view (aspect-ratio fit),
    /// or the full view size in trackpad-only mode.
    var displayedImageSize: CGSize {
        guard framebufferSize.width > 0, framebufferSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        if trackpadOnly {
            return viewSize
        }

        let imageAspect = framebufferSize.width / framebufferSize.height
        let viewAspect = viewSize.width / viewSize.height

        if imageAspect > viewAspect {
            return CGSize(
                width: viewSize.width,
                height: viewSize.width / imageAspect
            )
        } else {
            return CGSize(
                width: viewSize.height * imageAspect,
                height: viewSize.height
            )
        }
    }

    /// Offset of the displayed image from the top-left of the view.
    /// Always zero in trackpad-only mode.
    var imageOffset: CGPoint {
        if trackpadOnly {
            return .zero
        }
        let displayed = displayedImageSize
        return CGPoint(
            x: (viewSize.width - displayed.width) / 2,
            y: (viewSize.height - displayed.height) / 2
        )
    }

    /// Convert a point in view coordinates to framebuffer coordinates.
    /// Returns nil if the point is outside the displayed image bounds.
    func viewToFramebuffer(_ viewPoint: CGPoint) -> (x: UInt16, y: UInt16)? {
        let displayed = displayedImageSize
        let offset = imageOffset

        let relativeX = viewPoint.x - offset.x
        let relativeY = viewPoint.y - offset.y

        guard relativeX >= 0, relativeX <= displayed.width,
              relativeY >= 0, relativeY <= displayed.height else {
            return nil
        }

        let fbX = relativeX / displayed.width * framebufferSize.width
        let fbY = relativeY / displayed.height * framebufferSize.height

        return (
            x: UInt16(clamping: Int(fbX)),
            y: UInt16(clamping: Int(fbY))
        )
    }

    /// Convert framebuffer coordinates back to view coordinates (inverse of viewToFramebuffer).
    func framebufferToView(x: UInt16, y: UInt16) -> CGPoint {
        let displayed = displayedImageSize
        let offset = imageOffset

        let viewX = (CGFloat(x) / framebufferSize.width) * displayed.width + offset.x
        let viewY = (CGFloat(y) / framebufferSize.height) * displayed.height + offset.y

        return CGPoint(x: viewX, y: viewY)
    }

    /// Convert a view-space delta to framebuffer-space delta for relative/touchpad mode.
    /// Applies a sensitivity multiplier on top of the geometric scale.
    func viewDeltaToFramebufferDelta(dx: CGFloat, dy: CGFloat, sensitivity: CGFloat = 1.5) -> (dx: CGFloat, dy: CGFloat) {
        let displayed = displayedImageSize
        guard displayed.width > 0, displayed.height > 0 else { return (0, 0) }

        let scaleX = framebufferSize.width / displayed.width
        let scaleY = framebufferSize.height / displayed.height

        return (
            dx: dx * scaleX * sensitivity,
            dy: dy * scaleY * sensitivity
        )
    }
}
