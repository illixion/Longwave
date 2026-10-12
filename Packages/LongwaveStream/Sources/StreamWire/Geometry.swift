// Poses and fields of view for PCVR (section 4.7).
//
// Conventions follow OpenXR, which the PCVR host's frame source speaks, and
// which agree with ARKit/RealityKit on the headset: metres, right-handed,
// +Y up, -Z forward. Every component is an IEEE 754 binary32, little-endian,
// with no quantisation. Non-finite values are rejected, which also keeps
// decoded values comparable (NaN != NaN would break round-trip checks).

public struct Vector3: Sendable, Hashable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(_ x: Float, _ y: Float, _ z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(0, 0, 0)

    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    var lengthSquared: Float { x * x + y * y + z * z }
}

/// A rotation as a unit quaternion, (x, y, z, w) on the wire as in OpenXR's
/// `XrQuaternionf`.
public struct Quaternion: Sendable, Hashable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

    /// Unit length within 1% (squared norm), which tolerates binary32 noise
    /// from a pose pipeline but rejects garbage.
    var isValidRotation: Bool {
        guard x.isFinite, y.isFinite, z.isFinite, w.isFinite else { return false }
        let normSquared = x * x + y * y + z * z + w * w
        return abs(normSquared - 1) <= 0.01
    }
}

/// A rigid transform. Wire: orientation (16 bytes) then position (12 bytes),
/// the field order of OpenXR's `XrPosef`.
public struct Pose: Sendable, Hashable {
    public static let wireSize = 28

    public var orientation: Quaternion
    public var position: Vector3

    public init(orientation: Quaternion, position: Vector3) {
        self.orientation = orientation
        self.position = position
    }

    public static let identity = Pose(orientation: .identity, position: .zero)

    func validate(_ field: String) throws(WireError) {
        guard orientation.isValidRotation, position.isFinite else { throw .invalid(field) }
    }
}

/// A view's field of view as four signed angles in radians, OpenXR's
/// `XrFovf`: left and down are normally negative.
public struct FieldOfView: Sendable, Hashable {
    public static let wireSize = 16

    public var angleLeft: Float
    public var angleRight: Float
    public var angleUp: Float
    public var angleDown: Float

    public init(angleLeft: Float, angleRight: Float, angleUp: Float, angleDown: Float) {
        self.angleLeft = angleLeft
        self.angleRight = angleRight
        self.angleUp = angleUp
        self.angleDown = angleDown
    }

    func validate(_ field: String) throws(WireError) {
        let limit = Float.pi / 2
        for angle in [angleLeft, angleRight, angleUp, angleDown] {
            guard angle.isFinite, angle > -limit, angle < limit else { throw .invalid(field) }
        }
        guard angleLeft < angleRight, angleDown < angleUp else { throw .invalid(field) }
    }
}

/// One eye's pose and field of view.
public struct EyeView: Sendable, Hashable {
    public static let wireSize = Pose.wireSize + FieldOfView.wireSize

    public var pose: Pose
    public var fieldOfView: FieldOfView

    public init(pose: Pose, fieldOfView: FieldOfView) {
        self.pose = pose
        self.fieldOfView = fieldOfView
    }

    func validate(_ field: String) throws(WireError) {
        try pose.validate(field + ".pose")
        try fieldOfView.validate(field + ".fieldOfView")
    }
}

extension WireReader {
    mutating func readVector3() throws(WireError) -> Vector3 {
        Vector3(try readFloat32(), try readFloat32(), try readFloat32())
    }

    mutating func readPose() throws(WireError) -> Pose {
        let orientation = Quaternion(x: try readFloat32(), y: try readFloat32(), z: try readFloat32(), w: try readFloat32())
        return Pose(orientation: orientation, position: try readVector3())
    }

    mutating func readFieldOfView() throws(WireError) -> FieldOfView {
        FieldOfView(angleLeft: try readFloat32(), angleRight: try readFloat32(),
                    angleUp: try readFloat32(), angleDown: try readFloat32())
    }

    mutating func readEyeView() throws(WireError) -> EyeView {
        EyeView(pose: try readPose(), fieldOfView: try readFieldOfView())
    }
}

extension WireWriter {
    mutating func writeVector3(_ v: Vector3) {
        writeFloat32(v.x)
        writeFloat32(v.y)
        writeFloat32(v.z)
    }

    mutating func writePose(_ pose: Pose) {
        writeFloat32(pose.orientation.x)
        writeFloat32(pose.orientation.y)
        writeFloat32(pose.orientation.z)
        writeFloat32(pose.orientation.w)
        writeVector3(pose.position)
    }

    mutating func writeFieldOfView(_ fov: FieldOfView) {
        writeFloat32(fov.angleLeft)
        writeFloat32(fov.angleRight)
        writeFloat32(fov.angleUp)
        writeFloat32(fov.angleDown)
    }

    mutating func writeEyeView(_ eye: EyeView) {
        writePose(eye.pose)
        writeFieldOfView(eye.fieldOfView)
    }
}
