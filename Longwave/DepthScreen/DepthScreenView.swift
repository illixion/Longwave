#if os(visionOS)
import QuartzCore
import RealityKit
import SwiftUI

/// One depth screen: the feed frames arrive through, the renderer that draws
/// them, and the knobs. What a host window holds to show a stream in 3D: it
/// submits decoded pictures and depth frames to `feed` and puts a
/// `DepthScreenView` on screen.
@MainActor
@Observable
final class DepthScreenController {
    let feed = DepthScreenFeed()
    @ObservationIgnored let renderer = DepthScreenRenderer()

    var settings: DepthScreenSettings {
        get { renderer.settings }
        set { renderer.settings = newValue; stats = renderer.stats }
    }

    /// Refreshed at most a few times a second; the renderer's own numbers
    /// change every frame, and observing those would redraw SwiftUI as often.
    private(set) var stats = DepthScreenStats()
    @ObservationIgnored private var lastStatsPublish: CFTimeInterval = 0

    /// For a new source: drops held frames and the renderer's fade, so
    /// nothing of the previous source's depth is drawn under the new one.
    func reset() {
        feed.reset()
        renderer.stop()
    }

    init() {
        feed.onFrame = { [weak self] frame in self?.renderer.show(frame) }
        renderer.onStats = { [weak self] stats in
            guard let self else { return }
            let now = CACurrentMediaTime()
            guard now - self.lastStatsPublish > 0.25 || stats.source != self.stats.source else { return }
            self.lastStatsPublish = now
            self.stats = stats
        }
    }
}

/// The depth screen in a RealityView, `width` metres across with its window
/// plane (zero relief) at the content's origin. Relief reaches up to
/// `settings.strength × width` behind that plane, so the host scene must leave
/// room for it: a volumetric window today. A plain window clips whatever
/// lies behind its plane, which is the open question for hosting this in the
/// Native stream window.
struct DepthScreenView: View {
    let controller: DepthScreenController
    let width: Float
    /// Turns the screen about its vertical axis, so a fixed viewpoint (the
    /// simulator, a screenshot) can see the relief from the side.
    var yawDegrees: Float = 0

    var body: some View {
        RealityView { content in
            content.add(controller.renderer.entity)
        } update: { _ in
            controller.renderer.screenWidth = width
            controller.renderer.entity.orientation = simd_quatf(angle: yawDegrees * .pi / 180, axis: [0, 1, 0])
        }
        .onDisappear {
            controller.renderer.stop()
        }
    }
}
#endif
