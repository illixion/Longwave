//
//  GestureChargeView.swift
//  VisionVNC
//
//  The filling ring shown at the hand while a menu-class gesture charges.
//
//  Menu and system are the only gestures held to a deliberate 1.5 s, because they are the
//  only ones whose misfire cannot be undone: hello_xr binds menu straight to
//  xrRequestExitSession, so an accidental little-finger pinch ends the session outright.
//  A silent delay would only trade a surprise quit for an unresponsive button, so the
//  hold is drawn: the ring says a press is happening, how far off it is, and — because it
//  empties the moment the hand opens — that letting go cancels it.
//

#if FOVEATED_ENABLED
import SwiftUI

/// Attachment root. The attachment's view is built once, so the observation has to live
/// inside it — reading `gestureCharge` here is what makes the ring fill. While nothing is
/// charging the property is nil and unchanging, so this costs nothing at rest.
struct GestureChargeRoot: View {
    let manager: FoveatedConnectionManager

    var body: some View {
        GestureChargeView(charge: manager.controllerBridge?.gestureCharge)
    }
}

struct GestureChargeView: View {
    var charge: ControllerBridgeSender.GestureCharge?

    var body: some View {
        ZStack {
            // Dark, thin track against a bright arc. The first cut used white-on-white at
            // the same width, and on a light scene a part-filled ring was indistinguishable
            // from a full one — it read as a stuck circle rather than as progress.
            Circle()
                .fill(.black.opacity(0.35))
            Circle()
                .stroke(.black.opacity(0.45), lineWidth: 4)
            Circle()
                .trim(from: 0, to: Double(charge?.progress ?? 0))
                .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                // From the top, clockwise: the direction every progress ring turns.
                .rotationEffect(.degrees(-90))
                .shadow(color: .black.opacity(0.5), radius: 2)
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
        }
        .frame(width: 72, height: 72)
        .opacity(charge == nil ? 0 : 1)
        // No animation on progress: it is already sampled per frame from the hold
        // duration, and animating it would lag the finger.
        .animation(.easeOut(duration: 0.12), value: charge == nil)
    }

    private var label: String {
        switch charge?.target {
        case .system: "Home"
        default: "Menu"
        }
    }
}
#endif
