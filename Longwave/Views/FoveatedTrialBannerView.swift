//  FoveatedTrialBannerView.swift
//
//  The warning that a trial session is about to end, shown inside the immersive
//  space because that is where the user is. The wrist HUD cannot carry this: it
//  only appears when a palm is raised, and a warning nobody thought to ask for
//  is exactly the one that must arrive on its own.
//
//  It is a notice, not a control. Buying mid-game would mean pulling someone out
//  of a title to read a price sheet; the offer is waiting in the PCVR tab
//  afterwards, and after a cut it opens by itself.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI

/// Attachment root for the one shared immersive banner entity. Built once — both
/// `limiter` and `bandwidthMonitor` are `@Observable`, so this re-renders on its own
/// whenever either one's state moves, the same way the trial-only version used to
/// react to the countdown alone. Precedence, highest first: a bandwidth stop means
/// the session is already ending, which outranks a trial countdown that is about to
/// be moot anyway; the trial countdown in turn outranks a bandwidth warning, which
/// is advisory and can wait a beat. Only one banner exists — nothing here has ever
/// needed two shown at once.
struct ImmersiveBannerRoot: View {
    let limiter: PCVRSessionLimiter
    let bandwidthMonitor: PCVRBandwidthMonitor

    var body: some View {
        if bandwidthMonitor.bannerKind == .stop {
            FoveatedBandwidthBannerView(kind: .stop, monitor: bandwidthMonitor)
        } else if let remaining = limiter.bannerRemaining {
            FoveatedTrialBannerView(remaining: remaining)
        } else if bandwidthMonitor.bannerKind == .warning {
            FoveatedBandwidthBannerView(kind: .warning, monitor: bandwidthMonitor)
        }
    }
}

struct FoveatedTrialBannerView: View {
    /// Seconds left when the banner was raised.
    var remaining: TimeInterval

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "hourglass")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("This session ends in \(PCVRSessionLimiter.clock(remaining))")
                    .font(.headline)
                    .monospacedDigit()
                // Says what happens, and that starting again is free — the fear
                // this raises is "am I out of PCVR for today", and the answer is no.
                Text("Trial sessions run 20 minutes. You can start another straight away, or unlock PCVR in the Longwave window.")
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
