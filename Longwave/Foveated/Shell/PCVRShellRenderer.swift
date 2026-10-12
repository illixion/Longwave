#if FOVEATED_ENABLED && os(visionOS)
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
    var framesWithoutAnchor = 0
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
///    reproject it to the anchor's eye poses, and submit with that anchor.
///
/// The system compositor then reprojects once more from the drawable's anchor
/// and depth to the true display pose. That residual is small because our
/// display pose was predicted for the same presentation time.
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

    /// Makes the layer's configuration: dedicated layout (one texture and one
    /// rasterization rate map per eye, which the receiver's per-view passes need
    /// to apply foveation correctly) with foveation when the device offers both.
    /// Anything else falls back to an unfoveated layout: a layered texture's
    /// single multi-layer rate map cannot be applied one slice at a time.
    static func configure(capabilities: LayerRenderer.Capabilities,
                          configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
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
        let presented = head == nil ? nil : mailbox.takeForPresentation()
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
        for drawable in drawables {
            drawable.deviceAnchor = anchor
            if let receiver {
                let targets = Self.targets(for: drawable, head: head ?? .identity)
                do {
                    try receiver.encode(frame: presented?.frame, targets: targets,
                                        options: options.receiver, commandBuffer: commandBuffer)
                } catch {
                    log.error("Reprojection encode failed: \(error, privacy: .public)")
                }
            }
            drawable.encodePresent(commandBuffer: commandBuffer)
        }
        // The frame's texture stays leased until the GPU has finished sampling it.
        let sampled = presented?.frame
        commandBuffer.addCompletedHandler { [inFlight] _ in
            withExtendedLifetime(sampled) {}
            inFlight.signal()
        }
        commandBuffer.commit()
        committed = true
        frame.endSubmission()
        publishStatsIfDue(now: presentTime, tracking: tracking)
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
        let horizon = predictsToLatency ? poseProducer.predictionHorizon : 0
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

    private func publishStatsIfDue(now: TimeInterval, tracking: DataProviderState) {
        guard now - window.start >= 0.5 else { return }
        let counts = mailbox.counts
        let horizon = poseProducer.predictionHorizon
        let snapshot = window
        stats.withLock { stats in
            stats.displayRate = snapshot.presents > 1 ? Double(snapshot.presents - 1) / max(snapshot.lastPresent - snapshot.firstPresent, 1e-3) : 0
            stats.presentedNew = counts.presentedNew
            stats.repeated = counts.repeated
            stats.dropped = counts.dropped
            stats.frameAge = snapshot.frameAge.mean.map { $0 * 1000 }
            stats.frameAgeMax = snapshot.frameAge.maximum.map { $0 * 1000 }
            stats.poseToPresent = snapshot.poseToPresent.mean.map { $0 * 1000 }
            stats.arrivalToPresent = snapshot.arrivalToPresent.mean.map { $0 * 1000 }
            stats.predictionHorizon = horizon * 1000
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
        var frameAge = Series()
        var poseToPresent = Series()
        var arrivalToPresent = Series()

        init(start: TimeInterval = 0) { self.start = start }

        mutating func addPresent(time: TimeInterval, frameAge age: TimeInterval?, hasAnchor: Bool) {
            if presents == 0 { firstPresent = time }
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
