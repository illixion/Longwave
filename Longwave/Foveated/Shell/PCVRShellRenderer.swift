#if FOVEATED_ENABLED && os(visionOS)
import RAVEGuardian
import StreamWire
import ARKit
import CompositorServices
import DebugTrace
import Foundation
import Metal
import QuartzCore
import os

/// What the presenter's render loop takes from the main actor each frame.
nonisolated struct PCVRShellRenderOptions: Equatable, Sendable {
    var receiver = PCVRReceiverOptions()
    /// Predict the uplink pose past the drawable by the measured pipeline
    /// latency (`PCVRHeadPoseProducer.predictionHorizon`) instead of sending the
    /// pose for the next drawable.
    var predictsToLatency = true
    /// The readiness latency the prediction horizon takes
    /// (`PCVRHeadPoseProducer.readinessPercentile`). A trade under Wi-Fi
    /// jitter (headset, 2026-11-08): at 0.9 the tail pinned the horizon at its
    /// 100 ms cap, and the eye's distance from the render pose, which the
    /// warp's uncovered strips grow with, grows with it; at 0.5 every frame
    /// later than the median is superseded by the next, a repeat and a skip
    /// (23% of frames at 60 Hz).
    var readinessPercentile = 0.5
    /// The longest prediction horizon (`PCVRHeadPoseProducer.maximumHorizon`), seconds.
    var maximumHorizon = PCVRHeadPoseProducer.maximumPredictionHorizon
    var depthWarp = PCVRShellDepthWarp()
}

/// Per-pixel reprojection by the stream's depth (`PCVRDepthWarper`), straight
/// into the drawable: each display pixel's ray, from the eye at the drawable's
/// presentation pose, is marched through the frame's depth map, and the hit's
/// depth goes to the compositor with the colour. Off, the receiver's
/// single-plane `PCVRReceiverOptions.mode` is used instead.
nonisolated struct PCVRShellDepthWarp: Equatable, Sendable {
    var isEnabled = true
    var maxSteps = 32
    var stepTexels: Float = 2
    /// Diagnostics: the pixels the warp fills in, in magenta (cyan where the
    /// other eye filled them).
    var tintsFills = false
    /// Fill what a view's own eye could not see from the frame's other eye.
    var fillsFromOtherEye = true
    /// Where the picture is taken to lie, metres ahead of the render eye, for a
    /// frame whose depth has not arrived (or a host that sends none).
    var planeDistance: Float = 50
    /// The quality tier to hold; nil lets the render loop pick one from its
    /// GPU time (`PCVRWarpBudget`). A tier only ever limits `maxSteps`,
    /// `stepTexels` and `fillsFromOtherEye` as set here. Held at full: the
    /// headset's GPU clock follows the load, so a display frame's GPU time
    /// stays near the budget whatever the tier (minimal 9.4 ms, full 8.8 ms,
    /// warp off 5.75 ms of 11.1, Cyberpunk, 2026-11-17), and the budget only
    /// ever walked the tier down to minimal, which drops the other-eye fill
    /// for nothing.
    var tier: PCVRWarpTier? = .full
    /// The share of the display period a display frame's GPU time may take
    /// before the tier is lowered (`PCVRWarpBudget.Configuration.share`).
    var budgetShare = PCVRWarpBudget.defaultShare
    /// Carry the game's own motion on in display frames that repeat a stream
    /// frame (`PCVRMotionShift`), from the motion the host sends with depth.
    var motionExtrapolation = true
    /// Show the HUD the host marked as head-locked where the head is now,
    /// instead of reprojecting it with the world (`PCVRDepthWarper.headLockedHud`).
    var headLockedHud = true
}

/// What the render loop measured, published a few times a second. Times in
/// milliseconds; nil until there is something to average.
nonisolated struct PCVRShellStats: Equatable, Sendable {
    /// Presented display frames per second, measured.
    var displayRate: Double = 0
    var presentedNew = 0
    var repeated = 0
    var dropped = 0
    /// Present time minus the display time the frame was rendered for: how much
    /// later than intended it is shown, which is what reprojection has to cover.
    var frameAge: Double?
    var frameAgeMax: Double?
    /// Present time minus when the frame's head pose was sampled: motion-to-photon
    /// for the streamed content, before the compositor's own late correction.
    var poseToPresent: Double?
    /// Present time minus the frame's arrival: time spent waiting for a display slot.
    var arrivalToPresent: Double?
    var predictionHorizon: Double = 0
    /// How long the playout holds every frame past its render display time
    /// (`PCVRPacedFrameQueue.holdBack`), ms: nonzero while frames come late.
    var playoutHoldBack: Double = 0
    /// Pose snapshot to the first drawable its frame could be shown in, ms:
    /// 10th, 50th and 90th percentile of the last 120 frames.
    var readiness: [Double]?
    var framesWithoutAnchor = 0
    /// Frames shown with the depth warp, and how many of those had no depth
    /// picture (warped at `PCVRShellDepthWarp.planeDistance`).
    var depthWarps = 0
    var depthWarpsWithoutDepth = 0
    /// Display frames moved on along the game's motion, of those that repeated
    /// a frame with motion, and the motion's mean length (render pixels a frame).
    var motionShifts = 0
    var motionMeanPixels: Double?
    /// GPU time of a display frame's command buffer, ms.
    var gpuTime: Double?
    var gpuTimeMax: Double?
    /// The depth warp's tier in force (pinned or picked by the budget).
    var warpTier = PCVRWarpTier.full
    /// The display period the loop observed (the shortest interval between
    /// two presentation times in the window) and the GPU time the budget
    /// allows of it, ms.
    var displayPeriod: Double?
    var warpBudget: Double?
    var worldTracking = "—"
    var configuration = "—"
}

/// Shell A's frame loop: a CompositorServices `LayerRenderer` in a full
/// immersive space, presenting the PCVR stream through `PCVRReceiver`.
///
/// Per display frame, on its own thread (never the main actor, whose hitches
/// would become dropped frames):
/// 1. wait for the frame's optimal input time, then take the drawable;
/// 2. query the device anchor for the drawable's predicted presentation time —
///    exactly once, because the drawable must be submitted with the anchor that
///    was drawn for (re-querying later yields a fresher pose that the system
///    compositor then over-corrects against);
/// 3. produce the uplink head-pose snapshot (`PCVRHeadPoseProducer`);
/// 4. take the newest stream frame (latest wins; none new means repeat the last),
///    reproject it to the anchor's eye poses (per pixel by the stream's depth,
///    `PCVRShellDepthWarp`, else on one plane), and submit with that anchor.
///
/// The system compositor then reprojects once more from the drawable's anchor
/// and depth to the true display pose. That residual is small because our
/// display pose was predicted for the same presentation time, and with the
/// depth warp the depth it reprojects by is the scene's own.
nonisolated final class PCVRShellRenderer: @unchecked Sendable {
    /// Called once on the render thread when the layer is invalidated (the space
    /// closed), and not after `stop()`.
    var onInvalidated: (@Sendable () -> Void)?

    let options = OSAllocatedUnfairLock(initialState: PCVRShellRenderOptions())
    let stats = OSAllocatedUnfairLock(initialState: PCVRShellStats())

    private let layerRenderer: LayerRenderer
    private let mailbox: PCVRFrameMailbox
    private let poseProducer: PCVRHeadPoseProducer
    private let commandQueue: any MTLCommandQueue
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRShell")
    /// Frames in flight on the GPU. Three lets the CPU prepare the next frame
    /// while the compositor still holds the previous one.
    private let inFlight = DispatchSemaphore(value: 3)
    private var receiver: PCVRReceiver?
    private var depthWarper: PCVRDepthWarper?
    /// The v3 source's depth pictures, when it asked for them. Set before `start()`.
    var depthStore: PCVRDepthStore?
    /// The room guardian's walls, drawn over the stream in every eye (its
    /// snapshot is published from the main actor; encoding it never waits).
    /// Set before `start()`.
    var guardian: RAVEGuardianMetalRenderer?
    /// GPU times of completed frames, seconds, drained into the stats window.
    private let gpuTimes = OSAllocatedUnfairLock(initialState: [Double]())
    private var depthWarps = 0
    private var depthWarpsWithoutDepth = 0
    private var motionShifts = 0
    private var motionPixels = 0.0
    /// The frame on screen and when it was first shown, for how far a repeat
    /// of it carries its motion on.
    private var firstShown: (frameNumber: UInt32, streamEpoch: UInt32, time: TimeInterval)?
    /// The warp's tier when none is pinned, stepped once per stats window.
    private var warpBudget = PCVRWarpBudget()
    /// `LayerRenderer.Clock` seconds minus `CACurrentMediaTime()`. ARKit takes
    /// the former; the receiver clock everything else stamps is the latter.
    private var clockOffset: TimeInterval = 0
    private var window = StatsWindow()
    private let isStopped = OSAllocatedUnfairLock(initialState: false)

    init(layerRenderer: LayerRenderer, mailbox: PCVRFrameMailbox, poseProducer: PCVRHeadPoseProducer) throws {
        guard let queue = layerRenderer.device.makeCommandQueue() else {
            throw PCVRReceiverError.resourceCreationFailed("command queue")
        }
        queue.label = "PCVR shell"
        self.layerRenderer = layerRenderer
        self.mailbox = mailbox
        self.poseProducer = poseProducer
        self.commandQueue = queue
        let configuration = layerRenderer.configuration
        stats.withLock {
            $0.configuration = "\(Self.describe(configuration.layout)), foveation \(configuration.isFoveationEnabled ? "on" : "off")"
        }
    }

    /// The layer's far plane, metres.
    static let farPlaneMetres: Float = 10_000

    /// Makes the layer's configuration: dedicated layout (one texture and one
    /// rasterization rate map per eye, which the receiver's per-view passes need
    /// to apply foveation correctly) with foveation when the device offers both.
    /// Anything else falls back to an unfoveated layout: a layered texture's
    /// single multi-layer rate map cannot be applied one slice at a time.
    static func configure(capabilities: LayerRenderer.Capabilities,
                          configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        // The compositor clips what lies past the far plane when it reprojects
        // (shown black), so push it past anything a stream draws; the depth
        // written is never beyond it (`PCVRDepthWarper`). Only the far plane:
        // it rejects near planes below its own minimum (Oneiros).
        configuration.defaultDepthRange.x = max(configuration.defaultDepthRange.x, Self.farPlaneMetres)
        let foveated = capabilities.supportsFoveation
            && capabilities.supportedLayouts(options: .foveationEnabled).contains(.dedicated)
        configuration.isFoveationEnabled = foveated
        let layouts = capabilities.supportedLayouts(options: [])
        if foveated || layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else if let layout = layouts.first {
            configuration.layout = layout
        }
    }

    /// Starts world tracking, then the render thread.
    func start() {
        Task.detached(priority: .userInitiated) { [self] in
            do {
                try await arSession.run([worldTracking])
            } catch {
                log.error("World tracking failed to start: \(error, privacy: .public)")
            }
            let thread = Thread { [self] in renderLoop() }
            thread.name = "PCVR shell render"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    /// Ends the loop without waiting for the layer to be invalidated: a space
    /// reopened quickly gets its new renderer before the old layer reports its
    /// end, and two loops must never run at once. The thread finishes its frame
    /// in flight, stops world tracking and exits. It is not joined, because it
    /// may be blocked in the compositor (a paused layer's `waitUntilRunning`),
    /// which the main actor must not wait on; nothing it still touches is
    /// shared with the next run (each run has its own mailbox and producer).
    func stop() {
        isStopped.withLock { $0 = true }
        // World tracking ends now, not when the loop next runs: a loop blocked in
        // a paused layer's `waitUntilRunning` would otherwise keep it going beside
        // the next session's. `ARKitSession` is Sendable, so this is safe from the
        // main actor while the render thread waits; a later query just returns no
        // anchor, and the loop's own `stop()` on exit is then a no-op.
        arSession.stop()
    }

    // MARK: Loop

    private func renderLoop() {
        defer { arSession.stop() }
        do {
            receiver = try PCVRReceiver(device: layerRenderer.device)
        } catch {
            log.error("PCVR receiver could not be created: \(error, privacy: .public)")
        }
        do {
            depthWarper = try PCVRDepthWarper(device: layerRenderer.device)
        } catch {
            log.error("PCVR depth warp could not be created: \(error, privacy: .public)")
        }
        clockOffset = LayerRenderer.Clock().now.pcvrSeconds - CACurrentMediaTime()
        log.notice("Shell A render loop started (\(self.stats.withLock { $0.configuration }, privacy: .public)); layer clock leads media time by \(self.clockOffset * 1000, format: .fixed(precision: 3)) ms")
        while true {
            if isStopped.withLock({ $0 }) {
                log.notice("Shell A render loop stopped")
                return
            }
            switch layerRenderer.state {
            case .invalidated:
                log.notice("Shell A layer invalidated")
                onInvalidated?()
                return
            case .paused:
                layerRenderer.waitUntilRunning()
                window = StatsWindow()
            default:
                autoreleasepool { renderFrame() }
            }
        }
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }
        // Wait for a GPU slot before the frame's update, as Apple's Compositor
        // Services template does, so the timing the frame predicts accounts for it.
        inFlight.wait()
        var committed = false
        defer { if !committed { inFlight.signal() } }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        // Drawables before `startSubmission`, the order of Apple's Compositor
        // Services templates (Xcode 27, Renderer.swift).
        let drawables = frame.queryDrawables()
        guard let primary = drawables.first else { return }

        frame.startSubmission()
        let options = self.options.withLock { $0 }
        poseProducer.readinessPercentile = options.readinessPercentile
        poseProducer.maximumHorizon = options.maximumHorizon
        let presentLayerTime = primary.frameTiming.presentationTime.pcvrSeconds
        let presentTime = presentLayerTime - clockOffset
        let tracking = worldTracking.state
        let anchor = tracking == .running ? worldTracking.queryDeviceAnchor(atTimestamp: presentLayerTime) : nil
        let head = anchor.map { PCVRPose($0.originFromAnchorTransform) }
        noteAnchor(anchor != nil, tracking: tracking)

        if let head, !primary.views.isEmpty {
            produceSnapshot(head: head, drawable: primary, presentLayerTime: presentLayerTime,
                            presentTime: presentTime, predictsToLatency: options.predictsToLatency)
        }
        // A frame is only placed in the world with a head pose to place it at:
        // without one it would be drawn head-locked, which in VR is worse than black.
        // And only a frame rendered in the display pose's space epoch: across a
        // recentre its pose names a different place.
        // A frame that arrived since the last drawable could at the earliest
        // be shown at this one.
        for arrival in mailbox.drainArrivals() {
            poseProducer.recordReadiness(poseSequence: arrival.poseSequence, readyDisplayTime: presentTime)
        }
        let period = (mailbox.pacing?.periodMs ?? 1000.0 / 90) / 1000
        let presented = head == nil ? nil
            : mailbox.takeForPresentation(spaceEpoch: poseProducer.spaceEpoch, now: CACurrentMediaTime(),
                                          until: presentTime + period / 2)
        if let presented, presented.isNew {
            let poseToPresent = poseProducer.recordPresentation(
                frameNumber: presented.frame.frameNumber,
                poseSequence: presented.frame.renderPose.poseSequence,
                presentTime: presentTime)
            window.addNewFrame(poseToPresent: poseToPresent,
                               arrivalToPresent: presentTime - presented.frame.arrivalTime)
        }
        window.addPresent(time: presentTime,
                          frameAge: presented.map { presentTime - $0.frame.renderPose.displayTime },
                          hasAnchor: anchor != nil)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            frame.endSubmission()
            return
        }
        commandBuffer.label = "PCVR shell frame"
        let warp = options.depthWarp
        let warper = warp.isEnabled ? depthWarper : nil
        // One depth picture for the frame, kept until the GPU is done with it.
        var depthEntry: PCVRDepthStore.Entry?
        if let warper, let presented {
            let march = (warp.tier ?? warpBudget.tier).limiting(
                PCVRWarpMarch(maxSteps: warp.maxSteps, stepTexels: warp.stepTexels, fillsFromOtherEye: warp.fillsFromOtherEye))
            warper.maxSteps = march.maxSteps
            warper.stepTexels = march.stepTexels
            warper.tintsFills = warp.tintsFills
            warper.headLockedHud = warp.headLockedHud
            warper.fillsFromOtherEye = march.fillsFromOtherEye
            depthEntry = depthStore?.depth(for: presented.frame.frameNumber)
            depthWarps += 1
            if depthEntry == nil { depthWarpsWithoutDepth += 1 }
        }
        // A repeat moves on along the frame's own motion, by the time since the
        // frame was first shown: only the motion with that frame's number, as
        // a neighbour's would move it by another frame's motion.
        var motion: PCVRMotionShift?
        if let presented {
            let frame = presented.frame
            if presented.isNew || firstShown?.frameNumber != frame.frameNumber || firstShown?.streamEpoch != frame.streamEpoch {
                firstShown = (frame.frameNumber, frame.streamEpoch, presentTime)
            } else if warp.motionExtrapolation, let entry = depthEntry, entry.frameNumber == frame.frameNumber,
                      let shift = PCVRMotionShift.forDisplay(map: entry.motion, sinceFirstShown: presentTime - (firstShown?.time ?? presentTime)) {
                motion = shift
                motionShifts += 1
                motionPixels += Double(shift.map.meanPixels)
            }
        }
        let capture = presented == nil ? nil : PCVRShellCapture.shared.next()
        if let capture, let presented {
            recordCaptureInput(capture, presented: presented.frame, isNew: presented.isNew, depth: depthEntry,
                               head: head, presentTime: presentTime, motion: motion != nil, warp: warp,
                               commandBuffer: commandBuffer)
        }
        for (drawableIndex, drawable) in drawables.enumerated() {
            drawable.deviceAnchor = anchor
            let targets = Self.targets(for: drawable, head: head ?? .identity)
            do {
                if let warper {
                    try warper.encode(frame: presented?.frame, depth: depthEntry?.map, views: targets,
                                      planeDistance: warp.planeDistance, motion: motion, commandBuffer: commandBuffer)
                } else if let receiver {
                    try receiver.encode(frame: presented?.frame, targets: targets,
                                        options: options.receiver, commandBuffer: commandBuffer)
                }
            } catch {
                log.error("Reprojection encode failed: \(error, privacy: .public)")
            }
            if let capture, drawableIndex == 0 {
                recordCaptureOutput(capture, drawable: drawable, targets: targets, commandBuffer: commandBuffer)
            }
            if let guardian, let anchor, guardian.hasContent {
                guardian.encode(commandBuffer: commandBuffer,
                                targets: Self.guardianTargets(for: drawable, originFromDevice: anchor.originFromAnchorTransform))
            }
            drawable.encodePresent(commandBuffer: commandBuffer)
        }
        // The frame's texture (and its depth picture) stay leased until the GPU
        // has finished sampling them.
        let sampled = presented?.frame
        commandBuffer.addCompletedHandler { [inFlight, gpuTimes] buffer in
            withExtendedLifetime((sampled, depthEntry)) {}
            capture?.complete()
            let time = buffer.gpuEndTime - buffer.gpuStartTime
            if time > 0 { gpuTimes.withLock { $0.append(time) } }
            inFlight.signal()
        }
        commandBuffer.commit()
        committed = true
        frame.endSubmission()
        publishStatsIfDue(now: presentTime, tracking: tracking, warp: warp)
    }

    private func produceSnapshot(head: PCVRPose, drawable: LayerRenderer.Drawable, presentLayerTime: TimeInterval,
                                 presentTime: TimeInterval, predictsToLatency: Bool) {
        let views = drawable.views
        // The simulator's drawable has one view; it stands in for both eyes so
        // the stream still has a stereo pair to render.
        let eyes = PCVRStereo(left: 0, right: min(1, views.count - 1)).map { index in
            PCVREyeGeometry(deviceFromEye: PCVRPose(views[index].transform),
                            fieldOfView: PCVRFieldOfView(projection: drawable.computeProjection(viewIndex: index)))
        }
        let horizon = predictsToLatency ? poseProducer.nextHorizon() : 0
        var predicted = head
        if horizon > 0, let ahead = worldTracking.queryDeviceAnchor(atTimestamp: presentLayerTime + horizon) {
            predicted = PCVRPose(ahead.originFromAnchorTransform)
        }
        poseProducer.makeSnapshot(head: predicted, eyes: eyes, sampledAt: CACurrentMediaTime(),
                                  baseDisplayTime: presentTime, displayTime: presentTime + horizon)
    }

    /// One receiver target per drawable view: the built-in display has two; a
    /// capture drawable may have one, which shows the left eye.
    private static func targets(for drawable: LayerRenderer.Drawable, head: PCVRPose) -> [PCVRReceiverTarget] {
        let rateMaps = drawable.rasterizationRateMaps
        return drawable.views.indices.map { index in
            let view = drawable.views[index]
            let map = view.textureMap
            let projection = drawable.computeProjection(viewIndex: index)
            return PCVRReceiverTarget(
                eye: min(index, 1),
                colorTexture: drawable.colorTextures[map.textureIndex],
                colorSlice: map.sliceIndex,
                depthTexture: drawable.depthTextures[map.textureIndex],
                depthSlice: map.sliceIndex,
                // CompositorServices uses reverse Z: 0 is the far plane.
                depthClearValue: 0,
                viewport: map.viewport,
                rasterizationRateMap: rateMaps.count == drawable.views.count ? rateMaps[index] : rateMaps.first,
                display: PCVREyeView(pose: head * PCVRPose(view.transform),
                                     fieldOfView: PCVRFieldOfView(projection: projection)),
                displayProjection: projection)
        }
    }

    /// The guardian's eye views: the same textures, slices, viewports and rate
    /// maps the stream was drawn into, with clip-from-world for each eye.
    private static func guardianTargets(for drawable: LayerRenderer.Drawable,
                                        originFromDevice: simd_float4x4) -> [RAVEGuardianMetalRenderer.Target] {
        let rateMaps = drawable.rasterizationRateMaps
        return drawable.views.indices.map { index in
            let view = drawable.views[index]
            let map = view.textureMap
            let originFromEye = originFromDevice * view.transform
            return RAVEGuardianMetalRenderer.Target(
                colorTexture: drawable.colorTextures[map.textureIndex],
                colorSlice: map.sliceIndex,
                viewport: map.viewport,
                rasterizationRateMap: rateMaps.count == drawable.views.count ? rateMaps[index] : rateMaps.first,
                viewProjection: drawable.computeProjection(viewIndex: index) * originFromEye.inverse)
        }
    }

    // MARK: Capture (`PCVRShellCapture`)

    private func recordCaptureInput(_ capture: PCVRShellCapture.Frame, presented frame: PCVRDecodedFrame, isNew: Bool,
                                    depth: PCVRDepthStore.Entry?, head: PCVRPose?, presentTime: TimeInterval,
                                    motion: Bool, warp: PCVRShellDepthWarp, commandBuffer: any MTLCommandBuffer) {
        var meta: [String: Any] = [
            "version": 1,
            "presentTime": presentTime,
            "isNew": isNew,
            "frameNumber": Int(frame.frameNumber),
            "streamEpoch": Int(frame.streamEpoch),
            "arrivalTime": frame.arrivalTime,
            "renderDisplayTime": frame.renderPose.displayTime,
            "poseSequence": Int(frame.renderPose.poseSequence),
            "renderEyes": [PCVRShellCapture.json(frame.renderPose.eyes[0]), PCVRShellCapture.json(frame.renderPose.eyes[1])],
            "motionShift": motion,
            "warp": ["enabled": warp.isEnabled, "maxSteps": warp.maxSteps, "stepTexels": Double(warp.stepTexels),
                     "otherEye": warp.fillsFromOtherEye, "hudLocked": warp.headLockedHud,
                     "planeDistance": Double(warp.planeDistance), "tier": (warp.tier ?? warpBudget.tier).name] as [String: Any],
        ]
        if let head { meta["head"] = PCVRShellCapture.json(head) }
        if let foveation = frame.foveation {
            meta["foveation"] = [
                "renderEye": [Int(foveation.renderEye.width), Int(foveation.renderEye.height)],
                "eyes": (0..<2).map { eye -> [String: Any] in
                    let c = foveation.constants(eye: eye)
                    return ["x": PCVRShellCapture.json(c.x), "y": PCVRShellCapture.json(c.y)]
                },
            ] as [String: Any]
        }
        let device = layerRenderer.device
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            capture.meta = meta
            return
        }
        blit.label = "PCVR capture input"
        if let section = PCVRShellCapture.copy(frame.texture, name: "stream.colour", blit: blit, device: device) {
            capture.sections.append(section)
        }
        if let depth {
            let map = depth.map
            meta["depth"] = ["frameNumber": Int(depth.frameNumber), "near": Double(map.near),
                             "far": map.far.isFinite ? Double(map.far) : -1, "valueScale": Double(map.valueScale),
                             "valueOffset": Double(map.valueOffset), "hasHud": map.hud != nil,
                             "hasMotion": depth.motion != nil] as [String: Any]
            if depth.values.count >= depth.width * depth.height, depth.width > 0 {
                capture.sections.append(.init(name: "depth.luma", format: "r8", width: depth.width, height: depth.height,
                                              bytesPerRow: depth.width, data: Data(depth.values.prefix(depth.width * depth.height))))
            } else if let section = PCVRShellCapture.copy(map.texture, name: "depth.luma", blit: blit, device: device) {
                capture.sections.append(section)
            }
            if let hud = map.hud, let section = PCVRShellCapture.copy(hud, name: "depth.chroma", blit: blit, device: device) {
                capture.sections.append(section)
            }
        }
        blit.endEncoding()
        capture.meta = meta
    }

    private func recordCaptureOutput(_ capture: PCVRShellCapture.Frame, drawable: LayerRenderer.Drawable,
                                     targets: [PCVRReceiverTarget], commandBuffer: any MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "PCVR capture output"
        let device = layerRenderer.device
        var views: [[String: Any]] = []
        for (index, target) in targets.enumerated() {
            let viewport = target.viewport
            // A rate-mapped view's viewport is in screen pixels; its texture holds
            // the physical (smaller) ones, so copy only what the texture has.
            let originX = target.rasterizationRateMap == nil ? Int(viewport.originX) : 0
            let originY = target.rasterizationRateMap == nil ? Int(viewport.originY) : 0
            let physical = target.rasterizationRateMap?.physicalSize(layer: 0)
            let width = min(physical?.width ?? Int(viewport.width), target.colorTexture.width - originX)
            let height = min(physical?.height ?? Int(viewport.height), target.colorTexture.height - originY)
            let region = MTLRegion(origin: MTLOrigin(x: originX, y: originY, z: 0),
                                   size: MTLSize(width: width, height: height, depth: 1))
            var view: [String: Any] = [
                "eye": target.eye,
                "display": PCVRShellCapture.json(target.display),
                "projection": PCVRShellCapture.json(target.displayProjection),
                "viewport": [viewport.originX, viewport.originY, viewport.width, viewport.height],
                "colourFramebufferOnly": target.colorTexture.isFramebufferOnly,
            ]
            if let section = PCVRShellCapture.copy(target.colorTexture, slice: target.colorSlice, name: "view\(index).colour",
                                                   region: region, blit: blit, device: device) {
                capture.sections.append(section)
            }
            if let depthTexture = target.depthTexture {
                view["depthFramebufferOnly"] = depthTexture.isFramebufferOnly
                if let section = PCVRShellCapture.copy(depthTexture, slice: target.depthSlice, name: "view\(index).depth",
                                                       region: region, blit: blit, device: device) {
                    capture.sections.append(section)
                }
            }
            if let map = target.rasterizationRateMap {
                view["screenSize"] = [map.screenSize.width, map.screenSize.height]
                capture.sections.append(contentsOf: PCVRShellCapture.rateMapSections(map, view: index))
            }
            views.append(view)
        }
        blit.endEncoding()
        capture.meta["views"] = views
    }

    // MARK: Diagnostics

    private var hasLoggedFirstAnchor = false
    private var consecutiveFramesWithoutAnchor = 0

    /// The first anchor, and a warning once tracking has given none for two
    /// seconds: without an anchor nothing is drawn, so a black space with no
    /// line here means the loop itself is not running.
    private func noteAnchor(_ present: Bool, tracking: DataProviderState) {
        if present {
            consecutiveFramesWithoutAnchor = 0
            guard !hasLoggedFirstAnchor else { return }
            hasLoggedFirstAnchor = true
            log.notice("Shell A has its first device anchor")
        } else {
            consecutiveFramesWithoutAnchor += 1
            if consecutiveFramesWithoutAnchor == 180 {
                log.error("Shell A: 180 frames without a device anchor (world tracking \(String(describing: tracking), privacy: .public)); drawing black")
            }
        }
    }

    // MARK: Stats

    private func publishStatsIfDue(now: TimeInterval, tracking: DataProviderState, warp: PCVRShellDepthWarp) {
        guard now - window.start >= 0.5 else { return }
        let counts = mailbox.counts
        let horizon = poseProducer.predictionHorizon
        let readiness = poseProducer.readinessQuantiles.map { [$0.low * 1000, $0.median * 1000, $0.high * 1000] }
        let snapshot = window
        let gpu = gpuTimes.withLock { times in
            defer { times.removeAll(keepingCapacity: true) }
            return times
        }
        let warps = depthWarps, withoutDepth = depthWarpsWithoutDepth
        let shifts = motionShifts, shiftPixels = motionPixels
        let gpuMean = gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count)
        // The budget steps on the window's mean GPU time against the period
        // the display ran at in it. A pinned tier, or the warp off, leaves it
        // be: the time measured is then not its tier's.
        let configuration = {
            var configuration = PCVRWarpBudget.Configuration()
            configuration.share = warp.budgetShare
            return configuration
        }()
        if warp.isEnabled, warp.tier == nil {
            let before = warpBudget.tier
            warpBudget = warpBudget.observing(gpuTime: gpuMean, period: snapshot.shortestInterval, configuration: configuration)
            if warpBudget.tier != before, let gpuMean, let period = snapshot.shortestInterval {
                log.notice("Depth warp tier \(before.name, privacy: .public) -> \(self.warpBudget.tier.name, privacy: .public): GPU \(gpuMean * 1000, format: .fixed(precision: 2)) ms of a \(period * 1000, format: .fixed(precision: 2)) ms period, budget \(PCVRWarpBudget.allowance(period: period, configuration: configuration) * 1000, format: .fixed(precision: 2)) ms")
            }
        }
        let tier = warp.tier ?? warpBudget.tier
        stats.withLock { stats in
            stats.gpuTime = gpuMean.map { $0 * 1000 }
            stats.gpuTimeMax = gpu.max().map { $0 * 1000 }
            stats.warpTier = tier
            stats.displayPeriod = snapshot.shortestInterval.map { $0 * 1000 }
            stats.warpBudget = snapshot.shortestInterval.map {
                PCVRWarpBudget.allowance(period: $0, configuration: configuration) * 1000
            }
            stats.depthWarps = warps
            stats.depthWarpsWithoutDepth = withoutDepth
            stats.motionShifts = shifts
            stats.motionMeanPixels = shifts > 0 ? shiftPixels / Double(shifts) : nil
            stats.displayRate = snapshot.presents > 1 ? Double(snapshot.presents - 1) / max(snapshot.lastPresent - snapshot.firstPresent, 1e-3) : 0
            stats.presentedNew = counts.presentedNew
            stats.repeated = counts.repeated
            stats.dropped = counts.dropped
            stats.frameAge = snapshot.frameAge.mean.map { $0 * 1000 }
            stats.frameAgeMax = snapshot.frameAge.maximum.map { $0 * 1000 }
            stats.poseToPresent = snapshot.poseToPresent.mean.map { $0 * 1000 }
            stats.arrivalToPresent = snapshot.arrivalToPresent.mean.map { $0 * 1000 }
            stats.predictionHorizon = horizon * 1000
            stats.playoutHoldBack = mailbox.pacing?.holdBackMs ?? 0
            stats.readiness = readiness
            stats.framesWithoutAnchor += snapshot.withoutAnchor
            stats.worldTracking = "\(tracking)"
        }
        window = StatsWindow(start: now)
    }

    /// Accumulates one publishing interval.
    private struct StatsWindow {
        struct Series {
            private(set) var sum: Double = 0
            private(set) var count = 0
            private(set) var maximum: Double?
            var mean: Double? { count > 0 ? sum / Double(count) : nil }
            mutating func add(_ value: Double?) {
                guard let value else { return }
                sum += value
                count += 1
                maximum = max(maximum ?? value, value)
            }
        }

        var start: TimeInterval = 0
        var presents = 0
        var firstPresent: TimeInterval = 0
        var lastPresent: TimeInterval = 0
        var withoutAnchor = 0
        /// The shortest interval between two presentation times: the display
        /// period, whatever rate visionOS chose. Not the mean, which a missed
        /// refresh stretches, just when the budget should not grow. Intervals
        /// under 4 ms (240 Hz) are a repeated timestamp, not a period.
        var shortestInterval: TimeInterval?
        var frameAge = Series()
        var poseToPresent = Series()
        var arrivalToPresent = Series()

        init(start: TimeInterval = 0) { self.start = start }

        mutating func addPresent(time: TimeInterval, frameAge age: TimeInterval?, hasAnchor: Bool) {
            if presents == 0 { firstPresent = time }
            if presents > 0, time - lastPresent >= 0.004 {
                shortestInterval = min(shortestInterval ?? .infinity, time - lastPresent)
            }
            if start == 0 { start = time }
            presents += 1
            lastPresent = time
            if !hasAnchor { withoutAnchor += 1 }
            frameAge.add(age)
        }

        mutating func addNewFrame(poseToPresent pose: TimeInterval?, arrivalToPresent arrival: TimeInterval) {
            poseToPresent.add(pose)
            arrivalToPresent.add(arrival)
        }
    }

    private static func describe(_ layout: LayerRenderer.Layout) -> String {
        switch layout {
        case .dedicated: "dedicated"
        case .shared: "shared"
        case .layered: "layered"
        @unknown default: "layout \(layout.rawValue)"
        }
    }
}

private extension LayerRenderer.Clock.Instant {
    /// Seconds since the clock's epoch: the timestamp `queryDeviceAnchor` takes.
    nonisolated var pcvrSeconds: TimeInterval {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
#endif
