//  JoystickVisualLayout.swift
//
//  Pure geometry for drawing RAVEEngine's renderer-neutral RAVEJoystickVisualization
//  (see RAVEEngine's RAVEHandJoystick.swift) as a disc + handle in RealityKit
//  (FoveatedImmersiveView). Split out from the RealityKit entity code so the
//  placement/sizing math — where the discs and the stick actually go — is
//  host-testable without a RealityKit runtime, the same reason RAVEInput itself
//  keeps its sensing math framework-free.
//
//  Every offset here is relative to RAVEJoystickVisualization.center: the caller
//  places its root entity at `center` in world space (the same ARKit tracking
//  space `thumbTipWorld`/`headWorldPosition` already treat as this scene's world
//  space in ControllerBridgeSender/FoveatedImmersiveView) and everything else is
//  a child offset, so this type never needs to know about world space at all.

#if FOVEATED_ENABLED
import RAVEInput
import simd

/// One frame's worth of layout for the joystick visualization's three drawable
/// pieces: the full-scale disc, the deadzone disc, and the handle + stick.
struct JoystickVisualLayout: Equatable {
    /// The stick joining center to handle: its midpoint offset, the rotation
    /// that points a unit +Y cylinder along it, and its length.
    struct Stick: Equatable {
        var midpoint: SIMD3<Float>
        var orientation: simd_quatf
        var length: Float
    }

    /// Diameter for the full-scale disc (2 × `fullScaleMeters`, floored so a
    /// misconfigured zero radius never collapses to an invisible disc).
    var fullScaleDiameter: Float
    /// Diameter for the deadzone disc, nil when the deadzone is too small to
    /// draw as anything but a flickering sliver.
    var deadzoneDiameter: Float?
    /// Handle position offset from center, always with y == 0.
    var handleOffset: SIMD3<Float>
    /// Nil while the handle sits within `minimumStickLength` of center, so a
    /// barely-engaged joystick doesn't draw a zero-length sliver either.
    var stick: Stick?

    /// Below this the deadzone disc would round-trip to an invisible sliver.
    static let minimumDeadzoneDiameter: Float = 0.004
    /// Below this the stick segment reads as a dot, not a segment.
    static let minimumStickLength: Float = 0.002

    init(_ visualization: RAVEJoystickVisualization) {
        let fullScale = max(visualization.fullScaleMeters, 0.01)
        fullScaleDiameter = fullScale * 2

        let deadzone = visualization.deadzoneMeters
        deadzoneDiameter = deadzone > Self.minimumDeadzoneDiameter ? deadzone * 2 : nil

        // Planar by RAVEPlanarBasis's own contract (forward/right are always
        // horizontal), but zeroed defensively rather than trusted blindly.
        let offset = visualization.handle - visualization.center
        let planar = SIMD3<Float>(offset.x, 0, offset.z)
        handleOffset = planar

        let length = simd_length(planar)
        if length > Self.minimumStickLength {
            let direction = planar / length
            // +Y and any horizontal direction are always exactly 90° apart, so
            // this rotation is never degenerate (no antiparallel case exists).
            let orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
            stick = Stick(midpoint: planar * 0.5, orientation: orientation, length: length)
        } else {
            stick = nil
        }
    }
}
#endif
