//  FoveatedBandwidthBannerView.swift
//
//  The bandwidth-cap warning and stop notices, shown in the same immersive space
//  and by the same mechanism as the trial banner (see FoveatedTrialBannerView and
//  ImmersiveBannerRoot) — the wrist HUD only appears on request, and a cap crossed
//  without you asking is exactly the kind of thing that has to arrive on its own.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI

struct FoveatedBandwidthBannerView: View {
    let kind: PCVRBandwidthMonitor.BannerKind
    let monitor: PCVRBandwidthMonitor

    private var usedGB: Double { monitor.usedGB ?? 0 }
    private var thresholdGB: Double {
        kind == .stop ? (monitor.stopThresholdGB ?? 0) : (monitor.warningThresholdGB ?? 0)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind == .stop ? "network.slash" : "network")
                .font(.system(size: 26))
                .foregroundStyle(kind == .stop ? .red : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind == .stop ? "Bandwidth cap reached" : "Approaching bandwidth cap")
                    .font(.headline)
                    .monospacedDigit()
                // Says what happens and where to fix it — same reasoning as the trial
                // banner: the fear this raises is "am I stuck", and the answer is no.
                Text(kind == .stop
                    ? "This PC has used \(usedGB, specifier: "%.1f") GB this month. Ending the session — reset the counter or raise the limit in the PCVR tab to keep streaming."
                    : "This PC has used \(usedGB, specifier: "%.1f") of \(thresholdGB, specifier: "%.0f") GB this month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: 460, alignment: .leading)
        .glassBackgroundEffect()
    }
}
#endif
