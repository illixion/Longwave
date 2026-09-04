#if MOONLIGHT_ENABLED
import CoreGraphics

/// View-space ↔ stream-space geometry for a Moonlight video layer that is
/// aspect-fit (letterboxed or pillarboxed) inside a view.
///
/// The host wants absolute pointer positions in its own stream resolution, and
/// the black bars around an aspect-fit video are not part of that space. Every
/// client (visionOS gaze, macOS pointer, iOS touch) needs the same arithmetic;
/// this is the one place it lives.
nonisolated enum MoonlightPointerMapping {
    /// The rectangle, in view coordinates, the video actually occupies.
    static func renderRect(streamWidth: Int, streamHeight: Int, in viewSize: CGSize) -> CGRect {
        let streamW = CGFloat(streamWidth)
        let streamH = CGFloat(streamHeight)
        guard streamW > 0, streamH > 0, viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let streamAspect = streamW / streamH
        let viewAspect = viewSize.width / viewSize.height
        if viewAspect > streamAspect {
            // Pillarboxed — black bars on left/right.
            let height = viewSize.height
            let width = height * streamAspect
            return CGRect(x: (viewSize.width - width) / 2, y: 0, width: width, height: height)
        } else {
            // Letterboxed — black bars on top/bottom.
            let width = viewSize.width
            let height = width / streamAspect
            return CGRect(x: 0, y: (viewSize.height - height) / 2, width: width, height: height)
        }
    }

    /// A view point → stream coordinates, clamped onto the video (a touch in
    /// the black bar lands on the nearest edge rather than off-screen).
    static func streamPoint(
        for point: CGPoint, streamWidth: Int, streamHeight: Int, in viewSize: CGSize
    ) -> (x: Int16, y: Int16) {
        let rect = renderRect(streamWidth: streamWidth, streamHeight: streamHeight, in: viewSize)
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let normalizedX = (clampedX - rect.minX) / rect.width
        let normalizedY = (clampedY - rect.minY) / rect.height
        return (
            Int16(clamping: Int(normalizedX * CGFloat(streamWidth))),
            Int16(clamping: Int(normalizedY * CGFloat(streamHeight)))
        )
    }
}
#endif
