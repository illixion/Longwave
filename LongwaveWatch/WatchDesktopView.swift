import SwiftUI
import WatchKit

/// View-only desktop: drag pans, the Digital Crown zooms. Both move the
/// picture already on screen at once and then ask the Mac for a sharp still of
/// the new region, so they stay responsive over a slow link.
struct WatchDesktopView: View {
    let host: WatchHostStore.Host

    @State private var desktop = WatchDesktop()
    @State private var zoom = 1.0
    /// Centre of the view, in 0…1 fractions of the Mac's display.
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var dragStart: CGPoint?
    /// The crown only drives a focused view, and nothing else here takes focus.
    @FocusState private var crownFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let region = region(in: size)
            let fit = fitRect(for: region, in: size)
            ZStack {
                Color.black
                if let image = desktop.image {
                    let frame = imageFrame(shown: desktop.imageRegion, wanted: region, fit: fit)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                overlay
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let start = dragStart ?? center
                        dragStart = start
                        guard fit.width > 0, fit.height > 0 else { return }
                        center = clamp(CGPoint(
                            x: start.x - value.translation.width / fit.width * region.width,
                            y: start.y - value.translation.height / fit.height * region.height
                        ), region: region)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onChange(of: region, initial: true) { _, region in
                desktop.request(viewport(for: region, fit: fit))
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation(
            $zoom, from: 1, through: 8, by: 0.05,
            sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
        )
        .onChange(of: zoom) { center = clamp(center, region: regionSize) }
        .onAppear {
            crownFocused = true
            desktop.start(host: host)
        }
        .onDisappear { desktop.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Wrist down: stop polling rather than keep the radio busy.
            if phase == .active { desktop.start(host: host) } else { desktop.stop() }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch desktop.state {
        case .connecting where desktop.image == nil:
            ProgressView()
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Button("Retry") { desktop.start(host: host) }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        default:
            EmptyView()
        }
    }

    // MARK: Geometry

    /// Fractions of the display the view shows, before centring. At zoom 1 the
    /// whole display (letterboxed); zooming in narrows the width first, then
    /// the height once it fills the watch.
    private var regionSize: CGSize {
        let width = 1 / zoom
        let viewAspect = Self.screenAspect
        return CGSize(width: width, height: min(1, width * desktop.displayAspect / viewAspect))
    }

    private func region(in size: CGSize) -> WatchLinkProtocol.Viewport {
        let regionSize = regionSize
        let origin = CGPoint(
            x: min(max(0, center.x - regionSize.width / 2), 1 - regionSize.width),
            y: min(max(0, center.y - regionSize.height / 2), 1 - regionSize.height)
        )
        return WatchLinkProtocol.Viewport(
            x: Self.rounded(origin.x), y: Self.rounded(origin.y),
            width: Self.rounded(regionSize.width), height: Self.rounded(regionSize.height)
        )
    }

    /// Where the region lands in the view: aspect-fit, centred.
    private func fitRect(for region: WatchLinkProtocol.Viewport, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let aspect = region.width * desktop.displayAspect / region.height
        var fit = CGSize(width: size.width, height: size.width / aspect)
        if fit.height > size.height { fit = CGSize(width: size.height * aspect, height: size.height) }
        return CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height)
    }

    /// The current picture, which shows `shown`, placed as if the view were
    /// already showing `wanted` — the instant part of a pan or zoom.
    private func imageFrame(shown: WatchLinkProtocol.Viewport, wanted: WatchLinkProtocol.Viewport, fit: CGRect) -> CGRect {
        let scaleX = fit.width / wanted.width
        let scaleY = fit.height / wanted.height
        return CGRect(
            x: fit.minX + (shown.x - wanted.x) * scaleX,
            y: fit.minY + (shown.y - wanted.y) * scaleY,
            width: shown.width * scaleX,
            height: shown.height * scaleY
        )
    }

    private func viewport(for region: WatchLinkProtocol.Viewport, fit: CGRect) -> WatchLinkProtocol.Viewport {
        var viewport = region
        let scale = WKInterfaceDevice.current().screenScale
        viewport.pixelWidth = max(16, min(1024, Int(fit.width * scale)))
        viewport.pixelHeight = max(16, min(1024, Int(fit.height * scale)))
        viewport.quality = 60
        return viewport
    }

    private func clamp(_ point: CGPoint, region: WatchLinkProtocol.Viewport) -> CGPoint {
        clamp(point, region: CGSize(width: region.width, height: region.height))
    }

    private func clamp(_ point: CGPoint, region: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(region.width / 2, point.x), 1 - region.width / 2),
            y: min(max(region.height / 2, point.y), 1 - region.height / 2)
        )
    }

    private static var screenAspect: Double {
        let bounds = WKInterfaceDevice.current().screenBounds.size
        return bounds.height > 0 ? bounds.width / bounds.height : 0.8
    }

    /// Four decimals, so tiny jitter doesn't count as a new viewport.
    private static func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
}
