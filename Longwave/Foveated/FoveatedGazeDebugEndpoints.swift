//  FoveatedGazeDebugEndpoints.swift
//
//  `pcvrGaze`: which gaze feed the PCVR session reads (see
//  `FoveatedConnectionManager.gazeFeed`) and its newest sample, so a feed can be
//  checked from the debug server without any UI.
//
//  Registered only when the debug server runs, like the tracker endpoints.
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import DebugTrace
import Foundation
#if os(visionOS) && !targetEnvironment(simulator)
import RAVEFoveatedGaze
import QuartzCore
import RAVEInput
#endif

enum FoveatedGazeDebugEndpoints {
    struct Reply: Encodable {
        var feed: String?
        var sequence: Int?
        var direction: [Float]?
        var distance: Float?
        var ageSeconds: Double?
        /// Since capture, on this headset's clock; absent when the feed gives no
        /// capture time (then the native PCVR uplink sends no gaze).
        var captureAgeSeconds: Double?
    }

    static func register() {
        DebugSurface.shared.register([
            .query("pcvrGaze",
                   "The PCVR session's gaze feed (a plug-in feed, or RAVE's gaze message channel) and its newest "
                   + "sample: direction in head space (-z ahead), focus distance, age since receipt and since capture "
                   + "(no capture age: the native uplink won't send it). Empty off the headset "
                   + "or with no session") { _ in
                #if os(visionOS) && !targetEnvironment(simulator)
                guard let manager = FoveatedConnectionManager.current else { return Reply() }
                let s = manager.gazeSample
                return Reply(feed: manager.gazeFeed?.name, sequence: s?.sequence,
                             direction: s.map { [$0.direction.x, $0.direction.y, $0.direction.z] },
                             distance: s?.distance, ageSeconds: s.map { Date().timeIntervalSince($0.receivedAt) },
                             captureAgeSeconds: s?.localCaptureTime.map { CACurrentMediaTime() - $0 })
                #else
                return Reply()
                #endif
            },
        ])
    }
}
#endif
