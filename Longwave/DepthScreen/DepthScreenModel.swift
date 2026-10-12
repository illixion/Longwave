#if os(visionOS)
import CoreVideo
import Foundation

// The pure half of "3D for flat games" (NATIVE_V3_PROTOCOL.md §4.8): what a
// depth frame's numbers mean and how they become a relief mesh. No Metal and no
// RealityKit here, so every rule can be unit-tested; the mesh kernel in
// `DepthScreenShaders.metal` mirrors `DepthScreenGeometry` and the two must be
// kept in step.

/// A depth frame's `depthRange` side data: the planes its inverse depth was
/// quantised between, the game profile's suggested convergence distance, and
/// whether the frame has depth at all (a pre-rendered cutscene sends a cleared
/// buffer, which the host marks empty).
///
/// Units are whatever the game's camera uses; only ratios matter to the
/// headset, so metres are assumed for defaults but nothing depends on it.
///
/// The renderer's own copy of `StreamWire.DepthRange` (branch `v3-wire`), with
/// the same fields: when the feed is wired to the Native stream it is built
/// from that — `.planes(near, far, convergence)` field for field, with a wire
/// convergence of 0 ("no suggestion") becoming nil, and `.empty` becoming
/// `.empty`. Named apart so the two can't be confused once the app imports
/// StreamWire.
nonisolated struct DepthScreenRange: Equatable, Sendable {
    var near: Float
    /// `.infinity` for an infinite far plane (common with reversed Z).
    var far: Float
    /// The distance that should sit on the window plane, when the game's
    /// profile suggests one.
    var convergence: Float?
    var isEmpty: Bool

    init(near: Float, far: Float, convergence: Float? = nil, isEmpty: Bool = false) {
        self.near = near
        self.far = far
        self.convergence = convergence
        self.isEmpty = isEmpty
    }

    static let empty = DepthScreenRange(near: 0.1, far: .infinity, isEmpty: true)

    /// Wire encoding (§4.8): `v = (1/z − 1/far) / (1/near − 1/far)`, so 1 is
    /// the near plane, 0 the far plane, and `v` is linear in inverse depth —
    /// which is what stereo disparity is proportional to.
    var inverseScale: Float { 1 / near - inverseBias }
    var inverseBias: Float { far.isFinite ? 1 / far : 0 }

    /// Metric inverse depth (1/z) for a normalised sample.
    func metricInverseDepth(normalized v: Float) -> Float {
        min(max(v, 0), 1) * inverseScale + inverseBias
    }

    /// The distance a normalised sample decodes to. `.infinity` at v = 0 with
    /// an infinite far plane.
    func distance(normalized v: Float) -> Float {
        let inverse = metricInverseDepth(normalized: v)
        return inverse > 0 ? 1 / inverse : .infinity
    }

    /// A distance to its normalised sample, clamped to the range.
    func normalized(distance z: Float) -> Float {
        guard z > 0, inverseScale > 0 else { return 0 }
        return min(max((1 / z - inverseBias) / inverseScale, 0), 1)
    }
}

/// How a depth texture's samples map to the normalised inverse depth `v`.
///
/// The wire carries 10-bit luma in HEVC Main10, which VideoToolbox hands back
/// as `x420`/`xf20`: each 10-bit code in the most significant bits of a 16-bit
/// word, so a `.r16Unorm` view samples `code · 64 / 65535`. Video range puts
/// black at code 64 and white at 940.
nonisolated enum DepthSampleEncoding: Equatable, Sendable {
    case videoRange10
    case fullRange10
    /// The sample already is `v` (float textures, or unorm written directly).
    case unitInterval

    /// `v = sample · scale + bias`, the affine the mesh kernel applies.
    var scaleBias: (scale: Float, bias: Float) {
        let codePerSample: Float = 65535 / 64
        switch self {
        case .videoRange10: return (codePerSample / 876, -64 / 876)
        case .fullRange10: return (codePerSample / 1023, 0)
        case .unitInterval: return (1, 0)
        }
    }

    func normalized(sample: Float) -> Float {
        let (scale, bias) = scaleBias
        return min(max(sample * scale + bias, 0), 1)
    }

    /// The sample a 10-bit code reads back as through a `.r16Unorm` view.
    static func sample(forCode code: Int) -> Float {
        Float(code << 6) / 65535
    }

    /// Inferred from the decoder's output format; nil for one the renderer
    /// can't read depth from.
    init?(pixelFormat: OSType) {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: self = .videoRange10
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: self = .fullRange10
        case kCVPixelFormatType_OneComponent32Float,
             kCVPixelFormatType_OneComponent16Half,
             kCVPixelFormatType_DepthFloat32,
             kCVPixelFormatType_OneComponent16,
             kCVPixelFormatType_OneComponent8:
            self = .unitInterval
        default: return nil
        }
    }
}

/// What the stretched triangles at a depth edge get.
nonisolated enum DepthEdgeMode: String, CaseIterable, Identifiable, Sendable {
    /// The picture is stretched across the gap (the raw displaced mesh).
    case stretch
    /// The gap is textured with the background beside it, mirrored across the
    /// outline, so the outline's own pixels don't smear across it.
    case fill
    /// The gap is left open (a hole).
    case cut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stretch: "Stretch"
        case .fill: "Fill"
        case .cut: "Cut"
        }
    }

    /// The value the kernel switches on.
    var shaderValue: UInt32 {
        switch self {
        case .stretch: 0
        case .fill: 1
        case .cut: 2
        }
    }
}

/// The user-facing knobs.
nonisolated struct DepthScreenSettings: Equatable, Sendable {
    /// How far behind the window plane infinitely distant content sits, as a
    /// fraction of the screen's width. Everything behind the convergence
    /// distance lands between the glass and this depth, so the eyes can never
    /// be asked to diverge, whatever the game sends.
    var strength: Float = 0.2
    /// The distance on the window plane, overriding the profile's suggestion.
    var convergenceOverride: Float?
    /// How far content nearer than the convergence distance may come out of
    /// the window, as a fraction of `strength`'s depth. It approaches this
    /// softly, so a weapon at the near plane doesn't poke into the viewer.
    var popOutLimit: Float = 0.35
    var edgeMode: DepthEdgeMode = .fill
    /// A cell whose relief rises more than this many cell widths across it is
    /// treated as a depth edge rather than a steep surface.
    var maxSlope: Float = 3
    /// The finest mesh, in vertices across. The grid otherwise follows the
    /// depth texture's own resolution.
    var maxColumns: Int = 384

    /// Used when neither the user nor the game's profile names a convergence.
    static let fallbackConvergence: Float = 2

    func convergence(for range: DepthScreenRange) -> Float {
        let suggested = convergenceOverride ?? range.convergence ?? Self.fallbackConvergence
        return min(max(suggested, range.near), range.far.isFinite ? range.far : .greatestFiniteMagnitude)
    }
}

/// The relief: where each depth sample goes in front of or behind the window
/// plane. Mirrored by `depthScreenMesh` in the Metal kernel.
nonisolated enum DepthScreenGeometry {
    /// Fraction of the width over which relief fades to zero at each border,
    /// so the screen's outline stays a flat rectangle on the window plane and
    /// near content cut by the frame isn't a window violation. Vergence's warp
    /// feathers over 5% (`pseudo3DEdgeFeather`); the mesh needs less because
    /// it isn't sampling outside the frame.
    static let borderFeather: Float = 0.03

    /// Normalised relief for a sample: 0 on the window plane, −1 at infinity,
    /// positive (toward the viewer) for content nearer than the convergence
    /// distance, softly limited to `popOutLimit`.
    ///
    /// Behind the plane it is `1/z ÷ 1/zc − 1`: scaled stereo, linear in
    /// inverse depth like real disparity, anchored at the convergence distance.
    /// Normalising by the near/far range instead would hand nearly all of the
    /// relief to the first metre in front of a game camera with a 0.1 m near
    /// plane and leave the world beyond it flat.
    static func relief(normalized v: Float, range: DepthScreenRange, convergence: Float, popOutLimit: Float) -> Float {
        let inverse = range.metricInverseDepth(normalized: v)
        let r = inverse * convergence - 1
        guard r > 0 else { return max(r, -1) }
        guard popOutLimit > 0 else { return 0 }
        return popOutLimit * tanh(r / popOutLimit)
    }

    /// 0 at the border, 1 inside it.
    static func feather(_ u: Float) -> Float {
        smoothstep(0, borderFeather, u) * (1 - smoothstep(1 - borderFeather, 1, u))
    }

    /// Whether a cell is a depth edge: its corners' relief (in metres) spans
    /// more than `maxSlope` cell widths. A plane in the game, however steep, is
    /// linear in inverse depth across the screen, so it stays below this
    /// unless it is nearly edge-on; an outline jumps.
    static func isEdge(reliefs: [Float], cellWidth: Float, maxSlope: Float) -> Bool {
        guard let low = reliefs.min(), let high = reliefs.max(), cellWidth > 0 else { return false }
        return (high - low) / cellWidth > maxSlope
    }

    /// For each corner of an edge cell (TL, TR, BL, BR), the corner whose
    /// texture coordinate it is mirrored across in fill mode, or nil when the
    /// corner keeps its own. A near corner mirrors across its horizontal
    /// neighbour when that one is far (an outline moving sideways, the common
    /// case with eyes side by side), else its vertical neighbour, else the
    /// farthest corner.
    static func fillSources(reliefs: [Float], cellWidth: Float, maxSlope: Float) -> [Int?] {
        precondition(reliefs.count == 4)
        guard let low = reliefs.min(), let farthest = reliefs.firstIndex(of: low) else {
            return [nil, nil, nil, nil]
        }
        let nearThreshold = maxSlope * cellWidth * 0.5
        func isNear(_ corner: Int) -> Bool { reliefs[corner] - low > nearThreshold }
        return (0..<4).map { corner in
            guard isNear(corner) else { return nil }
            let horizontal = corner ^ 1
            let vertical = corner ^ 2
            if !isNear(horizontal) { return horizontal }
            if !isNear(vertical) { return vertical }
            return farthest
        }
    }

    /// The angle, in arcminutes, between the two eyes' lines of sight to a
    /// point `relief` metres in front of (positive) or behind the window plane
    /// relative to the plane itself — positive for uncrossed (behind) points.
    static func angularDisparity(relief: Float, viewerDistance: Float, interpupillary: Float = 0.063) -> Float {
        let depth = viewerDistance - relief
        guard depth > 0, viewerDistance > 0 else { return .infinity }
        let onScreen = interpupillary * -relief / depth
        return atan(onScreen / viewerDistance) * 180 / .pi * 60
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The mesh's grid: vertices across and down, following the depth texture.
nonisolated struct DepthMeshGrid: Equatable, Sendable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = max(2, columns)
        self.rows = max(2, rows)
    }

    /// One vertex per depth texel up to `maxColumns` across, rows following
    /// the depth texture's aspect.
    init(depthWidth: Int, depthHeight: Int, maxColumns: Int) {
        let columns = max(2, min(depthWidth, maxColumns))
        let aspect = depthWidth > 0 ? Double(depthHeight) / Double(depthWidth) : 9.0 / 16.0
        self.init(columns: columns, rows: Int((Double(columns) * aspect).rounded()))
    }

    var cellCount: Int { (columns - 1) * (rows - 1) }
    /// Each cell owns its four corners, so an edge cell can be filled or cut
    /// without touching its neighbours.
    var vertexCount: Int { cellCount * 4 }
    var indexCount: Int { cellCount * 6 }

    /// Two counter-clockwise triangles per cell (seen from +z, the viewer's
    /// side), over corners laid out TL, TR, BL, BR.
    func indices() -> [UInt32] {
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for cell in 0..<UInt32(cellCount) {
            let base = cell * 4
            indices += [base, base + 2, base + 1, base + 1, base + 2, base + 3]
        }
        return indices
    }
}
#endif
