//  TrackerOverlayDriver.swift
//
//  A wireframe on every tracked device, drawn where the PC's tracker hub says it is.
//
//  An alignment is judged by looking: the device is in your hand, the drawing is supposed to
//  be on it, and the two either coincide or they don't. The hub's poses arrive already in
//  ARKit world — the world this immersive scene lives in, the same assumption the joystick
//  overlay makes — so there is no transform here. A device whose tracking space is not
//  aligned has no place in that world, so it is not drawn at all (the Trackers panel lists it)
//  rather than drawn somewhere wrong.
//
//  Built once and re-posed, like the sent-skeleton markers: a pool of slots, one per possible
//  device, each holding an outline per device kind and showing one. Poses arrive at 30 Hz and
//  render at 90, so each slot eases toward the newest sample.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import QuartzCore
import RealityKit
import UIKit
import simd

@MainActor
final class TrackerOverlayDriver {
    /// Everything this draws hangs off here; the immersive view adds it to the scene.
    let root = Entity()

    /// How long the outline takes to cover about two thirds of a gap to the newest sample.
    /// Short enough that it does not trail a fast sweep visibly, long enough to hide 30 Hz.
    static let smoothingSeconds: Float = 0.035
    /// A device that has not reported for this long is hidden rather than left frozen.
    static let staleAfter: CFTimeInterval = 0.3
    /// A jump larger than this is a different place, not a sample to ease toward.
    static let snapDistance: Float = 0.5

    enum Look: Hashable { case bright, dim, target, targetAlt, local, localDim }

    /// Pure: what a device should look like. Tested.
    static func look(for device: ControllerBridgeTrackerDevice, isTarget: Bool, isLocal: Bool,
                     pulse: Bool) -> Look {
        if isTarget { return pulse ? .target : .targetAlt }
        let held = device.flags.contains(.held)
        if isLocal { return held ? .local : .localDim }
        return held ? .bright : .dim
    }

    private struct Slot {
        let root = Entity()
        let outlines: [ControllerBridgeTrackerDevice.Kind: Entity]
        let models: [ModelEntity]
        let labelRoot = Entity()
        var labelModel: ModelEntity?
        var labelText: String?
        var key: String?
        var kind: ControllerBridgeTrackerDevice.Kind?
        var look: Look?
        var position: SIMD3<Float> = .zero
        var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var lastSeen: CFTimeInterval = 0
    }

    private var slots: [Slot] = []
    private var materials: [Look: UnlitMaterial] = [:]
    private var labelMaterial = UnlitMaterial(color: .white)
    private var shown = true

    init() {
        buildMaterials()
        for _ in 0..<(ControllerBridgeProtocol.trackersMaxDevices + 2) {
            slots.append(makeSlot())
        }
        for slot in slots {
            root.addChild(slot.root)
            root.addChild(slot.labelRoot)
        }
        root.isEnabled = false
    }

    // MARK: Per frame

    func update(deltaTime: TimeInterval, hub: TrackerHubModel?,
                local: ControllerBridgeTrackedControllers?, head: SIMD3<Float>?) {
        let now = CACurrentMediaTime()
        guard let hub, hub.overlayWanted(now: now), let packet = hub.latest else {
            if shown { shown = false; root.isEnabled = false }
            return
        }
        if !shown { shown = true; root.isEnabled = true }

        // The hub's devices that can be drawn, then the headset's own.
        var wanted: [(device: ControllerBridgeTrackerDevice, isTarget: Bool, isLocal: Bool)] = []
        for (index, device) in packet.devices.enumerated()
        where device.isPlaced && device.isTracked && now - hub.receivedAt < Self.staleAfter {
            wanted.append((device, packet.alignPhase == .collecting && packet.alignDevice == index, false))
        }
        for device in TrackerHubModel.localDevices(from: local) {
            wanted.append((device, false, true))
        }

        let dt = Float(deltaTime)
        let alpha = 1 - exp(-dt / Self.smoothingSeconds)
        let pulse = Int(now * 3) % 2 == 0
        var used = Set<Int>()

        for entry in wanted {
            let key = entry.device.key
            var index = slots.firstIndex { $0.key == key }
            let isNew = index == nil
            if index == nil { index = slots.indices.first { slots[$0].key == nil } }
            guard let i = index else { continue }
            used.insert(i)
            var slot = slots[i]
            slot.key = key
            slot.lastSeen = now

            let target = entry.device.position
            let rotation = entry.device.orientation
            if isNew || simd_distance(slot.position, target) > Self.snapDistance {
                slot.position = target
                slot.orientation = rotation
            } else {
                slot.position += (target - slot.position) * alpha
                let aim = simd_dot(slot.orientation.vector, rotation.vector) < 0
                    ? simd_quatf(vector: -rotation.vector) : rotation
                slot.orientation = simd_normalize(simd_slerp(slot.orientation, aim, alpha))
            }
            slot.root.setPosition(slot.position, relativeTo: nil)
            slot.root.setOrientation(slot.orientation, relativeTo: nil)
            slot.root.isEnabled = true

            if slot.kind != entry.device.kind {
                for (kind, outline) in slot.outlines { outline.isEnabled = kind == entry.device.kind }
                slot.kind = entry.device.kind
            }
            let look = Self.look(for: entry.device, isTarget: entry.isTarget, isLocal: entry.isLocal,
                                 pulse: pulse)
            if slot.look != look, let material = materials[look] {
                for model in slot.models { model.model?.materials = [material] }
                slot.look = look
            }
            updateLabel(&slot, for: entry.device, isLocal: entry.isLocal, head: head)
            slots[i] = slot
        }

        for i in slots.indices where !used.contains(i) && slots[i].key != nil {
            slots[i].root.isEnabled = false
            slots[i].labelRoot.isEnabled = false
            slots[i].key = nil
            slots[i].kind = nil
            slots[i].look = nil
        }
    }

    // MARK: Label

    private func updateLabel(_ slot: inout Slot, for device: ControllerBridgeTrackerDevice,
                             isLocal: Bool, head: SIMD3<Float>?) {
        let role = TrackerRole(rawValue: device.role) ?? .none
        var text = TrackerNaming.name(for: device)
        if role != .none { text += " · \(role.label)" }
        if text != slot.labelText {
            slot.labelModel?.removeFromParent()
            let mesh = MeshResource.generateText(
                text, extrusionDepth: 0.0004, font: .systemFont(ofSize: 0.016),
                containerFrame: CGRect(x: -0.15, y: 0, width: 0.3, height: 0.03),
                alignment: .center, lineBreakMode: .byTruncatingTail)
            let model = ModelEntity(mesh: mesh, materials: [labelMaterial])
            slot.labelRoot.addChild(model)
            slot.labelModel = model
            slot.labelText = text
        }
        let at = slot.position + SIMD3(0, 0.12, 0)
        slot.labelRoot.isEnabled = true
        slot.labelRoot.setPosition(at, relativeTo: nil)
        if let head {
            // Text faces +Z, so the entity's +Z points at the viewer.
            slot.labelRoot.look(at: head, from: at, relativeTo: nil, forward: .positiveZ)
        }
    }

    // MARK: Construction

    private func buildMaterials() {
        func line(_ color: UIColor, _ opacity: Float) -> UnlitMaterial {
            var m = UnlitMaterial(color: color)
            m.blending = .transparent(opacity: .init(floatLiteral: opacity))
            m.triangleFillMode = .lines
            return m
        }
        materials = [
            .bright: line(.systemGreen, 0.95),
            .dim: line(.white, 0.45),
            .target: line(.systemOrange, 1.0),
            .targetAlt: line(.systemYellow, 0.7),
            .local: line(.systemCyan, 0.9),
            .localDim: line(.systemCyan, 0.4),
        ]
    }

    private func makeSlot() -> Slot {
        let material = materials[.dim]!
        var models: [ModelEntity] = []
        func wire(_ mesh: MeshResource) -> ModelEntity {
            let model = ModelEntity(mesh: mesh, materials: [material])
            models.append(model)
            return model
        }
        let alongZ = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])   // a cylinder's axis is Y

        // Touch controller: a handle with the tracking ring above and ahead of it.
        let touch = Entity()
        let touchHandle = wire(.generateCylinder(height: 0.11, radius: 0.017))
        touchHandle.orientation = alongZ
        touch.addChild(touchHandle)
        if let torus = Self.torus(major: 0.045, minor: 0.0045) {
            let ring = wire(torus)
            ring.position = [0, 0.03, -0.075]
            ring.orientation = simd_quatf(angle: -0.7, axis: [1, 0, 0])
            touch.addChild(ring)
        }

        // Wand: a handle with a flat disc head angled forward.
        let wand = Entity()
        let wandHandle = wire(.generateCylinder(height: 0.12, radius: 0.014))
        wandHandle.orientation = alongZ
        wand.addChild(wandHandle)
        let head = wire(.generateCylinder(height: 0.01, radius: 0.05))
        head.position = [0, 0.035, -0.085]
        head.orientation = simd_quatf(angle: -0.6, axis: [1, 0, 0])
        wand.addChild(head)

        // Puck.
        let tracker = Entity()
        tracker.addChild(wire(.generateCylinder(height: 0.04, radius: 0.0375)))

        // Anything else: a small sphere, so it is at least findable.
        let other = Entity()
        other.addChild(wire(.generateSphere(radius: 0.025)))

        let outlines: [ControllerBridgeTrackerDevice.Kind: Entity] = [
            .touch: touch, .wand: wand, .tracker: tracker, .other: other,
        ]

        // Axes at the pose origin, solid: red x, green y, blue z. Orientation errors show up
        // here before they do in the outline.
        let axes = Entity()
        for (axis, color) in [(SIMD3<Float>(1, 0, 0), UIColor.systemRed),
                              (SIMD3<Float>(0, 1, 0), UIColor.systemGreen),
                              (SIMD3<Float>(0, 0, 1), UIColor.systemBlue)] {
            let size = SIMD3<Float>(repeating: 0.003) + axis * 0.057
            let bar = ModelEntity(mesh: .generateBox(size: size), materials: [UnlitMaterial(color: color)])
            bar.position = axis * 0.03
            axes.addChild(bar)
        }

        let slot = Slot(outlines: outlines, models: models)
        for outline in outlines.values {
            outline.isEnabled = false
            slot.root.addChild(outline)
        }
        slot.root.addChild(axes)
        slot.root.isEnabled = false
        slot.labelRoot.isEnabled = false
        return slot
    }

    /// A ring (torus about +Y), because RealityKit has none. Tessellated coarsely: it is
    /// drawn as lines, and a fine mesh would be a dense mat of them.
    static func torus(major: Float, minor: Float, segments: Int = 24, sides: Int = 6) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for i in 0..<segments {
            let theta = 2 * Float.pi * Float(i) / Float(segments)
            for j in 0..<sides {
                let phi = 2 * Float.pi * Float(j) / Float(sides)
                let ring = major + minor * cos(phi)
                positions.append([ring * cos(theta), minor * sin(phi), ring * sin(theta)])
                normals.append([cos(phi) * cos(theta), sin(phi), cos(phi) * sin(theta)])
            }
        }
        var indices: [UInt32] = []
        for i in 0..<segments {
            for j in 0..<sides {
                let a = UInt32(i * sides + j)
                let b = UInt32(((i + 1) % segments) * sides + j)
                let c = UInt32(((i + 1) % segments) * sides + (j + 1) % sides)
                let d = UInt32(i * sides + (j + 1) % sides)
                indices += [a, b, c, a, c, d]
            }
        }
        var descriptor = MeshDescriptor(name: "TrackerRing")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }
}
#endif
