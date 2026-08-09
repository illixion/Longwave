#if MOONLIGHT_ENABLED
import SwiftUI

/// Semi-transparent HUD showing live streaming statistics.
struct StreamStatsOverlay: View {
    @Environment(MoonlightConnectionManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let stats = manager.streamStats

            Text("\(stats.videoCodec) \(stats.resolution) @ \(stats.configuredFPS) FPS\(manager.isHDRActive ? " HDR" : "")")
                .font(.caption.monospaced())
            Text("FPS: \(stats.actualFPS, specifier: "%.1f")")
                .font(.caption.monospaced())
            Text("RTT: \(stats.networkRttMs) ms (±\(stats.rttVarianceMs))")
                .font(.caption.monospaced())
            Text("Decode: \(stats.decodeTimeMs, specifier: "%.1f") ms")
                .font(.caption.monospaced())
            Text("Frames: \(stats.totalFrames)  Dropped: \(stats.droppedFrames)")
                .font(.caption.monospaced())
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .allowsHitTesting(false)
    }
}
#endif
