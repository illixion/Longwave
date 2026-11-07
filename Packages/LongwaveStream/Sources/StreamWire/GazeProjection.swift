// Device-relative gaze to an eye's warp centre (NATIVE_V3_PROTOCOL.md section
// 4.7, "Gaze projection"). The host centres its foveation warp with this; the
// headset's `PCVREyeGeometry.gazeCentre` calls it too, so both sides project
// the same way.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

public enum GazeProjection {
    /// Where head-space gaze lands in one eye's unwarped image, as top-left UVs.
    ///
    /// - Parameters:
    ///   - direction: The gaze ray in head (device) space, -Z ahead. Need not be unit length.
    ///   - distance: Metres to the fixation point. A positive distance puts a
    ///     point on the ray and projects it through the eye's own position (the
    ///     parallax between the eyes at a near fixation); zero means unknown and
    ///     projects the direction alone, as a point at infinity.
    ///   - deviceFromEye: The eye's pose relative to the head (`HeadPose.leftEye.pose`).
    ///   - fieldOfView: The eye's frustum, asymmetric as rendered.
    /// - Returns: nil for a non-finite or zero direction, a negative distance or
    ///   a point behind the eye. Gaze ahead of the eye but outside its frustum
    ///   clamps to the nearest edge: the centre then sits as close to the
    ///   gaze as the image allows. Callers check the sample's age first; this
    ///   never applies a world head pose to device-relative gaze.
    public static func centre(direction: Vector3, distance: Float, deviceFromEye: Pose,
                              fieldOfView: FieldOfView) -> NormalizedPoint? {
        let length = direction.lengthSquared.squareRoot()
        guard direction.isFinite, length.isFinite, length > 1e-6, distance.isFinite, distance >= 0 else { return nil }
        let ray = Vector3(direction.x / length, direction.y / length, direction.z / length)
        guard let rotation = deviceFromEye.orientation.normalized, deviceFromEye.position.isFinite else { return nil }
        let eyeFromDevice = rotation.conjugate
        let point: Vector3
        if distance > 0 {
            let p = deviceFromEye.position
            point = eyeFromDevice.rotate(Vector3(ray.x * distance - p.x, ray.y * distance - p.y, ray.z * distance - p.z))
        } else {
            point = eyeFromDevice.rotate(ray)
        }
        guard point.isFinite, point.z < 0 else { return nil }
        // In Double: Windows' C library has no Float overload of tan.
        func tangent(_ angle: Float) -> Float { Float(tan(Double(angle))) }
        let left = tangent(fieldOfView.angleLeft), right = tangent(fieldOfView.angleRight)
        let up = tangent(fieldOfView.angleUp), down = tangent(fieldOfView.angleDown)
        guard right - left > 1e-6, up - down > 1e-6 else { return nil }
        let x = point.x / -point.z, y = point.y / -point.z
        let ndcX = (2 * x - (right + left)) / (right - left)
        let ndcY = (2 * y - (up + down)) / (up - down)
        guard ndcX.isFinite, ndcY.isFinite else { return nil }
        return NormalizedPoint(x: min(max((ndcX + 1) / 2, 0), 1), y: min(max((1 - ndcY) / 2, 0), 1))
    }
}

extension Quaternion {
    /// This rotation at unit length, or nil for one too degenerate to normalise.
    var normalized: Quaternion? {
        guard x.isFinite, y.isFinite, z.isFinite, w.isFinite else { return nil }
        let norm = (x * x + y * y + z * z + w * w).squareRoot()
        guard norm > 1e-6 else { return nil }
        return Quaternion(x: x / norm, y: y / norm, z: z / norm, w: w / norm)
    }

    /// The inverse of a unit quaternion.
    var conjugate: Quaternion { Quaternion(x: -x, y: -y, z: -z, w: w) }

    /// `v` rotated by this unit quaternion (q v q*), via
    /// `t = 2 (q.xyz × v)`, `v' = v + w t + q.xyz × t`.
    func rotate(_ v: Vector3) -> Vector3 {
        let tx = 2 * (y * v.z - z * v.y)
        let ty = 2 * (z * v.x - x * v.z)
        let tz = 2 * (x * v.y - y * v.x)
        return Vector3(v.x + w * tx + (y * tz - z * ty),
                       v.y + w * ty + (z * tx - x * tz),
                       v.z + w * tz + (x * ty - y * tx))
    }
}
