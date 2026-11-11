//
//  PCVRGuardianDriver.swift
//  Longwave
//
//  The room guardian in the PCVR space (RAVEGuardian): while a game covers the
//  view, the real walls light up as a grid where your head, a hand or a
//  controller gets close to one or heads for one fast. Settings are on the PCVR
//  tab (Guardian panel), on by default.
//
//  It runs in both PCVR spaces, whichever is open (only one can be):
//  - the foveated-streaming space (CloudXR, and native sessions presented by
//    the system receiver): RealityKit, `RAVEGuardian` in its content;
//  - Shell A (native sessions presented by Longwave's own Compositor Services
//    renderer, low latency): no RealityKit there, so `RAVEGuardianOverlay`
//    decides what shows on the main actor and Shell A's render thread draws it
//    over the stream in each eye (`PCVRShellRenderer.guardian`).
//  Both read the same settings store.
//
//  Longwave runs no scene reconstruction of its own, so the guardian's sensor
//  does: a second ARKit session with SceneReconstructionProvider and a
//  WorldTrackingProvider for the head. Hands and tracked controllers come from
//  whichever controller bridge runs (the CloudXR manager's or the native
//  session's), which already holds them in the same ARKit world; without one
//  the head still guards. Both drawings go over the stream: a game object
//  nearer than the wall must not hide a safety outline.
//
//  One instance for the app: `FoveatedImmersiveView` is a struct rebuilt on
//  every state change, so a driver held by it would not be the one its
//  RealityView was built with.
//
//  Gated behind FOVEATED_ENABLED.
//

#if FOVEATED_ENABLED
import DebugTrace
import RAVEGuardian
import RealityKit
import SwiftUI
import simd

@MainActor
final class PCVRGuardianDriver {
    static let shared = PCVRGuardianDriver()

    let guardian = RAVEGuardian()
    /// Shell A's guardian.
    let overlay = RAVEGuardianOverlay()
    /// The native session, for its controller bridge. Set by the session.
    weak var nativeSession: PCVRNativeSession?
    /// A head used while world tracking gives none (the simulator), set from
    /// the debug server (`pcvrGuardianControl`).
    var standInHead: SIMD3<Float>?

    /// Which space draws the guardian, its map and last verdict (debug server).
    var status: (host: String, map: RAVEGuardianMap, frame: RAVEGuardianFrame) {
        if overlay.isRunning { return ("shell", overlay.world.map, overlay.lastFrame) }
        if guardian.isActive && guardian.root.parent != nil { return ("realityKit", guardian.map, guardian.lastFrame) }
        return ("none", guardian.map, guardian.lastFrame)
    }

    func headPosition() -> SIMD3<Float>? {
        sensor.headProbe()?.position ?? manager?.controllerBridge?.headWorldPosition ?? standInHead
    }

    /// Puts a stand-in room into whichever guardian runs (nil removes it).
    func setDemoRoom(_ walls: [RAVEGuardianTriangle]?, anchor: UUID) {
        for world in [guardian.world, overlay.world] {
            if let walls { world.setBarriers(walls, anchor: anchor) } else { world.remove(anchorID: anchor) }
        }
    }
    /// The package's messages carry their own privacy (ARKit error text private).
    private let sensor = RAVEGuardianWorldSensor(log: { message in
        DebugLogger(subsystem: "pro.longwave", category: "Guardian").notice(message)
    })
    private weak var manager: FoveatedConnectionManager?

    private init() {
        guardian.probeSource = { [weak self] in self?.probes() ?? [] }
        overlay.probeSource = { [weak self] in self?.probes() ?? [] }
    }

    /// The foveated-streaming space opened.
    func attach(to content: RealityViewContent, manager: FoveatedConnectionManager) {
        self.manager = manager
        detachShell()
        guardian.root.removeFromParent()
        content.add(guardian.root)
        guardian.isActive = true
        sensor.stop()
        sensor.start(feeding: guardian)
    }

    func detach() {
        guardian.isActive = false
        // The sensor's next session re-delivers every anchor; keeping the old
        // map would leave walls from a room this headset may have left.
        guardian.removeAll()
        guardian.root.removeFromParent()
        if !overlay.isRunning { sensor.stop() }
    }

    /// Shell A's space opened: start the overlay and hand its renderer to the
    /// render loop.
    func attachShell() -> RAVEGuardianMetalRenderer {
        if guardian.isActive { detach() }
        sensor.stop()
        overlay.removeAll()
        sensor.start(feeding: overlay)
        overlay.start()
        return overlay.renderer
    }

    func detachShell() {
        guard overlay.isRunning else { return }
        overlay.stop()
        overlay.removeAll()
        if !guardian.isActive { sensor.stop() }
    }

    private func probes() -> [RAVEGuardianProbe] {
        var out: [RAVEGuardianProbe] = []
        let bridge = manager?.controllerBridge ?? nativeSession?.controllerBridge
        if let head = sensor.headProbe() {
            out.append(head)
        } else if let head = bridge?.headWorldPosition ?? standInHead {
            out.append(.init(id: "head", kind: .head, position: head))
        }
        guard let bridge else { return out }

        let grips = bridge.gripPositions
        for (side, grip, joints) in [("left", grips.left, bridge.leftJoints),
                                     ("right", grips.right, bridge.rightJoints)] {
            guard let grip else { continue }
            out.append(.init(id: "hand.\(side).palm", kind: .hand, position: grip))
            // XR_EXT_hand_tracking order: 10 = index tip, 15 = middle tip.
            if let joints, joints.count >= 26 {
                out.append(.init(id: "hand.\(side).index", kind: .hand, position: joints[10].position))
                out.append(.init(id: "hand.\(side).middle", kind: .hand, position: joints[15].position))
            }
        }
        if let tracked = bridge.lastTrackedControllers {
            for (side, c) in [("left", tracked.left), ("right", tracked.right)]
            where c.flags.contains(.present) && c.flags.contains(.tracked) {
                out.append(.init(id: "controller.\(side)", kind: .controller, position: c.position))
            }
        }
        return out
    }
}
#endif
