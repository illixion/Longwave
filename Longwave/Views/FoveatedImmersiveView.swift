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
import RAVEInput
import RAVEPanel
import SwiftUI

#if !targetEnvironment(simulator)
import FoveatedStreaming
#endif
import RealityKit
import UIKit

struct FoveatedImmersiveView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @Environment(PCVRSessionLimiter.self) private var limiter
    @Environment(PCVRBandwidthMonitor.self) private var bandwidthMonitor
    @AppStorage("foveatedShowSentSkeleton") private var sentSkeletonPreference = false
    /// The markers are a debugging aid whose toggles exist only in DEBUG builds, so
    /// a release build ignores a value a development install left behind.
    #if DEBUG
    private var showSentSkeleton: Bool { sentSkeletonPreference }
    #else
    private var showSentSkeleton: Bool { false }
    #endif
    @AppStorage("foveatedWristHUD") private var wristHUDEnabled = true
    @AppStorage("foveatedWristHUDOnRight") private var wristHUDOnRight = false

    /// Debug marker root: one sphere per joint per hand, hidden unless the HUD asks
    /// for them. Built once and re-posed — 52 entities created per frame would be a
    /// worse frame-time bug than the one they exist to diagnose.
    private let skeletonRoot = Entity()
    private let wristDriver = WristHUDDriver()
    private let chargeEntity = Entity()
    private let bannerDriver = ImmersiveBannerDriver()
    private let webPanels = PCVRWebPanelsDriver()
    private let joystickEntity = Entity()

    var body: some View {
        RealityView { content in
            buildSkeletonMarkers()
            skeletonRoot.isEnabled = showSentSkeleton
            content.add(skeletonRoot)

            buildWristHUD(content: content)
            buildGestureCharge(content: content)
            buildBanner(content: content)
            buildWebPanels(content: content)
            buildJoystickVisualization(content: content)
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
        // Move mode's grab bar and resize corner on the pinned web panels.
        .gesture(DragGesture().targetedToAnyEntity()
            .onChanged { value in
                webPanels.drag(value.entity,
                               translation: value.convert(value.translation3D, from: .local, to: .scene),
                               bridge: manager.controllerBridge)
            }
            .onEnded { _ in webPanels.endDrag(bridge: manager.controllerBridge) })
        .onDisappear {
            wristDriver.hide(bridge: manager.controllerBridge)
            webPanels.tearDown(bridge: manager.controllerBridge)
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
        let panel = RAVEPanel(name: "WristHUD", size: [0.14, 0.1]) {
            FoveatedHUDView().environment(manager).environment(limiter)
        }
        // Attachments are sized points→metres: the 380 pt panel is ~0.28 m at scale 1,
        // so half that is about a hand's width.
        panel.contentScale = 0.5
        panel.opacity = 0
        panel.root.components.set(ClosureComponent { [weak panel] _ in
            guard let panel else { return }
            wristDriver.update(panel: panel,
                               hand: wristHUDOnRight ? .right : .left,
                               enabled: wristHUDEnabled,
                               bridge: manager.controllerBridge)
        })
        wristDriver.panel = panel
        content.add(panel.root)
    }

    // MARK: Pinned web panels

    /// Pages pinned to a wrist or the view (PCVRWebPanels.swift). One entity holds
    /// them all; the driver makes and drops panels under it as Settings changes.
    private func buildWebPanels(content: RealityViewContent) {
        webPanels.root.components.set(ClosureComponent { deltaTime in
            webPanels.update(deltaTime: deltaTime, bridge: manager.controllerBridge)
        })
        content.add(webPanels.root)
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

    // MARK: Locomotion joystick visualization

    /// The wrist-delta locomotion joystick (`ControllerBridgeSender.applyGestures`)
    /// would otherwise have no on-screen presence: the player would have to learn the
    /// deadzone and full-scale radius by feel — and both now move with the per-title
    /// sensitivity. `RAVEJoystickVisualization`
    /// (see RAVEEngine's `RAVEHandJoystick.swift`) exists so every consumer can draw
    /// the same stick from renderer-neutral geometry — this is Longwave's.
    ///
    /// Three children, built once like `skeletonRoot`'s markers: a translucent
    /// full-scale disc, a brighter deadzone disc, and a handle sphere joined to the
    /// center by a thin stick — all flat, planar meshes generated at unit size and
    /// resized per frame via `.scale`, the same trick `buildSkeletonMarkers` uses for
    /// its joint spheres.
    private func buildJoystickVisualization(content: RealityViewContent) {
        // A plane with cornerRadius == half its side is a circle in the entity's own
        // XZ plane (`generatePlane(width:depth:cornerRadius:)` is documented to build
        // in the xz-plane) — no torus/ring mesh generator needed for either disc, and
        // no rotation either: `RAVEPlanarBasis.forward`/`.right` are horizontal by
        // construction, so `center` and `handle` already share one horizontal plane.
        let discMesh = MeshResource.generatePlane(width: 1, depth: 1, cornerRadius: 0.5)

        var fullScaleMaterial = UnlitMaterial(color: .white)
        fullScaleMaterial.blending = .transparent(opacity: 0.16)
        let fullScaleDisc = ModelEntity(mesh: discMesh, materials: [fullScaleMaterial])

        var deadzoneMaterial = UnlitMaterial(color: .white)
        deadzoneMaterial.blending = .transparent(opacity: 0.55)
        let deadzoneDisc = ModelEntity(mesh: discMesh, materials: [deadzoneMaterial])
        // Lifted a hair above the full-scale disc so the two coplanar circles never
        // z-fight.
        deadzoneDisc.position.y = 0.0006

        var stickMaterial = UnlitMaterial(color: .white)
        stickMaterial.blending = .transparent(opacity: 0.7)
        let stick = ModelEntity(
            mesh: .generateCylinder(height: 1, radius: 1), materials: [stickMaterial])
        stick.isEnabled = false

        let handle = ModelEntity(
            mesh: .generateSphere(radius: 1), materials: [UnlitMaterial(color: .systemGreen)])

        joystickEntity.addChild(fullScaleDisc)
        joystickEntity.addChild(deadzoneDisc)
        joystickEntity.addChild(stick)
        joystickEntity.addChild(handle)
        joystickEntity.isEnabled = false
        joystickEntity.components.set(ClosureComponent { [weak joystickEntity] _ in
            guard let joystickEntity else { return }
            self.updateJoystickVisualization(root: joystickEntity)
        })
        content.add(joystickEntity)
    }

    /// `RAVEJoystickVisualization.center`/`.handle` are in the same ARKit tracking
    /// space `thumbTipWorld`/`headWorldPosition` already treat as this scene's world
    /// space elsewhere in this file, so the root is placed directly at `center` with
    /// no basis rotation — only the handle/stick offsets need the per-frame geometry.
    private func updateJoystickVisualization(root: Entity) {
        guard let bridge = manager.controllerBridge,
              let vis = bridge.joystickVisualization,
              // Freshness, exactly like the gesture-charge ring above: a stalled send
              // loop must not leave a stick frozen mid-deflection.
              CACurrentMediaTime() - bridge.joystickVisualizationAt < 0.25
        else {
            if root.isEnabled { root.isEnabled = false }
            return
        }
        root.isEnabled = true
        root.setPosition(vis.center, relativeTo: nil)

        guard root.children.count == 4 else { return }
        let fullScaleDisc = root.children[0]
        let deadzoneDisc = root.children[1]
        let stick = root.children[2]
        let handle = root.children[3]

        // The actual placement/sizing math is a pure, host-testable type (see
        // JoystickVisualLayout.swift) — this is just handing its numbers to entities.
        let layout = JoystickVisualLayout(vis)
        fullScaleDisc.scale = .init(repeating: layout.fullScaleDiameter)

        if let deadzoneDiameter = layout.deadzoneDiameter {
            deadzoneDisc.isEnabled = true
            deadzoneDisc.scale = .init(repeating: deadzoneDiameter)
        } else {
            deadzoneDisc.isEnabled = false
        }

        handle.position = SIMD3(layout.handleOffset.x, 0.0012, layout.handleOffset.z)
        // A 1.2 cm handle reads as the primary, grabbable element against the ~1-4 cm
        // joint markers `buildSkeletonMarkers` draws at half their real joint radius.
        handle.scale = .init(repeating: 0.012)

        if let stickLayout = layout.stick {
            stick.isEnabled = true
            stick.position = SIMD3(stickLayout.midpoint.x, 0.0009, stickLayout.midpoint.z)
            stick.orientation = stickLayout.orientation
            stick.scale = SIMD3(0.006, stickLayout.length, 0.006)
        } else {
            stick.isEnabled = false
        }
    }

    // MARK: Banner

    /// The one thing here that appears without being asked for. Placed ahead of the
    /// viewer and eased toward that spot rather than pinned to the head — a panel
    /// rigidly locked to head motion is the standard way to make someone ill, and
    /// this one is on screen for twenty-five seconds at a stretch.
    ///
    /// One shared entity for both the trial countdown and the bandwidth cap notices
    /// — see `ImmersiveBannerRoot` for which one wins when more than one is active.
    /// The attachment is built once; `ImmersiveBannerRoot` is itself observing both
    /// `limiter` and `bandwidthMonitor`, so it re-renders its own content on its own
    /// as their state moves, the same way the trial-only version already did.
    private func buildBanner(content: RealityViewContent) {
        let panel = RAVEPanel(name: "ImmersiveBanner", size: [0.2, 0.05]) {
            ImmersiveBannerRoot(limiter: limiter, bandwidthMonitor: bandwidthMonitor)
        }
        // 460 pt ≈ 0.34 m at scale 1. Slightly under half reads as a notice at
        // arm's length rather than a wall.
        panel.contentScale = 0.45
        panel.opacity = 0
        panel.root.components.set(ClosureComponent { [weak panel] deltaTime in
            guard let panel else { return }
            let showing = limiter.bannerRemaining != nil || bandwidthMonitor.bannerKind != nil
            bannerDriver.update(panel: panel,
                                deltaTime: deltaTime,
                                showing: showing,
                                bridge: manager.controllerBridge)
        })
        content.add(panel.root)
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
///
/// Placing, following and fading are RAVEInput's `RAVEPalmAnchor` (the same one the
/// Metal hosts' wrist HUDs use), applied to a `RAVEPanel`. The show/hide gate stays
/// here, fed by the bridge's own palm-facing reading, as does what only Longwave
/// knows: which hand is busy, and giving that hand's gestures back to the game.
@MainActor
private final class WristHUDDriver {
    /// Show/hide is RAVEInput's `RAVEPalmFacingGate.panel`, which is this panel's own
    /// rule lifted into the shared package: plain palm facing (not the pitch-invariant
    /// metric, which widened the cone until almost any sideways hand summoned it), show
    /// at 0.95 — squarely, within about 18° — and hide only below 0.70, a deadband so the
    /// panel does not flicker at the threshold. No linger: a long hold-open made the
    /// panel feel like it was deciding whether to obey. What the preset adds is a 0.12 s
    /// dwell, because a hand swinging past the face on its way to something else crossed
    /// 0.95 for a frame or two and flashed the panel — and, worse, suppressed that hand's
    /// gestures in-game for as long as it was up.
    private var gate = RAVEPalmFacingGate.panel
    /// 18 cm off the palm along its normal; a ~0.1 s ease, enough to take hand tremor out
    /// of a panel the user is about to aim their eyes at without feeling detached from
    /// the hand; a 0.22 s fade either way once the gate has decided. It snaps into place
    /// on appearing, or it would swoop in from wherever the hand was last time.
    private var anchor = RAVEPalmAnchor(tuning: .init(lift: 0.18, smoothing: 0.1, fadeIn: 0.22, fadeOut: 0.22))

    weak var panel: RAVEPanel?
    private var suppressedHand: BridgeHand?

    func update(panel: RAVEPanel, hand: BridgeHand, enabled: Bool, bridge: ControllerBridgeSender?) {
        panel.tick(viewer: nil)
        guard enabled, let bridge else {
            hide(bridge: bridge)
            return
        }
        let now = CACurrentMediaTime()

        // A lost hand reads as nil, which the gate treats as a lapse; the fade covers a
        // brief dropout on its own. A hand that is busy walking, turning or steering may
        // not summon the panel: a palm that faces you mid-jog is not a request for it.
        let visible = gate.update(facing: bridge.palmFacing(hand), now: now,
                                  showAllowed: !bridge.isHandBusy(hand)).engaged

        // The pinch that presses a HUD button is also mapped to a controller button, so
        // the holding hand stops feeding the game while its panel is up.
        let wantSuppressed: BridgeHand? = visible ? hand : nil
        if wantSuppressed != suppressedHand {
            if let previous = suppressedHand { bridge.setGestureSuppressed(false, for: previous) }
            if let next = wantSuppressed { bridge.setGestureSuppressed(true, for: next) }
            suppressedHand = wantSuppressed
        }

        // Upright facing the head however the hand is rolled, rather than tumbling with
        // the palm. Without a head pose it stays where it was and fades there.
        anchor.update(pose: bridge.palmPose(hand), head: bridge.headWorldPosition ?? anchor.viewer,
                      now: now, shown: visible)
        panel.follow(anchor)
    }

    /// Drop the panel and, crucially, give the hand back to the game.
    func hide(bridge: ControllerBridgeSender?) {
        gate.reset()
        anchor.reset()
        panel?.opacity = 0
        if let suppressedHand { bridge?.setGestureSuppressed(false, for: suppressedHand) }
        suppressedHand = nil
    }
}

/// Placement for the shared immersive banner (trial countdown or bandwidth notice —
/// see `ImmersiveBannerRoot`). Same shape as `WristHUDDriver` — durable state for a
/// per-frame closure — but anchored to the head instead of a palm, and with a far
/// slower follow: this one has to be readable while the user is playing, and a
/// panel that tracks head motion tightly is unpleasant to sit inside. Nothing here
/// is specific to which banner is currently showing — `showing` is already a plain
/// `Bool` by the time it reaches this driver.
@MainActor
private final class ImmersiveBannerDriver {
    /// 1.5 m ahead: comfortably beyond arm's reach, so it never collides with hands
    /// that are busy holding something. 0.28 m below eye level: the centre of view
    /// belongs to the game. A ~1.2 s time constant: slow enough that turning your head
    /// does not drag it along, quick enough that it is back in front of you by the time
    /// you go looking for what the noise was.
    private var follow = RAVEPanelHeadFollow(distance: 1.5, drop: 0.28, smoothing: 1 / 0.85)
    private static let fade: TimeInterval = 0.35
    private var opacity: Float = 0

    func update(panel: RAVEPanel, deltaTime: TimeInterval, showing: Bool, bridge: ControllerBridgeSender?) {
        panel.tick(viewer: nil)
        let step = Float(deltaTime / Self.fade)
        opacity = showing ? min(1, opacity + step) : max(0, opacity - step)

        guard opacity > 0 else {
            if panel.opacity != 0 { panel.opacity = 0 }
            // Next time it materialises where the viewer is looking rather than sliding
            // in from wherever the last one closed.
            follow.reset()
            return
        }

        // No head pose (world tracking not up yet) means no sensible place to put it:
        // keep whatever pose it already had rather than dropping it on the origin.
        let viewer = bridge?.headWorldPose.map { RAVEPanelViewer(position: $0.position, forward: $0.forward) }
        guard let pose = follow.update(viewer: viewer, deltaTime: deltaTime) else { return }
        panel.follow(pose)
        panel.opacity = opacity
    }
}
#endif
