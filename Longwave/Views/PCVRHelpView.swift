//  PCVRHelpView.swift
//
//  The PCVR tab's help sheet, behind the question mark in its toolbar. Everything
//  you need to know once, and nothing you need on screen every time — which is why
//  it is a sheet and not a section of the form.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI

struct PCVRHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                foveation
                topic("What you need", rows: [
                    Row("pc", "A Windows PC with an NVIDIA RTX card",
                        "Running the Longwave Companion, with PCVR started. It installs the streaming host for you the first time."),
                    Row("bolt.badge.checkmark", "40-series officially, 30-series in practice",
                        "NVIDIA lists RTX 40-series or newer as supported, and CloudXR will say so if you have less. A 30-series card does work — this was built on a 3080 — but with less headroom, so expect to sit a stream-quality step lower."),
                    Row("wifi", "Both on the same network",
                        "The PC announces itself, so there is normally no address to type. If your network blocks that, switch Connection to By IP address."),
                    Row("qrcode", "One pairing, then never again",
                        "The first connection shows a code on the PC. After that the headset is remembered."),
                ])
                topic("On the PC", rows: [
                    Row("dial.medium", "Stream quality",
                        "Performance, Balanced or Quality, in the companion's PCVR options. Each step up asks the PC for more pixels to render and encode — if a heavy game stutters, this is the first lever to pull, and it applies from the next start."),
                    Row("cube.transparent", "Passthrough cutouts",
                        "Off by default. Turned on, anything a game paints pure green (00FF00) arrives as a hole and you see your real room through it — a green-screen world in VRChat, a cockpit with the canopy keyed out. The headset switches itself into Mixed immersion while it is on, which is the only mode that can show those holes, so the Digital Crown stops adjusting immersion until you turn it off again. It costs encoder time and bitrate on every frame, and changing it restarts PCVR."),
                    Row("eye.circle", "VRChat eye tracking",
                        "Off by default. Turned on, your real gaze drives your avatar's eyes over OSC — the same eye tracking that foveates the render, doing a second job. It takes over the eye channel, so leave it off if another OSC eye-tracking app is running on that PC."),
                    Row("network", "Remote play over Tailscale",
                        "For a PC that is not on your network — at home, or a cloud GPU host. Switch the companion's Connection to Tailscale, install Tailscale on the headset, and connect By IP address to the PC's tailnet address. It needs a direct WireGuard path: a relayed connection cannot carry this much video, and the companion warns you when it sees one."),
                ])
                topic("Your hands", rows: [
                    Row("hand.point.up.left", "Point and pinch to click",
                        "Your right hand aims. The ray leaves your palm, not your fingertip, so pinching does not drag the aim off target."),
                    Row("hand.draw", "Move a panel",
                        "Your left hand casts a visible beam. Put it on a panel's grab bar — or simply look at the bar — then pinch and move your hand, as you would move a window here. ✕ puts the panel away."),
                    Row("hand.raised", "Raise a palm for the wrist HUD",
                        "Turn a palm toward your face and look at it. Quit the running title, put your PC's desktop on a panel, or switch between emulated controllers and bare hands."),
                    Row("gamecontroller", "A controller is optional",
                        "Pair a Switch Pro or a Quest controller, then choose OpenXR, Xbox 360, or both in the Windows Companion. Without one, pinch gestures stand in for the buttons."),
                ])
                topic("If something is wrong", rows: [
                    Row("magnifyingglass", "The PC does not appear",
                        "Check PCVR is started in the Windows Companion, and that both devices are on the same Wi‑Fi band. Some guest and corporate networks block discovery between clients entirely."),
                    Row("hand.raised.fingers.spread", "Hands land in the wrong place",
                        "Hand alignment, under Controls during a session, shows what the PC is actually receiving."),
                    Row("bolt.horizontal", "Frames stutter",
                        "Step Stream quality down on the PC. Then close anything else recording or encoding — game recording overlays cost a surprising amount of the same encoder this needs."),
                ])
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("About PCVR")
    }

    /// The one claim worth making carefully, because it is the thing this does
    /// that stock CloudXR does not.
    private var foveation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Foveated on the PC, by your eyes", systemImage: "eye")
                .font(.title3).fontWeight(.semibold)
            Text("""
            Streaming a VR headset normally means the PC renders every pixel at the same \
            quality and hopes the encoder can keep up. Here your gaze reaches the PC, so the \
            game itself renders in full detail where you are actually looking and spends \
            less on the periphery you cannot resolve anyway.

            That is not how CloudXR works out of the box — games running under it get no eye \
            tracking at all. Longwave supplies it, which is why a given PC can hold a higher \
            frame rate here than it does with a stock setup.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private struct Row: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String

        init(_ icon: String, _ title: String, _ detail: String) {
            self.icon = icon
            self.title = title
            self.detail = detail
        }
    }

    private func topic(_ title: String, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3).fontWeight(.semibold)
            ForEach(rows) { row in
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title)
                        Text(row.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: row.icon)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                }
            }
        }
    }
}
#endif
