//  PCVRSleeve.swift
//
//  The PCVR space's wrist HUD worn as a sleeve on the forearm (RAVE Engine's RAVESleeve,
//  drawn by RAVEPanel) instead of one big panel floated over the palm: a status line and
//  a few keys on the arm, and the whole readout (FoveatedHUDView) as a panel one of the
//  keys docks beside it. Every hand-anchored HUD in the portfolio is becoming a sleeve
//  (RAVEEngine's CLAUDE.md, "About `RAVESleeve`"); the palm panel it replaces
//  (`WristHUDDriver` in FoveatedImmersiveView) stays behind Settings' "Shown as".
//
//  **On the inner face, not the outer.** A sleeve shows a face while that side of the
//  forearm is turned to the eyes. The back of the forearm faces the eyes for most of a
//  VR game (hands held out, aiming, steering), so keys there would come and go all
//  session and take the hand's pinches from the game each time. The palm side is turned
//  to the face only on purpose, which is the old panel's summon gesture, so the keys
//  live there and nothing new has to be learned.
//
//  What only Longwave knows stays here, as it did for the palm panel: a hand that is
//  busy walking or steering may not show it, and while it shows, the worn hand's pinches
//  (and the other hand's, once its finger is at the arm) are kept from the game.
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import ARKit
import DebugTrace
import QuartzCore
import RAVEInput
import RAVEPanel
import RealityKit
import SwiftUI
import simd

@MainActor
final class PCVRSleeveDriver {
    static let styleKey = "foveatedWristHUDStyle"

    /// How the wrist HUD is shown.
    enum Style: String {
        /// Keys on the forearm, the full readout docked beside it.
        case sleeve
        /// The one panel over the palm (`WristHUDDriver`).
        case panel
    }

    enum Tile {
        static let status = "pcvr.status"
        static let controls = "pcvr.controls"
        static let desktop = "pcvr.desktop"
        static let hands = "pcvr.hands"
        static let details = "pcvr.details"
        static let quit = "pcvr.quit"
        static let webTouch = "pcvr.web.touch"
        static let webMove = "pcvr.web.move"
    }

    static let detailsDock = "pcvr.hud"
    /// Seconds Quit has to be held: it ends a running game, and a key answers to a
    /// glance and a pinch. The panel's button asks twice for the same reason.
    static let quitHold = 1.0

    static let layout = RAVESleeveLayout(
        inner: [
            RAVESleevePage("pcvr", rows: [
                [RAVESleeveTile(Tile.status, .label, span: 4)],
                [RAVESleeveTile(Tile.details, .dock(detailsDock), label: "Details", icon: "chart.xyaxis.line"),
                 RAVESleeveTile(Tile.controls, .button(RAVESleeveAction(Tile.controls)), label: "Controls",
                                icon: "slider.horizontal.3"),
                 RAVESleeveTile(Tile.desktop, .toggle(RAVESleeveAction(Tile.desktop)), label: "Desktop",
                                icon: "display"),
                 RAVESleeveTile(Tile.hands, .toggle(RAVESleeveAction(Tile.hands)), label: "Bare hands",
                                icon: "hand.raised")],
                [RAVESleeveTile(Tile.webTouch, .toggle(RAVESleeveAction(Tile.webTouch)), label: "Touch pages",
                                icon: "hand.tap"),
                 RAVESleeveTile(Tile.webMove, .toggle(RAVESleeveAction(Tile.webMove)), label: "Move pages",
                                icon: "arrow.up.and.down.and.arrow.left.and.right"),
                 RAVESleeveTile(Tile.quit, .hold(RAVESleeveAction(Tile.quit), seconds: quitHold),
                                label: "Quit title", icon: "xmark.circle.fill", role: .destructive, span: 2)],
            ]),
        ],
        // The readout is 380 pt wide at half scale, about 14 cm, and taller than wide.
        docks: [RAVESleeveDock(detailsDock, kind: "hud", title: "PCVR", width: 0.14, aspect: 0.55)])

    /// The driver that is in the space now, for the debug server.
    private(set) static weak var current: PCVRSleeveDriver?

    let wearer = RAVESleeveWearer(layout: PCVRSleeveDriver.layout)
    var root: Entity { wearer.root }
    /// The full readout, shown beside the arm while its dock is open.
    var details: RAVEPanel?
    /// Brings the PCVR controls window forward (the view has the environment for it).
    var openControls: () -> Void = {}

    private var suppressed: Set<BridgeHand> = []
    private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRSleeve")

    init() { Self.current = self }

    /// Once a frame. `hand` is the arm it is worn on.
    func update(hand: BridgeHand, enabled: Bool, bridge: ControllerBridgeSender?) {
        details?.tick(viewer: nil)
        guard enabled, let bridge, let head = bridge.headWorldPosition else {
            // Still stepped, so tiles that were showing fade rather than freeze.
            wearer.update(worn: nil, other: nil, head: .zero, showAllowed: false)
            hide(bridge: bridge)
            return
        }
        refreshTiles(bridge)

        let anchors = bridge.sleeveHandAnchors()
        let worn = hand == .left ? anchors?.left : anchors?.right
        let other = hand == .left ? anchors?.right : anchors?.left
        // A hand that is busy walking, turning or steering may not show it: a forearm
        // that turns to you mid-jog is not a request for the keys.
        let events = wearer.update(worn: worn, other: other, head: head, showAllowed: !bridge.isHandBusy(hand))
        for event in events { handle(event, bridge) }

        // The pinch that presses a key is also mapped to a controller button, so the
        // worn hand stops feeding the game while the keys are up, and the other hand
        // once its finger is at the arm.
        var want: Set<BridgeHand> = []
        if wearer.isVisible {
            want.insert(hand)
            if let tip = wearer.fingertip, let frame = wearer.snapshot?.frame,
               simd_distance(tip, frame.origin + frame.along * 0.08) < 0.15 {
                want.insert(hand == .left ? .right : .left)
            }
        }
        setSuppressed(want, bridge: bridge)

        let dock = wearer.isVisible ? wearer.snapshot?.docks.first { $0.dock.id == Self.detailsDock } : nil
        details?.follow(dock)
    }

    /// Drop the keys and, crucially, give the hands back to the game.
    func hide(bridge: ControllerBridgeSender?) {
        wearer.release()
        if details?.opacity != 0 { details?.opacity = 0 }
        setSuppressed([], bridge: bridge)
    }

    private func setSuppressed(_ want: Set<BridgeHand>, bridge: ControllerBridgeSender?) {
        guard want != suppressed else { return }
        guard let bridge else {
            // No bridge to tell; its own state went with it.
            suppressed = []
            return
        }
        for hand in suppressed.subtracting(want) { bridge.setGestureSuppressed(false, for: hand) }
        for hand in want.subtracting(suppressed) { bridge.setGestureSuppressed(true, for: hand) }
        suppressed = want
    }

    // MARK: Tiles

    private func refreshTiles(_ bridge: ControllerBridgeSender) {
        func set(_ id: String, _ state: RAVESleeveTileState) {
            if wearer.sleeve.states[id] != state { wearer.sleeve.states[id] = state }
        }
        set(Tile.status, statusLine(bridge))
        set(Tile.details, RAVESleeveTileState(isOn: wearer.sleeve.openDocks.contains(Self.detailsDock)))
        // Reflects the host, not the last press; nothing truthful to show before its
        // first telemetry.
        let desktop = bridge.desktopQuadShown
        set(Tile.desktop, RAVESleeveTileState(isOn: desktop == true, disabled: desktop == nil))
        let handsOnly = !bridge.emulatesControllers
        set(Tile.hands, RAVESleeveTileState(isOn: handsOnly, text: handsOnly ? "Bare hands" : "Controllers"))
        // Nothing submitting means nothing to close.
        set(Tile.quit, RAVESleeveTileState(disabled: bridge.activeGame == nil))
        let pages = PCVRWebPanelStore.shared
        set(Tile.webTouch, RAVESleeveTileState(isOn: pages.mode == .touch, hidden: !pages.hasEnabledPanels))
        set(Tile.webMove, RAVESleeveTileState(isOn: pages.mode == .move, hidden: !pages.hasEnabledPanels))
    }

    /// The headline the panel leads with: what is running and how it paces, or why
    /// there is nothing to say. Stale host data is said to be stale, as on the panel.
    private func statusLine(_ bridge: ControllerBridgeSender) -> RAVESleeveTileState {
        guard bridge.isRunning else { return RAVESleeveTileState(text: "Bridge not running", warn: true) }
        let now = CACurrentMediaTime()
        guard let perf = bridge.perf, bridge.perfReceivedAt > 0, now - bridge.perfReceivedAt < 1.5 else {
            return RAVESleeveTileState(text: bridge.perfReceivedAt > 0 ? "Host data stopped" : "Waiting for the host",
                                       warn: bridge.perfReceivedAt > 0)
        }
        var name = bridge.activeGame ?? "No title"
        if name.hasSuffix(".exe") { name = String(name.dropLast(4)) }
        if perf.flags.contains(.stalled) { return RAVESleeveTileState(text: "\(name) · host stalled", warn: true) }
        let rate = perf.clientFps > 0 ? String(format: " · %.0f fps", perf.clientFps) : ""
        return RAVESleeveTileState(text: name + rate)
    }

    private func handle(_ event: RAVESleeveEvent, _ bridge: ControllerBridgeSender) {
        let source = event.source.rawValue
        switch (event.tile, event.kind) {
        case (Tile.controls, .fired):
            log.info("Sleeve: controls window by \(source, privacy: .public)")
            openControls()
        case (Tile.desktop, .toggled(let on)):
            log.info("Sleeve: desktop \(on, privacy: .public) by \(source, privacy: .public)")
            bridge.setDesktopQuad(on)
        case (Tile.hands, .toggled(let handsOnly)):
            log.info("Sleeve: bare hands \(handsOnly, privacy: .public) by \(source, privacy: .public)")
            bridge.setEmulateControllers(!handsOnly)
        case (Tile.quit, .fired):
            log.notice("Sleeve: quit title by \(source, privacy: .public)")
            bridge.requestStopActiveClient()
        case (Tile.webTouch, .toggled(let on)):
            PCVRWebPanelStore.shared.mode = on ? .touch : .view
        case (Tile.webMove, .toggled(let on)):
            PCVRWebPanelStore.shared.mode = on ? .move : .view
        case (_, .dock(let id, let open)):
            log.info("Sleeve: dock \(id, privacy: .public) open \(open, privacy: .public)")
        default:
            break
        }
    }

    // MARK: Debug

    func status() -> [String: Any] {
        var out = wearer.status()
        out["suppressedHands"] = suppressed.map { $0 == .left ? "left" : "right" }.sorted()
        return out
    }
}

@MainActor
enum PCVRSleeveEndpoints {
    static func register() {
        let tiles = [PCVRSleeveDriver.Tile.details, PCVRSleeveDriver.Tile.controls, PCVRSleeveDriver.Tile.desktop,
                     PCVRSleeveDriver.Tile.hands, PCVRSleeveDriver.Tile.webTouch, PCVRSleeveDriver.Tile.webMove,
                     PCVRSleeveDriver.Tile.quit]
        DebugSurface.shared.register([
            .untyped("pcvrSleeve", kind: .query,
                     "The PCVR space's wrist HUD worn as keys on the forearm: whether it shows, where the arm comes "
                     + "from, how steadied it is, which hands' pinches it keeps from the game, the open docks, and "
                     + "each key's place and state. Empty outside the PCVR space.") { _ in
                PCVRSleeveDriver.current?.status() ?? [:]
            },
            .untyped("pcvrSleevePress", kind: .command,
                     "Presses a key of the forearm HUD as a pinch would, held `seconds` (default 0.05; pcvr.quit "
                     + "needs 1). The keys have to be showing: the inside of the worn forearm turned to the face.",
                     parameters: [
                        .string("tile", "which key", required: true, choices: tiles),
                        .number("seconds", "how long it is held, default 0.05"),
                     ]) { arguments in
                guard let driver = PCVRSleeveDriver.current, driver.wearer.isVisible else {
                    throw DebugError.failedPrecondition(
                        "the keys are hidden",
                        hint: "in the PCVR space, with Wrist HUD on and shown as keys, turn the inside of the worn forearm toward the face")
                }
                driver.wearer.press(try arguments.requireString("tile"),
                                    seconds: min(max(arguments.double("seconds") ?? 0.05, 0.01), 5))
                try? await Task.sleep(for: .milliseconds(250))
                return driver.status()
            },
        ])
    }
}
#endif
