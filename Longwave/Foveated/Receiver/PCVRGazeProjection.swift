#if FOVEATED_ENABLED
import simd
import StreamWire

extension PCVREyeGeometry {
    /// Projects head-space gaze into this eye's unwarped image, top-left UVs.
    /// A positive distance supplies a finite head-space fixation point; zero
    /// means unknown distance and uses a ray at infinity (no invented depth).
    /// Callers enforce gaze freshness before projecting. Behind-eye or invalid
    /// input returns nil; offscreen forward gaze clamps to the nearest edge.
    ///
    /// The host centres its foveation warp with StreamWire's `GazeProjection`
    /// on the wire types; this is the same function, so both sides agree.
    func gazeCentre(direction: SIMD3<Float>, distance: Float = 0) -> NormalizedPoint? {
        let q = deviceFromEye.rotation.vector, p = deviceFromEye.position, fov = fieldOfView
        return GazeProjection.centre(
            direction: Vector3(direction.x, direction.y, direction.z), distance: distance,
            deviceFromEye: Pose(orientation: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w), position: Vector3(p.x, p.y, p.z)),
            fieldOfView: FieldOfView(angleLeft: fov.angleLeft, angleRight: fov.angleRight,
                                     angleUp: fov.angleUp, angleDown: fov.angleDown))
    }
}
#endif
