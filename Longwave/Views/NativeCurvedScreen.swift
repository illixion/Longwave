#if os(visionOS)
import SwiftUI
import UIKit

/// How strongly a Native desktop wraps around the viewer, Mac Virtual
/// Display style. Each is a fixed radius rather than an angle, so curvature
/// follows window size continuously: a small window is a short arc of a big
/// circle and looks nearly flat, a wide one wraps further. Bending a wide
/// screen toward the viewer is what keeps its edges facing them instead of
/// being seen at a grazing angle — the fisheye look of a big flat slab.
enum NativeScreenCurvature: String, CaseIterable, Identifiable {
    case off, gentle, standard, wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Flat"
        case .gentle: "Gentle"
        case .standard: "Standard"
        case .wide: "Wide"
        }
    }

    /// The circle the screen lies on, in metres. Off has none.
    var radiusMeters: Double? {
        switch self {
        case .off: nil
        case .gentle: 2.6
        case .standard: 1.7
        case .wide: 1.15
        }
    }
}

/// A desktop of `contentRect.width` points of arc on a circle of `radius`
/// points, its centre touching the window plane and its edges toward the
/// viewer. The picture keeps its full size — the arc is as long as the flat
/// picture is wide — so the window outline is a little wider than the curve.
struct NativeScreenCurve: Equatable {
    /// The aspect-fitted video rect inside the view, in view points.
    let contentRect: CGRect
    let radius: Double

    /// Half the angle the screen subtends at the circle's centre.
    var halfAngle: Double { contentRect.width / (2 * radius) }

    /// How far the edges come toward the viewer, in points.
    var sagitta: Double { radius * (1 - cos(halfAngle)) }

    /// About 1.5° per strip: fine enough that the facets don't show on text,
    /// few enough to stay cheap. A nearly flat window gets very few.
    var stripCount: Int {
        min(96, max(1, Int((2 * halfAngle * 180 / .pi / 1.5).rounded(.up))))
    }

    struct Strip: Identifiable {
        let id: Int
        /// The strip's centre over the view, and its depth in front of it.
        let center: CGPoint
        let depth: Double
        /// Rotation about the vertical axis, so the strip faces the circle's
        /// centre.
        let angle: Double
        let size: CGSize
        /// The slice of the picture it shows, as a fraction of its width —
        /// including the overlap with its neighbours, so it can run slightly
        /// below 0 or above 1 at the ends, where Core Animation repeats the
        /// edge pixels for those few points.
        let u: ClosedRange<Double>
    }

    /// How far each strip reaches past its slice on either side, in points.
    /// A strip's anti-aliased edge is partly transparent, so strips that only
    /// met edge to edge left a hairline of the room showing between them.
    /// Overlapping by this much — showing the same pixels, since the slice is
    /// widened to match — hides it.
    static let stripOverlap: Double = 2

    var strips: [Strip] {
        let count = stripCount
        let width = contentRect.width / Double(count)
        let padU = Self.stripOverlap / contentRect.width
        return (0..<count).map { index in
            let u0 = Double(index) / Double(count)
            let u1 = Double(index + 1) / Double(count)
            let theta = ((u0 + u1) / 2 - 0.5) * 2 * halfAngle
            return Strip(
                id: index,
                center: CGPoint(x: contentRect.midX + radius * sin(theta), y: contentRect.midY),
                depth: radius * (1 - cos(theta)),
                angle: theta,
                size: CGSize(width: width + 2 * Self.stripOverlap, height: contentRect.height),
                u: (u0 - padU)...(u1 + padU)
            )
        }
    }

    /// A point in a strip's own (untransformed) coordinates to the point the
    /// flat picture would have had there — what the input path maps to a
    /// stream pixel. The system has already done the 3D hit-test through the
    /// strip's transform, so this holds from any viewing position.
    func flatPoint(inStrip strip: Strip, local: CGPoint) -> CGPoint {
        let fraction = local.x / strip.size.width
        let u = strip.u.lowerBound + fraction * (strip.u.upperBound - strip.u.lowerBound)
        return CGPoint(
            x: contentRect.minX + u * contentRect.width,
            y: contentRect.minY + local.y
        )
    }

    /// Where a point of the flat picture sits on the curve: over the view,
    /// and its depth in front of it — for drawing something on the screen
    /// surface itself (the trackpad cursor).
    func surfacePoint(forFlatPoint point: CGPoint) -> (point: CGPoint, depth: Double) {
        let u = (point.x - contentRect.minX) / contentRect.width
        let theta = (u - 0.5) * 2 * halfAngle
        return (
            CGPoint(x: contentRect.midX + radius * sin(theta), y: point.y),
            radius * (1 - cos(theta))
        )
    }

    static func fittedRect(stream: CGSize, in view: CGSize) -> CGRect {
        guard stream.width > 0, stream.height > 0, view.width > 0, view.height > 0 else {
            return CGRect(origin: .zero, size: view)
        }
        let scale = min(view.width / stream.width, view.height / stream.height)
        let size = CGSize(width: stream.width * scale, height: stream.height * scale)
        return CGRect(
            x: (view.width - size.width) / 2,
            y: (view.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// One strip of the curved desktop: a plain layer showing its slice of the
/// shared decoded frame. Ordinary window content, so the system renders it
/// like the flat desktop — not as 3D material, which it foveates.
struct MacNativeSurfaceStripView: UIViewRepresentable {
    let surface: MacNativeFrameSurface
    let u: ClosedRange<Double>

    func makeUIView(context: Context) -> StripView {
        let view = StripView()
        view.layer.contentsRect = Self.rect(u)
        surface.attach(view.layer)
        view.detach = { [weak surface, weak view] in
            if let view { surface?.detach(view.layer) }
        }
        return view
    }

    func updateUIView(_ view: StripView, context: Context) {
        view.layer.contentsRect = Self.rect(u)
    }

    static func dismantleUIView(_ view: StripView, coordinator: ()) {
        view.detach?()
    }

    private static func rect(_ u: ClosedRange<Double>) -> CGRect {
        CGRect(x: u.lowerBound, y: 0, width: u.upperBound - u.lowerBound, height: 1)
    }

    final class StripView: UIView {
        var detach: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = true
            backgroundColor = .black
            layer.contentsGravity = .resize
            layer.minificationFilter = .trilinear
            layer.magnificationFilter = .linear
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
#endif
