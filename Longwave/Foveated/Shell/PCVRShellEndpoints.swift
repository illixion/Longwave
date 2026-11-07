//  PCVRShellEndpoints.swift
//
//  Debug-server control for Shell A (`PCVRShellSession`): open its
//  CompositorServices space against the PC's v3 host, tune the depth warp,
//  read what the render loop measured. Registered only when the debug server
//  runs.

#if FOVEATED_ENABLED && os(visionOS)
import DebugTrace
import Foundation
import RAVECompanion
import SwiftData
import SwiftUI

@MainActor
enum PCVRShellEndpoints {
    static func register() {
        DebugSurface.shared.register([
            .untyped("pcvrShell", kind: .query,
                     "Shell A, the PCVR v3 stream in a CompositorServices space: whether it is open, the render loop's "
                     + "measurements (display rate, frame age, GPU time, depth warps) and the v3 source's") { _ in
                guard let session = PCVRShellSession.current else {
                    throw DebugError.unavailable("no Shell A session", hint: "a FOVEATED_ENABLED visionOS build makes one at launch")
                }
                return report(session)
            },
            .untyped("pcvrShellControl", kind: .command,
                     "Open or close Shell A (a full immersive space, so the PCVR session must be disconnected first) "
                     + "against the PC's v3 host, and tune it. Opening needs the main window open.",
                     parameters: [
                        .string("action", "open | close | set", default: "set"),
                        .string("host", "PC address (default: the PCVR tab's saved address)", default: ""),
                        .integer("companion", "index into the paired Companions (default: the one at the PCVR address, else the first)",
                                 default: -1, range: -1...50),
                        .boolean("warp", "per-pixel reprojection by the stream's depth (default on); off reprojects on one plane"),
                        .integer("warpSteps", "the most depth-map texels a ray is marched (default 32)", default: 0, range: 0...256),
                        .number("warpStep", "the march's step in depth-map texels (default 2)", default: 0, range: 0...8),
                        .boolean("warpTint", "diagnostics: the pixels the warp fills in, in magenta (cyan: filled from the other eye)"),
                        .boolean("otherEye", "fill what an eye could not see from the frame's other eye (default on)"),
                        .number("planeDistance", "metres ahead a frame without depth is taken to lie (default 50)",
                                default: 0, range: 0...1000),
                        .boolean("predictsToLatency", "predict the uplink pose by the measured pipeline latency (default on)"),
                        .number("percentile", "which readiness latency the horizon takes, 0-1 (default 0.5)", default: -1, range: -1...1),
                     ]) { args in
                guard let session = PCVRShellSession.current else {
                    throw DebugError.unavailable("no Shell A session", hint: "a FOVEATED_ENABLED visionOS build makes one at launch")
                }
                var options = session.renderOptions
                if let warp = args.bool("warp") { options.depthWarp.isEnabled = warp }
                if let steps = args.int("warpSteps"), steps > 0 { options.depthWarp.maxSteps = steps }
                if let step = args.double("warpStep"), step > 0 { options.depthWarp.stepTexels = Float(step) }
                if let tint = args.bool("warpTint") { options.depthWarp.tintsFills = tint }
                if let other = args.bool("otherEye") { options.depthWarp.fillsFromOtherEye = other }
                if let plane = args.double("planeDistance"), plane > 0 { options.depthWarp.planeDistance = Float(plane) }
                if let predicts = args.bool("predictsToLatency") { options.predictsToLatency = predicts }
                if let percentile = args.double("percentile"), percentile >= 0 { options.readinessPercentile = percentile }
                if options != session.renderOptions { session.renderOptions = options }
                switch args.string("action") ?? "set" {
                case "open":
                    guard !session.isPresenting else { break }
                    if let manager = FoveatedConnectionManager.current, !manager.isDisconnected {
                        throw DebugError.unavailable("a PCVR session holds the immersive space",
                                                     hint: "disconnect it first (pcvrCarrier on=false, or the PCVR tab)")
                    }
                    guard let open = session.openSpace else {
                        throw DebugError.unavailable("Shell A's space can't be opened yet", hint: "open Longwave's main window, then retry")
                    }
                    session.v3Target = try makeTarget(host: args.string("host") ?? "", index: args.int("companion") ?? -1)
                    switch await open() {
                    case .opened: break
                    case .userCancelled: throw DebugError.unavailable("the space was not opened", hint: "retry")
                    case .error: throw DebugError.unavailable("the space could not be opened", hint: "close any other immersive space first")
                    @unknown default: throw DebugError.unavailable("the space could not be opened", hint: "retry")
                    }
                case "close":
                    await session.dismissSpace?()
                default:
                    break
                }
                return report(session)
            },
        ])
    }

    private static func report(_ session: PCVRShellSession) -> [String: Any] {
        let s = session.stats
        var stats: [String: Any] = [
            "configuration": s.configuration,
            "worldTracking": s.worldTracking,
            "displayRate": s.displayRate,
            "presentedNew": s.presentedNew,
            "repeated": s.repeated,
            "dropped": s.dropped,
            "predictionHorizonMs": s.predictionHorizon,
            "framesWithoutAnchor": s.framesWithoutAnchor,
            "depthWarps": s.depthWarps,
            "depthWarpsWithoutDepth": s.depthWarpsWithoutDepth,
        ]
        let optional: [String: Double?] = [
            "frameAgeMs": s.frameAge, "frameAgeMaxMs": s.frameAgeMax, "poseToPresentMs": s.poseToPresent,
            "arrivalToPresentMs": s.arrivalToPresent, "gpuTimeMs": s.gpuTime, "gpuTimeMaxMs": s.gpuTimeMax,
        ]
        for (key, value) in optional { if let value { stats[key] = value } }
        if let readiness = s.readiness { stats["readinessMs"] = readiness }
        let warp = session.renderOptions.depthWarp
        var body: [String: Any] = [
            "presenting": session.isPresenting,
            "stats": stats,
            "options": [
                "warp": warp.isEnabled, "warpSteps": warp.maxSteps, "warpStep": warp.stepTexels,
                "warpTint": warp.tintsFills, "otherEye": warp.fillsFromOtherEye, "planeDistance": warp.planeDistance,
                "predictsToLatency": session.renderOptions.predictsToLatency,
                "percentile": session.renderOptions.readinessPercentile,
            ] as [String: Any],
        ]
        if let v = session.v3Status {
            var v3: [String: Any] = [
                "state": v.state, "picture": v.picture, "framesDecoded": v.framesDecoded, "framesLost": v.framesLost,
                "decodeErrors": v.decodeErrors, "megabitsPerSecond": v.megabitsPerSecond,
                "posesPerSecond": v.posesPerSecond, "gazeNegotiated": v.gazeNegotiated, "foveated": v.foveated,
                "framesWithoutFoveation": v.framesWithoutFoveation, "depthNegotiated": v.depthNegotiated,
                "depthFramesDecoded": v.depthFramesDecoded, "depthFramesLost": v.depthFramesLost,
                "depthPicture": v.depthPicture,
            ]
            if let rtt = v.rttMilliseconds { v3["rttMs"] = rtt }
            if let decode = v.decodeMilliseconds { v3["decodeMs"] = decode }
            body["v3"] = v3
        }
        return body
    }

    /// The same choice the Shell A dev window makes: a Companion this headset
    /// holds a per-device credential for, at the PCVR tab's address.
    private static func makeTarget(host: String, index: Int) throws -> PCVRV3Target {
        let container = try ModelContainer(for: SavedConnection.self)
        let all = try ModelContext(container).fetch(FetchDescriptor<SavedConnection>())
        let companions = all.filter { $0.connectionType == .native && $0.companionCredential?.deviceID != nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let pcvrAddress = all.first { $0.connectionType == .foveated && !$0.hostname.isEmpty }?.hostname ?? ""
        let chosen = companions.indices.contains(index) ? companions[index] : nil
        guard let companion = chosen ?? companions.first(where: { !pcvrAddress.isEmpty && $0.hostname == pcvrAddress }) ?? companions.first,
              let credential = companion.companionCredential else {
            throw DebugError.unavailable("no paired Companion with a per-device credential",
                                         hint: "pair the headset with the PC's Companion (Connections → Native)")
        }
        let address = !host.isEmpty ? host : (!pcvrAddress.isEmpty ? pcvrAddress : companion.hostname)
        return PCVRV3Target(host: address, credential: credential, deviceName: DeviceName.current)
    }
}
#endif
