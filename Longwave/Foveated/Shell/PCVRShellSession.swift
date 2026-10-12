#if FOVEATED_ENABLED && os(visionOS)
import CompositorServices
import DebugTrace
import Observation
import os
import SwiftUI

/// Shell A: the pre-entitlement PCVR presenter. A plain full immersive space
/// with a CompositorServices layer, which needs no special entitlement, and
/// gives predicted head poses, per-eye Metal drawables and the system
/// compositor's late reprojection (NATIVE_V3_PROTOCOL.md §4.7, "Why now").
/// Separate from the CloudXR foveated-streaming space, which stays as it is.
///
/// The session owns one run per opened space: a frame mailbox the stream feeds,
/// a head-pose producer whose snapshots go up the uplink, and the render loop.
/// Each run gets its own, so a run that is still winding down can never take
/// frames meant for the next one. Until the v3 client exists, DEBUG builds
/// feed it from `PCVRFakeRemote`.
@Observable
final class PCVRShellSession {
    static let immersiveSpaceID = "pcvr-shell"

    private(set) var isPresenting = false
    private(set) var stats = PCVRShellStats()

    var renderOptions = PCVRShellRenderOptions() {
        didSet {
            let options = renderOptions
            renderer?.options.withLock { $0 = options }
        }
    }

    #if DEBUG
    var remoteSettings = PCVRFakeRemoteSettings() {
        didSet {
            let settings = remoteSettings
            fakeRemote?.settings.withLock { $0 = settings }
        }
    }
    private(set) var remoteCounts: (rendered: Int, stalled: Int) = (0, 0)
    @ObservationIgnored private var fakeRemote: PCVRFakeRemote?

    /// Starts the fake remote's frame numbering over, as a host reconnecting
    /// within one open space does.
    func restartFakeStream() {
        fakeRemote?.restartStream()
    }

    /// Bumps the space epoch as a recentre would, without moving the origin:
    /// exercises the epoch gate (a brief gap until new-epoch frames arrive).
    func simulateRecentre() {
        poseProducer?.bumpSpaceEpoch()
    }
    #endif

    @ObservationIgnored private var renderer: PCVRShellRenderer?
    @ObservationIgnored private var poseProducer: PCVRHeadPoseProducer?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRShell")

    /// Called by the space's `CompositorLayer` once its layer renderer exists.
    func start(layerRenderer: LayerRenderer) {
        stop()
        let mailbox = PCVRFrameMailbox()
        let poseProducer = PCVRHeadPoseProducer()
        let renderer: PCVRShellRenderer
        do {
            renderer = try PCVRShellRenderer(layerRenderer: layerRenderer, mailbox: mailbox, poseProducer: poseProducer)
        } catch {
            log.error("Shell A could not start: \(error, privacy: .public)")
            return
        }
        renderer.options.withLock { [renderOptions] in $0 = renderOptions }
        // Only this renderer's own end stops the session: a space reopened
        // quickly starts a new one before the old layer reports invalidation.
        // Captured strongly: the session lives as long as the app (scene
        // state), and the renderer lets go of this closure when its thread ends.
        let identity = ObjectIdentifier(renderer)
        renderer.onInvalidated = { [self] in
            Task { @MainActor in rendererDidInvalidate(identity) }
        }
        #if DEBUG
        do {
            let remote = try PCVRFakeRemote(device: layerRenderer.device, mailbox: mailbox)
            remote.settings.withLock { [remoteSettings] in $0 = remoteSettings }
            poseProducer.onSnapshot = { [remote] snapshot in remote.receive(snapshot) }
            remote.start()
            fakeRemote = remote
        } catch {
            log.error("Fake remote could not start: \(error, privacy: .public)")
        }
        #endif
        self.renderer = renderer
        self.poseProducer = poseProducer
        isPresenting = true
        renderer.start()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollStats()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        statsTask?.cancel()
        statsTask = nil
        #if DEBUG
        fakeRemote?.stop()
        fakeRemote = nil
        #endif
        renderer?.stop()
        renderer = nil
        poseProducer = nil
        isPresenting = false
    }

    private func rendererDidInvalidate(_ identity: ObjectIdentifier) {
        guard let renderer, ObjectIdentifier(renderer) == identity else { return }
        stop()
    }

    private func pollStats() {
        guard let renderer else { return }
        stats = renderer.stats.withLock { $0 }
        #if DEBUG
        if let fakeRemote { remoteCounts = fakeRemote.counts }
        #endif
    }
}

/// The space's content: one full-immersion CompositorServices layer.
struct PCVRShellContent: CompositorContent {
    let session: PCVRShellSession

    var body: some CompositorContent {
        CompositorLayer(configuration: PCVRShellLayerConfiguration()) { layerRenderer in
            session.start(layerRenderer: layerRenderer)
        }
        // Set on the layer content itself: the scene-level preference alone has
        // let the Home indicator come back after the first palm-up (Oneiros).
        .persistentSystemOverlays(.hidden)
    }
}

struct PCVRShellLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        PCVRShellRenderer.configure(capabilities: capabilities, configuration: &configuration)
    }
}
#endif
