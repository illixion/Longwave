#if os(visionOS)
import SwiftUI
import RealityKit
import AVFoundation

/// How the Native desktop bends, Mac Virtual Display style: a window small
/// enough to take in at a glance stays flat, and a wide one curves around the
/// viewer so its edges face them instead of being seen at a grazing angle —
/// which is what reads as fisheye stretching toward the sides of a big flat
/// slab on the headset's optics.
///
/// The surface is a cylinder segment whose axis is where the viewer is
/// assumed to sit, the screen's centre touching the window plane and its
/// edges coming forward. The radius is chosen so a ray from the axis through
/// the window's edge meets the screen's edge exactly. That is what lets the
/// window's own flat gesture surface keep working: a tap lands on the window
/// plane, and `texturePoint(forViewPoint:)` follows the same ray on to the
/// curve to find the pixel the user was actually looking at.
struct NativeScreenCurve: Equatable {
    /// Half the angle the screen subtends from the cylinder axis. Zero is flat.
    let halfAngle: Double
    /// The aspect-fitted video rect inside the view, in view points.
    let contentRect: CGRect

    /// Curved at all, or close enough to flat that the plain layer is better.
    var isCurved: Bool { halfAngle > 0.02 }

    /// Cylinder radius in points.
    var radius: Double { (contentRect.width / 2) / tan(halfAngle) }
    /// Screen height on the curve. Shorter than the flat rect by cos(halfAngle),
    /// so the top corners also stay inside the window's gesture surface.
    var curvedHeight: Double { contentRect.height * cos(halfAngle) }
    /// How far the edges come toward the viewer, in points.
    var sagitta: Double { isCurved ? radius * (1 - cos(halfAngle)) : 0 }

    /// Mac Virtual Display's behaviour, by eye: flat up to about a metre wide,
    /// then bending more the wider the window gets.
    static func automaticHalfAngle(widthMeters: Double) -> Double {
        let flatUntil = 1.1, fullAt = 3.5, maxHalfAngle = 0.5
        let t = min(max((widthMeters - flatUntil) / (fullAt - flatUntil), 0), 1)
        return t * maxHalfAngle
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

    /// The flat-equivalent view point for a point on the window plane: where
    /// the ray from the cylinder axis through `viewPoint` meets the curve,
    /// expressed in the coordinates the flat layer would have used. Identity
    /// when the screen is flat.
    func texturePoint(forViewPoint viewPoint: CGPoint) -> CGPoint {
        guard isCurved else { return viewPoint }
        let x = viewPoint.x - contentRect.midX
        let y = viewPoint.y - contentRect.midY
        let theta = atan(x / radius)
        let u = 0.5 + theta / (2 * halfAngle)
        let v = 0.5 + (y * cos(theta)) / curvedHeight
        return CGPoint(
            x: contentRect.minX + min(max(u, 0), 1) * contentRect.width,
            y: contentRect.minY + min(max(v, 0), 1) * contentRect.height
        )
    }

    /// The curve as a mesh, in metres, centred on the origin with its centre
    /// line at z = 0 and the edges toward +z.
    func mesh(metersPerPoint: Double) throws -> MeshResource {
        let columns = 96
        let r = radius * metersPerPoint
        let halfHeight = Float(curvedHeight * metersPerPoint / 2)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity((columns + 1) * 2)
        for column in 0...columns {
            let fraction = Double(column) / Double(columns)
            let theta = -halfAngle + 2 * halfAngle * fraction
            let x = Float(r * sin(theta))
            let z = Float(r * (1 - cos(theta)))
            // Toward the axis, i.e. the viewer.
            let normal = SIMD3<Float>(Float(-sin(theta)), 0, Float(cos(theta)))
            positions.append([x, -halfHeight, z])
            positions.append([x, halfHeight, z])
            normals.append(normal)
            normals.append(normal)
            uvs.append([Float(fraction), 0])
            uvs.append([Float(fraction), 1])
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(columns * 6)
        for column in 0..<UInt32(columns) {
            let bottomLeft = column * 2, topLeft = bottomLeft + 1
            let bottomRight = bottomLeft + 2, topRight = bottomLeft + 3
            indices += [bottomLeft, bottomRight, topRight, bottomLeft, topRight, topLeft]
        }
        var descriptor = MeshDescriptor(name: "NativeCurvedScreen")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}

/// The desktop stream drawn on the curve. Decoding goes to `videoRenderer`
/// (see `MacNativeStreamManager.setCurvedSurface`) rather than the flat
/// display layer, so only one of the two is ever fed.
struct NativeCurvedScreenView: View {
    let videoRenderer: AVSampleBufferVideoRenderer
    let curve: NativeScreenCurve

    @Environment(\.physicalMetrics) private var physicalMetrics
    @State private var screen = Entity()
    @State private var builtCurve: NativeScreenCurve?

    var body: some View {
        RealityView { content in
            screen.components.set(ModelComponent(
                mesh: .generatePlane(width: 0.01, height: 0.01),
                materials: [VideoMaterial(videoRenderer: videoRenderer)]
            ))
            content.add(screen)
        } update: { content in
            // The view's centre on the window plane, in the content's space —
            // RealityView's origin is not documented to sit there.
            let center = content.convert(
                Point3D(x: curve.contentRect.midX, y: curve.contentRect.midY, z: 0),
                from: .local,
                to: .scene
            )
            screen.position = SIMD3<Float>(center)
            guard builtCurve != curve else { return }
            let metersPerPoint = physicalMetrics.convert(1, to: .meters)
            guard let mesh = try? curve.mesh(metersPerPoint: metersPerPoint) else { return }
            screen.components[ModelComponent.self]?.mesh = mesh
            Task { @MainActor in builtCurve = curve }
        }
        // The edges come forward out of the window plane; without a front
        // margin the system clips them off.
        .preferredWindowClippingMargins(.front, curve.sagitta + 8)
        .allowsHitTesting(false)
    }
}
#endif
