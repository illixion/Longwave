//
//  PCVRGuardianDriver.swift
//  Longwave
//
//  The room guardian in the PCVR space (RAVEGuardian): while a game covers the
//  view, the real walls light up as a grid where your head, a hand or a
//  controller gets close to one or heads for one fast. Settings are on the PCVR
//  tab (Guardian panel), on by default.
//
//  Longwave runs no scene reconstruction of its own, so the guardian's sensor
//  does: a second ARKit session with SceneReconstructionProvider and a
//  WorldTrackingProvider for the head. Hands and tracked controllers come from
//  the controller bridge, which already holds them in the same ARKit world;
//  without a bridge (it is off for this connection) the head still guards.
//  The guardian draws over the stream: RealityKit content here is depth-tested
//  against the game, and a game object nearer than the wall must not hide it.
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
    /// The package's messages carry their own privacy (ARKit error text private).
    private let sensor = RAVEGuardianWorldSensor(log: { message in
        DebugLogger(subsystem: "pro.longwave", category: "Guardian").notice(message)
    })
    private weak var manager: FoveatedConnectionManager?

    private init() {
        guardian.probeSource = { [weak self] in self?.probes() ?? [] }
    }

    func attach(to content: RealityViewContent, manager: FoveatedConnectionManager) {
        self.manager = manager
        guardian.root.removeFromParent()
        content.add(guardian.root)
        guardian.isActive = true
        sensor.start(feeding: guardian)
    }

    func detach() {
        guardian.isActive = false
        sensor.stop()
        // The sensor's next session re-delivers every anchor; keeping the old
        // map would leave walls from a room this headset may have left.
        guardian.removeAll()
        guardian.root.removeFromParent()
    }

    private func probes() -> [RAVEGuardianProbe] {
        var out: [RAVEGuardianProbe] = []
        let bridge = manager?.controllerBridge
        if let head = sensor.headProbe() {
            out.append(head)
        } else if let head = bridge?.headWorldPosition {
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
