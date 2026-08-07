#if os(visionOS)
import SwiftUI
import AVFoundation
import UIKit

private final class MacNativeLayerView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        layer.backgroundColor = UIColor.clear.cgColor
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct MacNativeVideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> MacNativeLayerView {
        MacNativeLayerView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: MacNativeLayerView, context: Context) {}
}

struct MacNativeStreamView: View {
    @Environment(MacNativeStreamManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            Color.clear

            if let displayLayer = manager.displayLayer {
                MacNativeVideoView(displayLayer: displayLayer)
                    .ignoresSafeArea()
            }

            if manager.state != .streaming {
                VStack(spacing: 16) {
                    if case .disconnected = manager.state {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 42))
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }
                    Text(manager.state.statusText)
                        .font(.headline)
                }
                .padding(24)
                .glassBackgroundEffect()
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            HStack {
                Button {
                    openWindow(id: "main", value: MainWindowID.shared)
                } label: {
                    Label("Connections", systemImage: "house")
                }

                Button {
                    manager.disconnect()
                    WindowSessionRegistry.shared.closeAfterSurfacingMain(using: openWindow) {
                        dismissWindow(
                            id: "mac-native-stream",
                            value: MacNativeWindowID.shared
                        )
                    }
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.bordered)
            .padding(12)
            .glassBackgroundEffect()
        }
        .onDisappear {
            manager.disconnect()
        }
    }
}
#endif
