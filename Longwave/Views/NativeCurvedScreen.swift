#if os(visionOS)
import SwiftUI
import RealityKit
import Metal
import CoreVideo

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
/// picture is wide.
struct NativeScreenCurve: Equatable {
    /// The aspect-fitted video rect inside the view, in view points.
    let contentRect: CGRect
    let radius: Double

    /// Half the angle the screen subtends at the circle's centre.
    var halfAngle: Double { contentRect.width / (2 * radius) }

    /// How far the edges come toward the viewer, in points.
    var sagitta: Double { radius * (1 - cos(halfAngle)) }

    /// A hit on the mesh, in the screen entity's own space (metres, origin at
    /// the picture's centre, +y up, the circle's centre at +z), to the point
    /// the flat picture would have had there.
    func flatPoint(meshLocal point: SIMD3<Float>, metersPerPoint: Double) -> CGPoint {
        let r = radius * metersPerPoint
        let theta = atan2(Double(point.x), r - Double(point.z))
        let u = 0.5 + theta / (2 * halfAngle)
        let v = 0.5 - Double(point.y) / (contentRect.height * metersPerPoint)
        return CGPoint(
            x: contentRect.minX + min(max(u, 0), 1) * contentRect.width,
            y: contentRect.minY + min(max(v, 0), 1) * contentRect.height
        )
    }

    /// For a pointer hovering the window plane (a mouse; the system reports
    /// no gaze position): the point on the curve along the ray from the
    /// circle's centre, which is where a viewer sitting there sees it. The
    /// outermost edges sit beyond the window's reach and clamp to it.
    func flatPoint(forPlanePoint point: CGPoint) -> CGPoint {
        let theta = atan((point.x - contentRect.midX) / radius)
        let u = 0.5 + theta / (2 * halfAngle)
        let v = 0.5 + (point.y - contentRect.midY) * cos(theta) / contentRect.height
        return CGPoint(
            x: contentRect.minX + min(max(u, 0), 1) * contentRect.width,
            y: contentRect.minY + min(max(v, 0), 1) * contentRect.height
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

    /// The curve as a mesh, in metres, centred on the origin with its centre
    /// line at z = 0 and the edges toward +z.
    func mesh(metersPerPoint: Double) throws -> MeshResource {
        let columns = max(2, min(128, Int((2 * halfAngle * 180 / .pi).rounded(.up))))
        let r = radius * metersPerPoint
        let halfHeight = Float(contentRect.height * metersPerPoint / 2)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        for column in 0...columns {
            let fraction = Double(column) / Double(columns)
            let theta = -halfAngle + 2 * halfAngle * fraction
            let x = Float(r * sin(theta))
            let z = Float(r * (1 - cos(theta)))
            let normal = SIMD3<Float>(Float(-sin(theta)), 0, Float(cos(theta)))
            positions += [[x, -halfHeight, z], [x, halfHeight, z]]
            normals += [normal, normal]
            uvs += [[Float(fraction), 0], [Float(fraction), 1]]
        }
        var indices: [UInt32] = []
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

    /// The largest curve of `radius` whose outline, seen from the circle's
    /// centre, fits inside `view`. The edges come forward, so seen from the
    /// viewer's seat they look wider (R·tan α instead of R·α) and taller (by
    /// 1/cos α) than the picture is; fitting the picture itself to the window
    /// let the forward corners cover the window's ornaments and resize
    /// handles. Fitting this outline keeps them clear.
    static func fitted(stream: CGSize, in view: CGSize, radius: Double) -> NativeScreenCurve {
        guard stream.width > 0, stream.height > 0, view.width > 0, view.height > 0, radius > 0 else {
            return NativeScreenCurve(contentRect: CGRect(origin: .zero, size: view), radius: max(radius, 1))
        }
        let aspect = stream.width / stream.height
        func fits(_ halfAngle: Double) -> Bool {
            let arc = 2 * radius * halfAngle
            return 2 * radius * tan(halfAngle) <= view.width
                && (arc / aspect) / cos(halfAngle) <= view.height
        }
        var low = 0.0, high = Double.pi / 2 - 0.01
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        let width = 2 * radius * low
        let height = width / aspect
        return NativeScreenCurve(
            contentRect: CGRect(
                x: (view.width - width) / 2,
                y: (view.height - height) / 2,
                width: width,
                height: height
            ),
            radius: radius
        )
    }

    /// The outline's aspect ratio, for locking the window to it.
    var outlineAspect: Double {
        (2 * radius * tan(halfAngle)) / (contentRect.height / cos(halfAngle))
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

/// The curved desktop's texture: each decoded frame copied into a RealityKit
/// `LowLevelTexture` and its mip chain rebuilt on the GPU.
///
/// The mips are the point. A video material samples a single full-size
/// image, so where the desktop is drawn small — at a distance, or outside the
/// gaze where the system renders at lower resolution — each screen pixel
/// lands on a few scattered texels of fine text, and which ones changes as
/// the head moves: shimmer. With mips the sampler reads a pre-filtered,
/// smaller copy matched to the size it is drawn at.
@MainActor
final class MacNativeCurvedTexture {
    private(set) var resource: TextureResource?
    private var texture: LowLevelTexture?
    private var size: (width: Int, height: Int) = (0, 0)
    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private var cache: CVMetalTextureCache?

    init() {
        if let device {
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        }
    }

    /// Draws `pixelBuffer` (BGRA, IOSurface-backed). Returns true when the
    /// texture had to be rebuilt for a new size, so the material needs the
    /// new resource.
    @discardableResult
    func update(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let cache, let queue else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var rebuilt = false
        if texture == nil || size != (width, height) {
            guard rebuild(width: width, height: height) else { return false }
            rebuilt = true
        }
        guard let texture else { return rebuilt }

        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm_srgb, width, height, 0, &cvTexture
        )
        guard let cvTexture, let source = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = queue.makeCommandBuffer() else { return rebuilt }
        let destination = texture.replace(using: commandBuffer)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: source, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: destination, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.generateMipmaps(for: destination)
            blit.endEncoding()
        }
        // Keeps the decoder's surface alive until the GPU has copied it.
        commandBuffer.addCompletedHandler { _ in _ = cvTexture }
        commandBuffer.commit()
        return rebuilt
    }

    private func rebuild(width: Int, height: Int) -> Bool {
        let levels = Int(log2(Double(max(width, height)))) + 1
        let descriptor = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapLevelCount: levels,
            textureUsage: [.shaderRead, .shaderWrite, .renderTarget]
        )
        guard let texture = try? LowLevelTexture(descriptor: descriptor),
              let resource = try? TextureResource(from: texture) else { return false }
        self.texture = texture
        self.resource = resource
        size = (width, height)
        return true
    }
}

/// The desktop drawn on the curve, with its pointer input taken on the mesh
/// itself: a tap or drag arrives as a 3D hit on the surface, which maps to
/// the picture exactly, from wherever the viewer is.
struct NativeCurvedScreenView: View {
    let surface: MacNativeFrameSurface
    let curve: NativeScreenCurve
    let onTap: (CGPoint) -> Void
    let onLongPress: () -> Void
    let onDragChanged: (_ point: CGPoint, _ translation: CGSize) -> Void
    let onDragEnded: (CGPoint) -> Void

    @Environment(\.physicalMetrics) private var physicalMetrics
    @State private var screen = Entity()
    @State private var texture = MacNativeCurvedTexture()
    @State private var builtCurve: NativeScreenCurve?
    @State private var dragStart: CGPoint?

    private var metersPerPoint: Double {
        Double(physicalMetrics.convert(1, to: .meters))
    }

    var body: some View {
        RealityView { content in
            screen.components.set(InputTargetComponent())
            content.add(screen)
        } update: { content in
            // The picture's centre on the window plane, in the content's
            // space — RealityView's origin is not documented to sit there.
            let center = content.convert(
                Point3D(x: curve.contentRect.midX, y: curve.contentRect.midY, z: 0),
                from: .local,
                to: .scene
            )
            screen.position = SIMD3<Float>(center)
            guard builtCurve != curve else { return }
            rebuildMesh()
        }
        .gesture(
            SpatialTapGesture()
                .targetedToEntity(screen)
                .onEnded { value in
                    onTap(flatPoint(value.convert(value.location3D, from: .local, to: screen)))
                }
        )
        .gesture(
            LongPressGesture(minimumDuration: 0.55)
                .targetedToEntity(screen)
                .onEnded { _ in onLongPress() }
        )
        .gesture(
            DragGesture(minimumDistance: 4)
                .targetedToEntity(screen)
                .onChanged { value in
                    let point = flatPoint(value.convert(value.location3D, from: .local, to: screen))
                    let start = dragStart ?? point
                    dragStart = start
                    onDragChanged(point, CGSize(width: point.x - start.x, height: point.y - start.y))
                }
                .onEnded { value in
                    onDragEnded(flatPoint(value.convert(value.location3D, from: .local, to: screen)))
                    dragStart = nil
                }
        )
        // The edges come forward out of the window plane; without a front
        // margin the system clips them off.
        .preferredWindowClippingMargins(.front, curve.sagitta + 8)
        .onAppear {
            surface.onFrame = { frame in
                if texture.update(frame) { applyMaterial() }
            }
        }
        .onDisappear {
            surface.onFrame = nil
        }
    }

    private func flatPoint(_ local: SIMD3<Float>) -> CGPoint {
        curve.flatPoint(meshLocal: local, metersPerPoint: metersPerPoint)
    }

    private func rebuildMesh() {
        guard let mesh = try? curve.mesh(metersPerPoint: metersPerPoint) else { return }
        if screen.components[ModelComponent.self] == nil {
            screen.components.set(ModelComponent(mesh: mesh, materials: []))
            applyMaterial()
        } else {
            screen.components[ModelComponent.self]?.mesh = mesh
        }
        let built = curve
        Task { @MainActor in
            builtCurve = built
            // The collision shape is what targeted gestures hit-test against,
            // so it follows the mesh — exact, not a box around it.
            if let shape = try? await ShapeResource.generateStaticMesh(from: mesh), builtCurve == built {
                screen.components.set(CollisionComponent(shapes: [shape]))
            }
        }
    }

    private func applyMaterial() {
        guard let resource = texture.resource else { return }
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        sampler.maxAnisotropy = 8
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(resource, sampler: .init(sampler)))
        screen.components[ModelComponent.self]?.materials = [material]
    }
}
#endif

#if os(visionOS)
/// Hands back the `UIWindowScene` hosting a SwiftUI view, for requests
/// SwiftUI has no API for — locking a window's aspect ratio.
struct WindowSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScene = onScene
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onScene = onScene
    }

    final class ReaderView: UIView {
        var onScene: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onScene?(window?.windowScene)
        }
    }
}

extension UIWindowScene {
    /// Keeps user resizes at `aspect` (width / height), resizing to it now at
    /// the current width; nil hands resizing back to the system.
    func lockAspect(_ aspect: Double?) {
        let preferences: UIWindowScene.GeometryPreferences.Vision
        if let aspect, aspect > 0 {
            let width = effectiveGeometry.coordinateSpace.bounds.width
            preferences = .init(
                size: CGSize(width: width, height: width / aspect),
                minimumSize: nil,
                maximumSize: nil,
                resizingRestrictions: .uniform
            )
        } else {
            preferences = .init(size: nil, minimumSize: nil, maximumSize: nil, resizingRestrictions: .freeform)
        }
        requestGeometryUpdate(preferences)
    }
}
#endif
