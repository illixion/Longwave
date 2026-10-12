#if FOVEATED_ENABLED
import Foundation
import simd

/// How the receiver moves a frame from the pose it was rendered at to the pose
/// it is shown at.
nonisolated enum PCVRReprojectionMode: Hashable, Sendable {
    /// Shown as rendered, as though the head had not moved since. Only useful
    /// as a baseline: every millisecond of latency swims the world with the head.
    case none
    /// Corrects rotation exactly and ignores translation: content behaves as if
    /// it were infinitely far away. The classic "timewarp".
    case rotation
    /// Corrects rotation exactly and translation for content at `planeDistance`
    /// metres in front of the render eye. Nearer content is under-corrected and
    /// farther content over-corrected (see `PCVRReprojection`).
    case rotationAndTranslation(planeDistance: Float)
}

/// The receiver's reprojection, as pure maths the shader only evaluates.
///
/// **What it does.** A stream frame was rendered for each eye at pose A (its
/// `renderPose` side data). It is shown with the eye at pose B, sampled from the
/// device anchor at the drawable's presentation time. For every display pixel
/// the receiver asks where that pixel's ray lands in the frame A saw, which is a
/// single 3x3 homography per eye from display NDC to source NDC. A frame has no
/// depth, so the homography assumes the whole picture lies on one proxy surface:
/// a plane at infinity (rotation only) or a plane at a fixed distance in front
/// of the render eye (rotation and translation). Both are exact for rotation.
/// For translation they are exact only for content on the proxy plane.
///
/// **Edges.** A display ray that lands outside the rendered frustum has nothing
/// to show. The shader fades those pixels to black over a short margin instead of
/// smearing the edge texels, and a host that overscans (renders a slightly
/// wider frustum than the display's, `PCVRFieldOfView.expanded(by:)`) leaves room
/// for a stale frame to be turned into before that happens. A ray that would hit
/// the proxy plane behind the eye is black too.
///
/// **Disocclusion.** None, by construction: a single-layer warp never tears the
/// image open, so nothing is revealed that the frame didn't contain. The price is
/// parallax error instead: with translation, objects off the proxy plane slide
/// against each other by `baseline × (1/d − 1/D)`. Fixing that needs per-pixel
/// depth (NATIVE_V3_PROTOCOL.md §4.8's depth auxiliary stream), and a depth-based
/// warp does disocclude, which brings back hole filling.
nonisolated enum PCVRReprojection {
    /// Depth assumed for the presenter's own depth buffer when the mode has no
    /// finite plane. The system compositor reprojects again from the drawable's
    /// depth; far content barely moves with translation, which is what rotation
    /// only means, but a pixel at infinity is clipped by the compositor's far
    /// plane, so it is far rather than infinite.
    static let rotationOnlyPresentationDepth: Float = 50

    /// The homography mapping display-eye NDC `(x, y, 1)` to homogeneous
    /// source-eye NDC. Divide by `z` for the source NDC; `z <= 0` means the ray
    /// does not reach the proxy surface in front of the render eye.
    static func sourceFromDisplay(render: PCVREyeView, display: PCVREyeView,
                                  mode: PCVRReprojectionMode) -> simd_float3x3 {
        let cameraTransform: simd_float3x3
        switch mode {
        case .none:
            cameraTransform = matrix_identity_float3x3
        case .rotation:
            cameraTransform = renderFromDisplayRotation(render: render, display: display)
        case .rotationAndTranslation(let distance):
            cameraTransform = planeHomography(render: render, display: display, planeDistance: distance)
        }
        // NDC → forward tangent → camera space (-Z forward) → render camera → back.
        return render.fieldOfView.ndcFromTangent * flipZ * cameraTransform * flipZ * display.fieldOfView.tangentFromNDC
    }

    /// The proxy surface in display-eye space as `(n, d)` with `n · p = d` for
    /// points `p` on it. The presenter turns a display ray into a depth with it.
    static func displayPlane(render: PCVREyeView, display: PCVREyeView,
                             mode: PCVRReprojectionMode) -> SIMD4<Float> {
        guard case .rotationAndTranslation(let distance) = mode else {
            return SIMD4(0, 0, -1, rotationOnlyPresentationDepth)
        }
        let renderFromDisplay = render.pose.inverse * display.pose
        let renderNormal = SIMD3<Float>(0, 0, -1)
        let displayNormal = renderFromDisplay.rotation.inverse.act(renderNormal)
        return SIMD4(displayNormal, distance - simd_dot(renderNormal, renderFromDisplay.position))
    }

    /// Source NDC for a display NDC, or nil when the ray misses the proxy
    /// surface. What the shader does per pixel; here for tests and diagnostics.
    static func sourceNDC(forDisplayNDC ndc: SIMD2<Float>, through homography: simd_float3x3) -> SIMD2<Float>? {
        let mapped = homography * SIMD3(ndc, 1)
        guard mapped.z > 1e-6 else { return nil }
        return SIMD2(mapped.x, mapped.y) / mapped.z
    }

    // MARK: Camera-space transforms

    private static let flipZ = simd_float3x3(diagonal: SIMD3(1, 1, -1))

    /// Rotation taking display-eye directions into the render eye.
    private static func renderFromDisplayRotation(render: PCVREyeView, display: PCVREyeView) -> simd_float3x3 {
        simd_float3x3(render.pose.rotation.inverse * display.pose.rotation)
    }

    /// The plane-induced homography `H = R + t nᵀR / (D − n·t)` between camera
    /// spaces, for the plane `n · p = D` in render-eye space with `n = (0, 0, -1)`
    /// (fronto-parallel, D metres ahead). `R` rotates display into render, `t`
    /// is the display eye's origin in render space. Derivation: the display ray
    /// `t + s R p` meets the plane at `s = (D − n·t) / (n · R p)`; scaling that
    /// point by the (positive, for a hit in front) `(n · R p) / (D − n·t)` gives
    /// `H p`.
    private static func planeHomography(render: PCVREyeView, display: PCVREyeView,
                                        planeDistance: Float) -> simd_float3x3 {
        let renderFromDisplay = render.pose.inverse * display.pose
        let rotation = simd_float3x3(renderFromDisplay.rotation)
        let translation = renderFromDisplay.position
        let normal = SIMD3<Float>(0, 0, -1)
        let denominator = planeDistance - simd_dot(normal, translation)
        // The display eye on or past the plane: no sensible warp, fall back to rotation.
        guard denominator > 1e-3 else { return rotation }
        // nᵀR as a row, then the outer product t (nᵀR): column j is t · (nᵀR)_j.
        let normalRow = rotation.transpose * normal
        let outer = simd_float3x3(translation * normalRow.x, translation * normalRow.y, translation * normalRow.z)
        return rotation + outer * (1 / denominator)
    }
}
#endif
