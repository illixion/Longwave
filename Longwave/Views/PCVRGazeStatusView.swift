//  PCVRGazeStatusView.swift
//
//  The "Eye tracking" readout: whether the wearer's eyes are reaching the PC's
//  picture, hop by hop, in words (see PCVRGazeHealth). Shown on the palm HUD
//  (FoveatedHUDView) and by anything else that wants to say it. Liveness only:
//  counters, never a direction.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import RAVEDiagnostics
import SwiftUI
import QuartzCore

struct PCVRGazeStatusView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @State private var watch = PCVRGazeWatch()
    @State private var tick = 0

    private var health: PCVRGazeHealth {
        let now = CACurrentMediaTime()
        return PCVRGazeHealth.evaluate(hasFeed: manager.gazeLiveness.hasFeed,
                                       sinceNewSample: watch.sinceNewSample(now: now),
                                       feedRate: watch.sampleRate(),
                                       uplink: PCVRGazeUplinkRegistry.current?(),
                                       sinceCentreMoved: watch.sinceCentreMoved(now: now))
    }

    private func tint(_ level: PCVRGazeHealth.Level) -> Color? {
        switch level {
        case .broken: .red
        case .warning: .orange
        case .ok: .green
        case .idle: nil
        }
    }

    var body: some View {
        let health = health
        let _ = tick // redraw on the clock
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Eye tracking").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: health.level == .ok ? "eye" : "eye.slash")
                    .foregroundStyle(tint(health.level) ?? .secondary)
            }
            Text(health.verdict)
                .font(.caption)
                .foregroundStyle(tint(health.level) ?? .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                ForEach(health.hops) { hop in
                    RAVEStatView(hop.name, value: hop.detail, tint: tint(hop.level))
                }
                Spacer()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                watch.observe(sequence: manager.gazeLiveness.sequence,
                              centres: PCVRGazeUplinkRegistry.current?()?.centres,
                              now: CACurrentMediaTime())
                tick &+= 1
            }
        }
    }
}
#endif
