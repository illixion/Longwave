//  ClosureComponent.swift
//
//  Per-frame update logic attached to a RealityKit entity. The pattern is from Apple's
//  "Creating a 3D Painting Space" sample, and is the right tool when an entity's pose
//  depends on something that changes faster than SwiftUI state should (hand tracking):
//  a `.task` loop re-poses on its own clock and visibly lags the render, while this runs
//  in the frame it affects and is handed the actual delta time to smooth against.
//
//  Ported from the Spatialcraft project.

import Foundation
import RealityKit

struct ClosureComponent: Component {
    let closure: (TimeInterval) -> Void

    init(closure: @escaping (TimeInterval) -> Void) {
        self.closure = closure
        ClosureSystem.registerSystem()
    }
}

/// Drives every entity carrying a `ClosureComponent`.
struct ClosureSystem: System {
    static let query = EntityQuery(where: .has(ClosureComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let component = entity.components[ClosureComponent.self] else { continue }
            component.closure(context.deltaTime)
        }
    }
}
