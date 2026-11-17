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
                     + "measurements (display rate, frame age, GPU time, depth warps, the warp's tier and GPU budget) and the v3 source's") { _ in
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
                        .boolean("hudLocked", "show the HUD the host marked as head-locked where the head is now, not "
                                 + "reprojected with the world (default on; needs a broker and host that mark it)"),
                        .boolean("motion", "carry the game's own motion on in display frames that repeat a stream frame, from the "
                                 + "motion the host sends with depth (default on; host --motion on)"),
                        .string("warpTier", "auto | full | reduced | minimal: hold the warp's quality tier (default full), or let "
                                + "the GPU budget pick it (auto). reduced: at most 20 steps of 3 texels; minimal: "
                                + "12 steps of 4 texels, no other-eye fill", default: ""),
                        .number("warpBudget", "the share of the display period a display frame's GPU time may take before "
                                + "the tier is lowered (default 0.8)", default: 0, range: 0...2),
                        .number("planeDistance", "metres ahead a frame without depth is taken to lie (default 50)",
                                default: 0, range: 0...1000),
                        .boolean("predictsToLatency", "predict the uplink pose by the measured pipeline latency (default on)"),
                        .number("percentile", "which readiness latency the horizon takes, 0-1 (default 0.5)", default: -1, range: -1...1),
                        .number("maxHorizonMs", "the longest prediction horizon, ms (default 100): a game several frames deep is "
                                + "ready later, and what the cap leaves over the reprojection bridges", default: 0, range: 0...300),
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
                if let motion = args.bool("motion") { options.depthWarp.motionExtrapolation = motion }
                if let locked = args.bool("hudLocked") { options.depthWarp.headLockedHud = locked }
                if let name = args.string("warpTier"), !name.isEmpty {
                    if name == "auto" {
                        options.depthWarp.tier = nil
                    } else if let tier = PCVRWarpTier(name: name) {
                        options.depthWarp.tier = tier
                    } else {
                        throw DebugError.invalidArgument("no warp tier named \(name)", hint: "auto, full, reduced or minimal")
                    }
                }
                if let share = args.double("warpBudget"), share > 0 { options.depthWarp.budgetShare = share }
                if let plane = args.double("planeDistance"), plane > 0 { options.depthWarp.planeDistance = Float(plane) }
                if let predicts = args.bool("predictsToLatency") { options.predictsToLatency = predicts }
                if let percentile = args.double("percentile"), percentile >= 0 { options.readinessPercentile = percentile }
                if let horizon = args.double("maxHorizonMs"), horizon > 0 { options.maximumHorizon = horizon / 1000 }
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
            .untyped("pcvrShellCapture", kind: .command,
                     "Diagnostics: record the next display frames of Shell A as the render loop saw them (the stream frame "
                     + "shown, its depth, poses and foveation, and the colour and depth the warp handed the compositor), "
                     + "for replay off the headset (scripts/pcvr-capture). Waits until they are recorded; fetch each "
                     + "with pcvrShellCaptureFrame. A capture holds about 80 MB a frame until the next one or clear.",
                     parameters: [
                        .integer("frames", "display frames to record (default 4)", default: 4, range: 1...12),
                        .integer("stride", "record every n-th display frame (default 1: consecutive)", default: 1, range: 1...90),
                        .boolean("clear", "drop the held capture and record nothing"),
                     ]) { args in
                let capture = PCVRShellCapture.shared
                if args.bool("clear") == true {
                    capture.clear()
                    return ["cleared": true]
                }
                guard let session = PCVRShellSession.current, session.isPresenting else {
                    throw DebugError.unavailable("Shell A is not presenting", hint: "open it with pcvrShellControl action=open")
                }
                let count = args.int("frames") ?? 4
                capture.request(count: count, stride: args.int("stride") ?? 1)
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    let frames = capture.frames
                    if capture.remaining == 0, frames.count == count, frames.allSatisfy(\.isComplete) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let frames = capture.frames
                return [
                    "recorded": frames.filter(\.isComplete).count,
                    "requested": count,
                    "frames": frames.enumerated().map { index, frame -> [String: Any] in
                        var row: [String: Any] = ["index": index, "complete": frame.isComplete,
                                                  "sections": frame.sections.map(\.name)]
                        for key in ["frameNumber", "isNew", "presentTime", "renderDisplayTime", "motionShift"] {
                            if let value = frame.meta[key] { row[key] = value }
                        }
                        if let depth = frame.meta["depth"] as? [String: Any] { row["depthFrameNumber"] = depth["frameNumber"] }
                        return row
                    },
                ]
            },
            .raw("pcvrShellCaptureFrame", kind: .query,
                 "One display frame of the last pcvrShellCapture as a binary blob (LWCAP1: JSON header, then raw "
                 + "sections; scripts/pcvr-capture/lwcap.py reads it). Holds the pictures shown in the headset.",
                 parameters: [.integer("index", "which recorded frame (default 0)", default: 0, range: 0...11)],
                 sensitivity: .screenCapture, timeout: .seconds(60)) { args in
                let frames = PCVRShellCapture.shared.frames
                let index = args.int("index") ?? 0
                guard frames.indices.contains(index), frames[index].isComplete else {
                    throw DebugError.unavailable("no recorded frame \(index)", hint: "run pcvrShellCapture first")
                }
                return .binary(frames[index].blob(), contentType: "application/octet-stream",
                               filename: "pcvr-capture-\(index).lwcap")
            },
            .untyped("pcvrLink", kind: .query,
                     "What the Wi-Fi link did to the v3 stream (Shell A's or the overlay's, whichever started last): "
                     + "gaps between datagrams (stalls of 30 ms and more listed), each frame's age from capture to its "
                     + "last shard on the host's clock (excess: above the window's lowest), RTT samples, NACKs",
                     parameters: [
                        .number("seconds", "how far back (default 10, at most 20)", default: 10, range: 0.1...20),
                        .boolean("rows", "one row per frame as well"),
                     ]) { args in
                guard let remote = PCVRV3Remote.latest else {
                    throw DebugError.unavailable("no v3 source has run", hint: "open Shell A or start the v3 overlay")
                }
                return remote.linkReport(seconds: args.double("seconds") ?? 10, rows: args.bool("rows") ?? false)
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
            "playoutHoldBackMs": s.playoutHoldBack,
            "framesWithoutAnchor": s.framesWithoutAnchor,
            "depthWarps": s.depthWarps,
            "depthWarpsWithoutDepth": s.depthWarpsWithoutDepth,
            "motionShifts": s.motionShifts,
            "warpTier": s.warpTier.name,
        ]
        let optional: [String: Double?] = [
            "frameAgeMs": s.frameAge, "frameAgeMaxMs": s.frameAgeMax, "poseToPresentMs": s.poseToPresent,
            "arrivalToPresentMs": s.arrivalToPresent, "gpuTimeMs": s.gpuTime, "gpuTimeMaxMs": s.gpuTimeMax,
            "displayPeriodMs": s.displayPeriod, "warpBudgetMs": s.warpBudget,
        ]
        for (key, value) in optional { if let value { stats[key] = value } }
        if let readiness = s.readiness { stats["readinessMs"] = readiness }
        if let pixels = s.motionMeanPixels { stats["motionMeanPixels"] = pixels }
        let warp = session.renderOptions.depthWarp
        var body: [String: Any] = [
            "presenting": session.isPresenting,
            "stats": stats,
            "options": [
                "warp": warp.isEnabled, "warpSteps": warp.maxSteps, "warpStep": warp.stepTexels,
                "warpTint": warp.tintsFills, "otherEye": warp.fillsFromOtherEye, "planeDistance": warp.planeDistance,
                "motion": warp.motionExtrapolation, "hudLocked": warp.headLockedHud,
                "warpTier": warp.tier?.name ?? "auto", "warpBudget": warp.budgetShare,
                "predictsToLatency": session.renderOptions.predictsToLatency,
                "percentile": session.renderOptions.readinessPercentile,
                "maxHorizonMs": session.renderOptions.maximumHorizon * 1000,
            ] as [String: Any],
        ]
        if let v = session.v3Status {
            var v3: [String: Any] = [
                "state": v.state, "picture": v.picture, "framesDecoded": v.framesDecoded, "framesLost": v.framesLost,
                "decodeErrors": v.decodeErrors, "megabitsPerSecond": v.megabitsPerSecond,
                "posesPerSecond": v.posesPerSecond, "gazeNegotiated": v.gazeNegotiated, "foveated": v.foveated,
                "framesWithoutFoveation": v.framesWithoutFoveation, "framesRescheduled": v.framesRescheduled, "depthNegotiated": v.depthNegotiated,
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
