#if FOVEATED_ENABLED
import Foundation
import simd

// The geometry the PCVR receiver speaks: rigid poses, per-eye fields of view
// and stereo pairs. Plain values with no CompositorServices, RealityKit or
// ARKit types, so the same receiver can sit behind the app's CompositorLayer
// today and behind whatever the foveated-streaming provider extension allows
// later (NATIVE_V3_PROTOCOL.md §4.7, open question 16).
//
// Conventions, shared with ARKit and CompositorServices so the presenter can
// copy values across without a conversion step:
// - Right-handed, metres, +Y up. A camera looks down its own -Z.
// - A pose is `parentFromChild`: `PCVRPose` for an eye is world-from-eye, so it
//   maps eye-space points into the immersive space.

/// A rigid transform: a rotation followed by a translation, no scale.
nonisolated struct PCVRPose: Equatable, Sendable {
    var rotation: simd_quatf
    var position: SIMD3<Float>

    static let identity = PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: .zero)

    init(rotation: simd_quatf, position: SIMD3<Float>) {
        self.rotation = rotation.normalized
        self.position = position
    }

    /// From a rigid 4x4 (ARKit's `originFromAnchorTransform`, a CompositorServices
    /// view's `transform`). Any scale or shear is discarded by normalising the
    /// basis, which a tracking transform should not carry anyway.
    init(_ matrix: simd_float4x4) {
        let basis = simd_float3x3(
            simd_normalize(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)),
            simd_normalize(SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)),
            simd_normalize(SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        )
        self.init(rotation: simd_quatf(basis),
                  position: SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z))
    }

    var matrix: simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4(position, 1)
        return m
    }

    var inverse: PCVRPose {
        let inverted = rotation.inverse
        return PCVRPose(rotation: inverted, position: inverted.act(-position))
    }

    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        rotation.act(point) + position
    }

    func transformVector(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        rotation.act(vector)
    }

    /// `a * b` is `b` expressed in `a`'s parent: `worldFromEye = worldFromDevice * deviceFromEye`.
    static func * (lhs: PCVRPose, rhs: PCVRPose) -> PCVRPose {
        PCVRPose(rotation: lhs.rotation * rhs.rotation, position: lhs.transformPoint(rhs.position))
    }

    /// True when both differ from `other` by less than the given distance and angle.
    func isClose(to other: PCVRPose, metres: Float, radians: Float) -> Bool {
        guard simd_distance(position, other.position) <= metres else { return false }
        // The angle of the relative rotation, from atan2 rather than acos of a
        // dot product: acos is ill-conditioned near 1, where float rounding alone
        // reads as a fraction of a milliradian. abs(real) folds q and -q together.
        let delta = rotation.inverse * other.rotation
        return 2 * atan2(simd_length(delta.imag), abs(delta.real)) <= radians
    }
}

/// An eye's field of view as OpenXR's `XrFovf`: four signed angles in radians
/// from the view axis to each edge, left and down negative. The same
/// convention as the Native v3 wire (StreamWire's `FieldOfView`), so values
/// cross the network unconverted. Asymmetric frusta are the norm on a headset;
/// nothing here assumes symmetry. The maths works in tangents, derived below.
nonisolated struct PCVRFieldOfView: Equatable, Sendable {
    var angleLeft: Float
    var angleRight: Float
    var angleUp: Float
    var angleDown: Float

    init(angleLeft: Float, angleRight: Float, angleUp: Float, angleDown: Float) {
        self.angleLeft = angleLeft
        self.angleRight = angleRight
        self.angleUp = angleUp
        self.angleDown = angleDown
    }

    /// From signed tangents of the same four angles (left and down negative).
    init(tangentLeft: Float, tangentRight: Float, tangentUp: Float, tangentDown: Float) {
        self.init(angleLeft: atan(tangentLeft), angleRight: atan(tangentRight),
                  angleUp: atan(tangentUp), angleDown: atan(tangentDown))
    }

    /// From a perspective projection whose clip `x` and `y` are
    /// `P[0][0]·x + P[2][0]·z` and `P[1][1]·y + P[2][1]·z` over `w = -z`, which
    /// every right-handed projection has whatever its depth convention
    /// (CompositorServices' `computeProjection`, this type's `projectionMatrix`).
    /// NDC is `P[0][0]·u − P[2][0]` for the tangent `u`, so the edges at NDC ±1
    /// sit at `u = (±1 + P[2][0]) / P[0][0]`.
    init(projection p: simd_float4x4) {
        self.init(tangentLeft: (p.columns.2.x - 1) / p.columns.0.x,
                  tangentRight: (p.columns.2.x + 1) / p.columns.0.x,
                  tangentUp: (p.columns.2.y + 1) / p.columns.1.y,
                  tangentDown: (p.columns.2.y - 1) / p.columns.1.y)
    }

    /// Signed tangents in `XrFovf` order: (left, right, up, down), left and down negative.
    var tangents: SIMD4<Float> {
        SIMD4(tan(angleLeft), tan(angleRight), tan(angleUp), tan(angleDown))
    }

    /// The same frustum widened by `fraction` of each edge's tangent: what a
    /// host renders when it overscans to leave reprojection something to show
    /// at the edges (see `PCVRReprojection`).
    func expanded(by fraction: Float) -> PCVRFieldOfView {
        let t = tangents * (1 + max(fraction, 0))
        return PCVRFieldOfView(tangentLeft: t.x, tangentRight: t.y, tangentUp: t.z, tangentDown: t.w)
    }

    /// Maps a forward-tangent vector `(x / -z, y / -z, 1)` to homogeneous NDC
    /// `(ndcX, ndcY, 1)`, NDC spanning -1...1 across the frustum with +Y up.
    var ndcFromTangent: simd_float3x3 {
        let t = tangents
        let width = t.y - t.x, height = t.z - t.w
        return simd_float3x3(
            SIMD3(2 / width, 0, 0),
            SIMD3(0, 2 / height, 0),
            SIMD3(-(t.y + t.x) / width, -(t.z + t.w) / height, 1)
        )
    }

    var tangentFromNDC: simd_float3x3 {
        let t = tangents
        return simd_float3x3(
            SIMD3((t.y - t.x) / 2, 0, 0),
            SIMD3(0, (t.z - t.w) / 2, 0),
            SIMD3((t.y + t.x) / 2, (t.z + t.w) / 2, 1)
        )
    }

    /// NDC of an eye-space point, or nil when it is behind the eye.
    func ndc(ofEyePoint point: SIMD3<Float>) -> SIMD2<Float>? {
        guard point.z < 0 else { return nil }
        let tangent = SIMD3(point.x / -point.z, point.y / -point.z, 1)
        let ndc = ndcFromTangent * tangent
        return SIMD2(ndc.x, ndc.y)
    }

    /// A right-handed perspective projection to Metal clip space (z in 0...1,
    /// forward depth: near maps to 0). For producers that rasterise a frame,
    /// like the fake remote; the presenter's own projection comes from its host.
    func projectionMatrix(near: Float, far: Float) -> simd_float4x4 {
        let t = tangents
        let l = t.x * near, r = t.y * near, b = t.w * near, top = t.z * near
        return simd_float4x4(
            SIMD4(2 * near / (r - l), 0, 0, 0),
            SIMD4(0, 2 * near / (top - b), 0, 0),
            SIMD4((r + l) / (r - l), (top + b) / (top - b), far / (near - far), -1),
            SIMD4(0, 0, near * far / (near - far), 0)
        )
    }
}

/// Where one eye was (or will be) and what it sees.
nonisolated struct PCVREyeView: Equatable, Sendable {
    /// World-from-eye: the immersive space's origin, not the device.
    var pose: PCVRPose
    var fieldOfView: PCVRFieldOfView
}

/// An eye's fixed relation to the device: §4.7's per-eye offset and field of
/// view, sent with every head-pose snapshot.
nonisolated struct PCVREyeGeometry: Equatable, Sendable {
    var deviceFromEye: PCVRPose
    var fieldOfView: PCVRFieldOfView

    func view(head: PCVRPose) -> PCVREyeView {
        PCVREyeView(pose: head * deviceFromEye, fieldOfView: fieldOfView)
    }
}

/// A left/right pair. The receiver is stereo by definition, so this replaces an
/// array whose count would have to be checked everywhere.
nonisolated struct PCVRStereo<Value> {
    var left: Value
    var right: Value

    subscript(index: Int) -> Value {
        get { index == 0 ? left : right }
        set { if index == 0 { left = newValue } else { right = newValue } }
    }

    func map<T>(_ transform: (Value) throws -> T) rethrows -> PCVRStereo<T> {
        PCVRStereo<T>(left: try transform(left), right: try transform(right))
    }
}

extension PCVRStereo: Equatable where Value: Equatable {}
extension PCVRStereo: Sendable where Value: Sendable {}
#endif
