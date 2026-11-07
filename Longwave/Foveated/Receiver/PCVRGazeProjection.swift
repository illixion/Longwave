#if FOVEATED_ENABLED
import simd
import StreamWire

extension PCVREyeGeometry {
    /// Projects head-space gaze into this eye's unwarped image, top-left UVs.
    /// A positive distance supplies a finite head-space fixation point; zero
    /// means unknown distance and uses a ray at infinity (no invented depth).
    /// Callers enforce gaze freshness before projecting. Behind-eye or invalid
    /// input returns nil; offscreen forward gaze clamps to the nearest edge.
    func gazeCentre(direction: SIMD3<Float>, distance: Float = 0) -> NormalizedPoint? {
        let length = simd_length(direction)
        guard length.isFinite, length > 1e-6, distance.isFinite, distance >= 0 else { return nil }
        let ray = direction / length
        let eyeFromDevice = deviceFromEye.inverse
        let point = distance > 0 ? eyeFromDevice.transformPoint(ray * distance) : eyeFromDevice.transformVector(ray)
        guard let ndc = fieldOfView.ndc(ofEyePoint: point), ndc.x.isFinite, ndc.y.isFinite else { return nil }
        return NormalizedPoint(x: min(max((ndc.x + 1) / 2, 0), 1),
                               y: min(max((1 - ndc.y) / 2, 0), 1))
    }
}
#endif
