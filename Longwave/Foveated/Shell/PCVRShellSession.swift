#if FOVEATED_ENABLED && os(visionOS)
import CompositorServices
import DebugTrace
import Observation
import os
import SwiftUI
import RAVEInput

/// Shell A: the pre-entitlement PCVR presenter. A plain full immersive space
/// with a CompositorServices layer, which needs no special entitlement, and
/// gives predicted head poses, per-eye Metal drawables and the system
/// compositor's late reprojection (NATIVE_V3_PROTOCOL.md §4.7, "Why now").
/// Separate from the CloudXR foveated-streaming space, which stays as it is.
///
/// The session owns one run per opened space: a frame mailbox the stream feeds,
/// a head-pose producer whose snapshots go up the uplink, and the render loop.
/// Each run gets its own, so a run that is still winding down can never take
/// frames meant for the next one. The frame source is the v3 client
/// (`PCVRV3Remote`) when `v3Target` is set when the space opens, else, in
/// DEBUG builds, `PCVRFakeRemote`.
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

    /// The PC to stream from when the space next opens; nil uses the fake
    /// remote (DEBUG) or nothing.
    var v3Target: PCVRV3Target?
    /// Set before starting a run to the official feed's `receiver.source`.
    /// This borrows readings; it never starts another immersive session.
    /// Nil (or a detached feed) keeps gaze invalid.
    @ObservationIgnored var gazeSource: (any RAVEGazeSource & Sendable)?
    private(set) var v3Status: PCVRV3Status?
    @ObservationIgnored private var v3Remote: PCVRV3Remote?

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

    /// The session the app's scene owns, for the debug endpoints.
    static weak var current: PCVRShellSession?

    /// Opens and dismisses the space; installed by a view in the main window
    /// (`pcvrShellSpaceControl()`), since only a view's environment can.
    @ObservationIgnored var openSpace: (@MainActor () async -> OpenImmersiveSpaceAction.Result)?
    @ObservationIgnored var dismissSpace: (@MainActor () async -> Void)?

    init() {
        Self.current = self
    }

    @ObservationIgnored private var renderer: PCVRShellRenderer?
    @ObservationIgnored private var poseProducer: PCVRHeadPoseProducer?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRShell")

    /// Called by the space's `CompositorLayer` once its layer renderer exists.
    func start(layerRenderer: LayerRenderer) {
        stop()
        // Each frame in the display slot it was rendered for: latest-wins
        // turned a source a few fps off the display rate into a repeat and a
        // skip every half second, a stutter in anything animated (headset,
        // 2026-11-08). The warp still shows every frame at the slot's own pose.
        let mailbox = PCVRFrameMailbox(playout: .timed)
        let poseProducer = PCVRHeadPoseProducer(gazeSource: gazeSource)
        // Held to their times, frames would raise a horizon measured from
        // presentation without end: it is measured from readiness instead.
        poseProducer.horizonSource = .readiness
        // The median, not the 90th percentile: under Wi-Fi jitter the tail
        // pinned the horizon at its 100 ms cap and frames waited 65 ms for
        // their slots (headset, 2026-11-08), and the eye's distance from the
        // render pose, which the warp's uncovered strips grow with, grows with
        // the horizon.
        poseProducer.readinessPercentile = renderOptions.readinessPercentile
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
        if let v3Target {
            do {
                if let remote = try PCVRV3Remote(device: layerRenderer.device, mailbox: mailbox, target: v3Target,
                                                  offersGaze: gazeSource != nil,
                                                  wantsDepth: renderOptions.depthWarp.isEnabled) {
                    renderer.depthStore = remote.depthStore
                    poseProducer.onSnapshot = { [remote] snapshot in remote.receive(snapshot) }
                    remote.start()
                    v3Remote = remote
                } else {
                    log.error("The v3 source has no per-device credential for this PC; pair the headset with its Companion")
                }
            } catch {
                log.error("The v3 source could not start: \(error, privacy: .public)")
            }
        }
        #if DEBUG
        if v3Remote == nil {
            do {
                let remote = try PCVRFakeRemote(device: layerRenderer.device, mailbox: mailbox)
                remote.settings.withLock { [remoteSettings] in $0 = remoteSettings }
                poseProducer.onSnapshot = { [remote] snapshot in remote.receive(snapshot) }
                remote.start()
                fakeRemote = remote
            } catch {
                log.error("Fake remote could not start: \(error, privacy: .public)")
            }
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
        v3Remote?.stop()
        v3Remote = nil
        v3Status = nil
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
        v3Status = v3Remote?.status.withLock { $0 }
        #if DEBUG
        if let fakeRemote { remoteCounts = fakeRemote.counts }
        #endif
    }
}

/// Lets the debug endpoints open and close Shell A's space: environment
/// actions exist only in a view, so the main window lends its own.
private struct PCVRShellSpaceControl: ViewModifier {
    let session: PCVRShellSession
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    func body(content: Content) -> some View {
        content.onAppear {
            session.openSpace = { [openImmersiveSpace] in
                await openImmersiveSpace(id: PCVRShellSession.immersiveSpaceID)
            }
            session.dismissSpace = { [dismissImmersiveSpace] in await dismissImmersiveSpace() }
        }
    }
}

extension View {
    func pcvrShellSpaceControl(_ session: PCVRShellSession) -> some View {
        modifier(PCVRShellSpaceControl(session: session))
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
