//
//  PCVRWebPanelsDriver.swift
//  Longwave
//
//  Runs the pinned web panels in the PCVR space, once a frame from a
//  `ClosureComponent`: makes and drops panels as the list in Settings changes, poses
//  each on its wrist (RAVEPanelHandMount) or in the view (RAVEPanelHeadLock), fades a
//  wrist panel while that palm is turned up (that is the palm HUD's gesture), and
//  pauses a page nobody can see. In touch and move modes it keeps both hands'
//  pinches from the game; a drag on a panel's grab bar or corner in move mode moves
//  or resizes it, and where it ends up is saved relative to its mount.
//
//  Gated behind FOVEATED_ENABLED.
//

#if FOVEATED_ENABLED
import RAVEInput
import RAVEPanel
import RealityKit
import SwiftUI

@MainActor
final class PCVRWebPanelsDriver {
    private struct Live {
        var config: PCVRWebPanelConfig
        let page: PCVRWebPanelPage
        let panel: RAVEPanel
        var hand: RAVEPanelHandMount
        var head: RAVEPanelHeadLock
        var dragging = false
    }

    private let store = PCVRWebPanelStore.shared
    private var live: [UUID: Live] = [:]
    /// Where the panels hang in the scene.
    let root = Entity()
    private var suppressing = false

    // MARK: - Per frame

    func update(deltaTime: TimeInterval, bridge: ControllerBridgeSender?) {
        sync()

        // Touch and move modes take both hands: the one wearing the panel holds still
        // while the other uses or drags it, and neither pinch belongs to the game.
        let takingInput = store.mode != .view
        if takingInput != suppressing, let bridge {
            for hand in [BridgeHand.left, .right] {
                bridge.setGestureSuppressed(takingInput, for: hand, reason: .webPanels)
            }
            suppressing = takingInput
        }

        let head = bridge?.headWorldTransform
        let viewer = head.map(RAVEPanelViewer.init(transform:))
        for id in live.keys {
            guard var item = live[id] else { continue }
            item.panel.showsChrome = store.mode == .move
            var shown: Float = item.panel.opacity > 0 ? 1 : 0
            if !item.dragging {
                switch item.config.mount {
                case .leftWrist, .rightWrist:
                    let hand: BridgeHand = item.config.mount == .leftWrist ? .left : .right
                    let palm = bridge?.palmPose(hand).map(RAVEPanelPalm.init)
                    if let pose = item.hand.update(palm: palm, viewer: viewer?.position, deltaTime: deltaTime) {
                        item.panel.setPose(position: pose.position, orientation: pose.orientation)
                    }
                    shown = item.hand.opacity
                case .view:
                    if let pose = item.head.update(head: head, deltaTime: deltaTime) {
                        item.panel.setPose(position: pose.position, orientation: pose.orientation)
                        shown = 1
                    } else {
                        shown = 0
                    }
                }
            }
            // See-through while playing; solid while you are using or moving it.
            item.panel.opacity = shown * (takingInput ? 1 : Float(item.config.opacity))
            item.panel.tick(viewer: viewer)
            let paused = !item.panel.isRunning || item.panel.opacity == 0
            if item.page.isPaused != paused { item.page.isPaused = paused }
            live[id] = item
        }
    }

    /// Panels for the enabled pages with an address; a changed address or mount
    /// rebuilds that panel, anything else is applied in place.
    private func sync() {
        let wanted = store.panels.filter { $0.enabled && $0.url != nil }
        let wantedIDs = Set(wanted.map(\.id))
        for (id, item) in live where !wantedIDs.contains(id) {
            item.panel.remove()
            live[id] = nil
        }
        for config in wanted {
            if let item = live[config.id] {
                if item.config.address != config.address || item.config.mount != config.mount {
                    item.panel.remove()
                    live[config.id] = nil
                } else {
                    if !item.dragging, abs(item.panel.size.x - config.widthMeters) > 1e-3 {
                        item.panel.setSize(SIMD2(config.widthMeters, item.panel.size.y))
                    }
                    // "Reset position" in Settings, or an offset saved elsewhere.
                    if !item.dragging, item.config.offset != config.offset {
                        let value = config.offset.flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
                        live[config.id]?.hand.offset = value ?? RAVEPanelHandMount.backOfWrist
                        live[config.id]?.head.offset = value ?? RAVEPanelHeadLock.lowerRight
                    }
                    live[config.id]?.config = config
                    continue
                }
            }
            live[config.id] = make(config)
        }
    }

    private func make(_ config: PCVRWebPanelConfig) -> Live {
        let page = PCVRWebPanelPage(config: config)
        let panel = RAVEPanel(name: "WebPanel", size: [config.widthMeters, config.widthMeters * 4 / 3],
                              chrome: [.grabBar, .resizeHandle]) { [store] in
            PCVRWebPanelView(page: page, store: store)
        }
        panel.widthRange = 0.1...0.8
        panel.fitHeightToContent = true
        panel.showsChrome = false
        panel.opacity = 0
        panel.isHosted = { [weak page] in page?.webView.window != nil }
        panel.add(to: root)
        var hand = RAVEPanelHandMount()
        var head = RAVEPanelHeadLock()
        if let offset = config.offset, offset.count == 3 {
            let value = SIMD3(offset[0], offset[1], offset[2])
            if config.mount == .view { head.offset = value } else { hand.offset = value }
        }
        return Live(config: config, page: page, panel: panel, hand: hand, head: head)
    }

    // MARK: - Moving by hand

    /// A drag on a panel's grab bar or corner, in move mode. Returns whether it was one.
    @discardableResult
    func drag(_ entity: Entity, translation: SIMD3<Float>, bridge: ControllerBridgeSender?) -> Bool {
        guard store.mode == .move,
              let (id, item) = live.first(where: { $0.value.panel.part(of: entity) != nil }),
              let part = item.panel.part(of: entity) else { return false }
        live[id]?.dragging = true
        let eye = bridge?.headWorldTransform.map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        item.panel.drag(part, translation: translation, viewer: eye)
        return true
    }

    /// Saves where a dragged panel ended up, relative to its wrist or the view.
    func endDrag(bridge: ControllerBridgeSender?) {
        for (id, item) in live where item.dragging {
            item.panel.endDrag()
            var config = item.config
            let position = item.panel.root.position(relativeTo: nil)
            switch config.mount {
            case .leftWrist, .rightWrist:
                let hand: BridgeHand = config.mount == .leftWrist ? .left : .right
                if let pose = bridge?.palmPose(hand),
                   let offset = RAVEPanelHandMount.offset(placing: position, on: RAVEPanelPalm(pose)) {
                    live[id]?.hand.offset = offset
                    config.offset = [offset.x, offset.y, offset.z]
                }
            case .view:
                if let head = bridge?.headWorldTransform {
                    let offset = RAVEPanelHeadLock.offset(placing: position, head: head)
                    live[id]?.head.offset = offset
                    config.offset = [offset.x, offset.y, offset.z]
                }
            }
            config.widthMeters = item.panel.size.x
            live[id]?.dragging = false
            live[id]?.config = config
            store.update(config)
        }
    }

    /// Leaving the space: back to view mode, and give both hands back to the game.
    func tearDown(bridge: ControllerBridgeSender?) {
        store.mode = .view
        if suppressing, let bridge {
            for hand in [BridgeHand.left, .right] {
                bridge.setGestureSuppressed(false, for: hand, reason: .webPanels)
            }
        }
        suppressing = false
    }
}
#endif
