//
//  PCVRGuardianEndpoints.swift
//  Longwave
//
//  Debug-server control for the PCVR room guardian (`PCVRGuardianDriver`):
//  which space it draws in, how much room it has mapped, where each tracked
//  part stands against the nearest wall; settings, and a stand-in room and
//  head for the simulator (no scene mesh or world tracking there).
//
//  Gated behind FOVEATED_ENABLED.
//

#if FOVEATED_ENABLED && os(visionOS)
import DebugTrace
import Foundation
import RAVEGuardian
import simd

@MainActor
enum PCVRGuardianEndpoints {
    static let demoAnchor = UUID(uuidString: "6A7D0000-0000-4000-8000-0000000010A1")!

    static func register() {
        DebugSurface.shared.register([
            .untyped("pcvrGuardian", kind: .query,
                     "The PCVR room guardian: which space draws it (realityKit = the foveated-streaming space, shell = "
                     + "Shell A's Metal overlay, none), its settings, the mapped chunks and triangles, and per tracked "
                     + "part the clearance to the nearest wall (m), approach speed and acceleration, and 0-1 cue.") { _ in
                report()
            },
            .untyped("pcvrGuardianControl", kind: .command,
                     "Change the PCVR guardian. `enabled`, `style` grid|lines|solid, "
                     + "`warningDistance` metres. `demoRoom` puts a stand-in room of `width` x `depth` m around the debug reference "
                     + "(or the origin); `clearDemo` removes it. `headX/headY/headZ` set the simulator's stand-in debug reference; "
                     + "`clearHead` drops it. Returns GET /pcvrGuardian.",
                     parameters: [
                        .boolean("enabled", "the guardian runs"),
                        .string("style", "pattern", choices: RAVEGuardianSettings.Style.allCases.map(\.rawValue)),
                        .number("warningDistance", "safety margin, metres", range: 0.15...1.5),
                        .boolean("demoRoom", "load a stand-in room"),
                        .number("width", "stand-in room width (x), metres", range: 1...10),
                        .number("depth", "stand-in room depth (z), metres", range: 1...10),
                        .boolean("clearDemo", "remove the stand-in room"),
                        .number("headX", "stand-in head x, metres"),
                        .number("headY", "stand-in head y, metres"),
                        .number("headZ", "stand-in head z, metres"),
                        .boolean("clearHead", "drop the stand-in head"),
                     ]) { args in
                let driver = PCVRGuardianDriver.shared
                let store = RAVEGuardianSettingsStore.shared
                var s = store.settings
                if let v = args.bool("enabled") { s.isEnabled = v }
                if let v = args.string("style").flatMap(RAVEGuardianSettings.Style.init) { s.appearance.style = v }
                if let v = args.double("warningDistance") { s.warningDistance = Float(v) }
                store.settings = s.sanitized()
                if args.bool("clearHead") == true { driver.standInHead = nil }
                if ["headX", "headY", "headZ"].contains(where: args.has) {
                    let current = driver.standInHead ?? .zero
                    driver.standInHead = SIMD3(Float(args.double("headX") ?? Double(current.x)),
                                               Float(args.double("headY") ?? Double(current.y)),
                                               Float(args.double("headZ") ?? Double(current.z)))
                }
                if args.bool("clearDemo") == true { driver.setDemoRoom(nil, anchor: demoAnchor) }
                if args.bool("demoRoom") == true {
                    let head = driver.headPosition() ?? .zero
                    driver.setDemoRoom(RAVEGuardianDemoRoom.walls(
                        center: SIMD3(head.x, 0, head.z), width: Float(args.double("width") ?? 3),
                        depth: Float(args.double("depth") ?? 3), floorY: min(0, head.y - 1.6)), anchor: demoAnchor)
                }
                return report()
            },
        ])
    }

    private static func report() -> [String: Any] {
        let driver = PCVRGuardianDriver.shared
        let (host, map, frame) = driver.status
        func r(_ v: Float) -> Double { (Double(v) * 1000).rounded() / 1000 }
        let s = RAVEGuardianSettingsStore.shared.settings
        return [
            "host": host,
            "enabled": s.isEnabled,
            "style": s.appearance.style.rawValue,
            "warningDistance": r(s.warningDistance),
            "chunks": map.chunks.count,
            "triangles": map.triangleCount,
            "visibleChunks": frame.chunkOpacity.count,
            "peakAlert": r(frame.peakAlert),
            "standInHead": driver.standInHead.map { [r($0.x), r($0.y), r($0.z)] } as Any,
            "probes": frame.probes.map { p -> [String: Any] in
                ["id": p.probe.id, "clearance": p.clearance.map(r) as Any,
                 "approachSpeed": r(p.approachSpeed),
                 "approachAcceleration": r(p.approachAcceleration), "alert": r(p.alert)]
            },
        ]
    }
}
#endif
