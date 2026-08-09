#if MOONLIGHT_ENABLED
import SwiftUI
import AppKit
import AVFoundation

/// macOS counterpart of the visionOS `VideoLayerView`: a layer-backed `NSView`
/// that hosts the Moonlight `AVSampleBufferDisplayLayer` (hardware decode +
/// display, native HDR). The layer's frame is kept in sync in `layout()`.
final class VideoLayerNSView: NSView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
}

/// SwiftUI wrapper hosting the Moonlight video layer.
struct MacVideoLayerView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> VideoLayerNSView {
        VideoLayerNSView(displayLayer: displayLayer)
    }

    func updateNSView(_ nsView: VideoLayerNSView, context: Context) {}
}
#endif
