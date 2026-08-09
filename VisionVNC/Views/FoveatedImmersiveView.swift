//  FoveatedImmersiveView.swift
//
//  RealityKit content layered into the foveated immersive space. The streamed
//  PCVR video itself is composited by the system (the `ImmersiveSpace(
//  foveatedStreaming:)` scene); this view adds the palm-summoned wrist HUD (see
//  FoveatedHUDView) and the optional hand-alignment overlay (see
//  FoveatedAlignmentDebugView).
//
//  A floating "Show Controls" button used to live here, carried over from Apple's
//  sample, for getting back to pause/disconnect once the control window was closed.
//  The wrist HUD does that on demand from the hand instead, so a button parked in
//  space in front of a game was pure clutter.
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI

#if !targetEnvironment(simulator)
import FoveatedStreaming
#endif
import RealityKit
import UIKit

struct FoveatedImmersiveView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @AppStorage("foveatedShowSentSkeleton") private var showSentSkeleton = false
    @AppStorage("foveatedWristHUD") private var wristHUDEnabled = true
    @AppStorage("foveatedWristHUDOnRight") private var wristHUDOnRight = false

    /// Debug marker root: one sphere per joint per hand, hidden unless the HUD asks
    /// for them. Built once and re-posed — 52 entities created per frame would be a
    /// worse frame-time bug than the one they exist to diagnose.
    private let skeletonRoot = Entity()
    private let wristEntity = Entity()
    private let wristDriver = WristHUDDriver()
    private let chargeEntity = Entity()

    var body: some View {
        RealityView { content in
            buildSkeletonMarkers()
            skeletonRoot.isEnabled = showSentSkeleton
            content.add(skeletonRoot)

            buildWristHUD(content: content)
            buildGestureCharge(content: content)
        }
        .onChange(of: showSentSkeleton, initial: true) { _, show in
            skeletonRoot.isEnabled = show
        }
        .onChange(of: wristHUDEnabled) { _, enabled in
            // Leaving a hand suppressed after the HUD is switched off would silently
            // disable its gestures in-game.
            if !enabled { wristDriver.hide(bridge: manager.controllerBridge) }
        }
        .onChange(of: wristHUDOnRight) { _, _ in
            wristDriver.hide(bridge: manager.controllerBridge)
        }
        .onDisappear {
            wristDriver.hide(bridge: manager.controllerBridge)
            Task { await manager.pauseForImmersiveExit() }
        }
        .task(id: showSentSkeleton) {
            guard showSentSkeleton else { return }
            // 45 Hz is plenty to judge alignment by eye and leaves the send loop alone.
            while !Task.isCancelled {
                updateSkeletonMarkers()
                try? await Task.sleep(for: .milliseconds(22))
            }
        }
    }

    // MARK: Wrist HUD

    /// Mounted like a watch: posed in world space from the palm each frame rather than
    /// parented to a hand anchor, so the lift and the billboard are ours to control (a
    /// palm anchor's local axes make "upright, facing the wearer" surprisingly awkward).
    /// Depth-tested against the streamed content, which is what makes it read as a
    /// hologram held over the hand rather than a label pasted on the display.
    private func buildWristHUD(content: RealityViewContent) {
        wristEntity.components.set(ViewAttachmentComponent(
            rootView: FoveatedHUDView().environment(manager)))
        // Attachments are sized points→metres: the 380 pt panel is ~0.28 m at scale 1,
        // so half that is about a hand's width.
        wristEntity.scale = .init(repeating: 0.5)
        wristEntity.isEnabled = false
        wristEntity.components.set(ClosureComponent { [weak wristEntity] deltaTime in
            guard let wristEntity else { return }
            wristDriver.update(entity: wristEntity,
                               deltaTime: deltaTime,
                               hand: wristHUDOnRight ? .right : .left,
                               enabled: wristHUDEnabled,
                               bridge: manager.controllerBridge)
        })
        content.add(wristEntity)
    }

    // MARK: Menu-gesture charge ring

    /// Sits at the thumb tip of the charging hand and billboards to the head. Unlike the
    /// wrist HUD this has no hysteresis or smoothing: it must appear on the frame the
    /// pinch is recognised and vanish on the frame it is released, or it would report a
    /// press that is no longer happening.
    private func buildGestureCharge(content: RealityViewContent) {
        chargeEntity.components.set(ViewAttachmentComponent(
            rootView: GestureChargeRoot(manager: manager)))
        // 72 pt ≈ 0.053 m at scale 1; a third of that reads as fingertip-sized.
        chargeEntity.scale = .init(repeating: 0.35)
        chargeEntity.isEnabled = false
        chargeEntity.components.set(ClosureComponent { [weak chargeEntity] _ in
            guard let chargeEntity else { return }
            // Freshness, not just presence: the charge is a published value, so a stalled
            // send loop would leave a ring hanging at whatever it last read.
            guard let bridge = manager.controllerBridge,
                  let charge = bridge.gestureCharge,
                  CACurrentMediaTime() - bridge.gestureChargeAt < 0.25,
                  let thumb = bridge.thumbTipWorld(charge.hand),
                  let head = bridge.headWorldPosition
            else {
                chargeEntity.isEnabled = false
                return
            }
            chargeEntity.isEnabled = true
            // Just off the thumb toward the viewer, so the ring is not buried in the hand.
            let toHead = head - thumb
            let length = simd_length(toHead)
            guard length > 1e-4 else { return }
            let z = toHead / length
            chargeEntity.setPosition(thumb + z * 0.04, relativeTo: nil)
            var x = simd_cross(SIMD3<Float>(0, 1, 0), z)
            let xLength = simd_length(x)
            guard xLength > 1e-4 else { return }
            x /= xLength
            chargeEntity.setOrientation(
                simd_quatf(simd_float3x3(x, simd_cross(z, x), z)), relativeTo: nil)
        })
        content.add(chargeEntity)
    }

    // MARK: Sent-skeleton overlay

    /// Left hand blue, right hand orange, so a mirrored-chirality bug is obvious at a
    /// glance rather than something to be inferred from finger geometry.
    private func buildSkeletonMarkers() {
        guard skeletonRoot.children.isEmpty else { return }
        let mesh = MeshResource.generateSphere(radius: 1)
        for hand in 0..<2 {
            var material = UnlitMaterial(
                color: hand == 0 ? UIColor.systemBlue : UIColor.systemOrange)
            material.blending = .transparent(opacity: 0.9)
            let handRoot = Entity()
            for _ in 0..<ControllerBridgeProtocol.handJointCount {
                handRoot.addChild(ModelEntity(mesh: mesh, materials: [material]))
            }
            skeletonRoot.addChild(handRoot)
        }
    }

    private func updateSkeletonMarkers() {
        guard let bridge = manager.controllerBridge, skeletonRoot.children.count == 2 else { return }
        for (hand, joints) in [(0, bridge.leftJoints), (1, bridge.rightJoints)] {
            let handRoot = skeletonRoot.children[hand]
            guard let joints, joints.count == handRoot.children.count else {
                handRoot.isEnabled = false
                continue
            }
            handRoot.isEnabled = true
            for (index, joint) in joints.enumerated() {
                let marker = handRoot.children[index]
                marker.position = joint.position
                marker.orientation = joint.orientation
                // Half the joint radius: visible next to the real finger, not covering it.
                marker.scale = .init(repeating: max(joint.radius, 0.004) * 0.5)
            }
        }
    }
}

/// Show/hide and placement state for the wrist HUD. A reference type because the
/// per-frame `ClosureComponent` needs somewhere durable to keep the hysteresis and the
/// smoothed pose, and the enclosing view is a struct rebuilt on every state change.
@MainActor
private final class WristHUDDriver {
    /// The palm must face you *squarely* — within about 18°. A wider cone triggered on
    /// ordinary hand movement.
    private static let engageFacing: Float = 0.95
    /// Held until well past the engage angle. This is a deadband, not a delay: without it
    /// the panel flickers while the hand sits near the threshold.
    private static let releaseFacing: Float = 0.70
    /// The only timing left. Both the engage dwell and the hold-open linger are gone — they
    /// made the panel feel like it was deciding whether to obey. The fade now begins on the
    /// frame the palm crosses the threshold, in either direction, so the response is
    /// immediate and only the animation takes time.
    private static let fade: TimeInterval = 0.22
    /// How far off the palm the panel floats, along the palm normal.
    private static let lift: Float = 0.18

    private var visible = false
    private var opacity: Float = 0
    private var suppressedHand: BridgeHand?

    func update(entity: Entity,
                deltaTime: TimeInterval,
                hand: BridgeHand,
                enabled: Bool,
                bridge: ControllerBridgeSender?) {
        guard enabled, let bridge else {
            hide(bridge: bridge)
            if entity.isEnabled { entity.isEnabled = false }
            return
        }

        // Threshold with hysteresis, evaluated fresh each frame: cross the engage angle and
        // it is coming in from this frame; drop below the release angle and it is going out
        // from this frame. Nothing waits.
        if let facing = bridge.palmFacing(hand) {
            if facing >= Self.engageFacing { visible = true }
            else if facing < Self.releaseFacing { visible = false }
        } else {
            // Hand lost. The fade covers a brief dropout on its own, so this needs no
            // grace period of its own.
            visible = false
        }

        // The pinch that presses a HUD button is also mapped to a controller button, so
        // the holding hand stops feeding the game while its panel is up.
        let wantSuppressed: BridgeHand? = visible ? hand : nil
        if wantSuppressed != suppressedHand {
            if let previous = suppressedHand { bridge.setGestureSuppressed(false, for: previous) }
            if let next = wantSuppressed { bridge.setGestureSuppressed(true, for: next) }
            suppressedHand = wantSuppressed
        }

        // Fade rather than switch. The entity stays enabled until it is fully transparent,
        // so the panel is never yanked out mid-look.
        let appearing = visible && opacity <= 0
        let step = Float(deltaTime / Self.fade)
        opacity = visible ? min(1, opacity + step) : max(0, opacity - step)
        entity.components.set(OpacityComponent(opacity: opacity))
        let shouldExist = opacity > 0
        if entity.isEnabled != shouldExist { entity.isEnabled = shouldExist }

        guard shouldExist,
              let palm = bridge.palmPose(hand),
              let head = bridge.headWorldPosition else { return }

        let target = palm.position + palm.normalOut * Self.lift
        // A basis with +Z toward the head (the direction a SwiftUI attachment faces) and
        // +Y world-up, so the panel stands upright facing the wearer however the hand is
        // rolled — rather than tumbling with the palm.
        let toHead = head - target
        let length = simd_length(toHead)
        guard length > 1e-4 else { return }
        let z = toHead / length
        var x = simd_cross(SIMD3<Float>(0, 1, 0), z)
        let xLength = simd_length(x)
        guard xLength > 1e-4 else { return }
        x /= xLength
        let orientation = simd_quatf(simd_float3x3(x, simd_cross(z, x), z))

        if appearing {
            // Snap, or it swoops in from wherever the hand was last time.
            entity.setPosition(target, relativeTo: nil)
            entity.setOrientation(orientation, relativeTo: nil)
        } else {
            // ~0.1 s time constant: enough to take hand tremor out of a panel the user
            // is about to aim their eyes at, without feeling detached from the hand.
            let alpha = 1 - exp(-10 * Float(deltaTime))
            let current = entity.position(relativeTo: nil)
            entity.setPosition(current + (target - current) * alpha, relativeTo: nil)
            entity.setOrientation(
                simd_slerp(entity.orientation(relativeTo: nil), orientation, alpha),
                relativeTo: nil)
        }
    }

    /// Drop the panel and, crucially, give the hand back to the game.
    func hide(bridge: ControllerBridgeSender?) {
        visible = false
        opacity = 0
        if let suppressedHand { bridge?.setGestureSuppressed(false, for: suppressedHand) }
        suppressedHand = nil
    }
}
#endif
