//
//  FoveatedQuitTitleButton.swift
//  VisionVNC
//
//  Quits whatever title is submitting frames on the host. Offered in two places — the
//  wrist HUD's action row and the PCVR controls window — because it is the only way out
//  of a title that has no exit of its own (hello_xr), and which of the two is reachable
//  depends on where the user is: the HUD needs a palm raised in-session, the window needs
//  hands free to look away from the game.
//
//  Shared rather than written twice: the arming behaviour below is the part that must not
//  drift between them.
//

#if FOVEATED_ENABLED
import SwiftUI

struct FoveatedQuitTitleButton: View {
    var bridge: ControllerBridgeSender?
    /// True in the wrist HUD, where the row is icon-only and space is tight.
    var iconOnly: Bool = false
    /// True in the PCVR window, to match the sizing of the buttons beside it.
    var wide: Bool = false

    @State private var armed = false

    var body: some View {
        Button {
            if armed {
                bridge?.requestStopActiveClient()
                armed = false
            } else {
                armed = true
            }
        } label: {
            // The armed state says so in words even in the icon-only row: this one ends a
            // process, and an icon swap is too quiet a difference to hang that on.
            labelContent
                .frame(minWidth: wide ? 120 : nil)
                .padding(.vertical, wide ? 6 : 0)
        }
        // Red and filled in both places. It was a bordered button with a bare xmark, which
        // in a row of bordered buttons read as "close this panel" rather than as the one
        // control here that stops a running game.
        .buttonStyle(.borderedProminent)
        .tint(.red)
        // Nothing submitting means nothing to close, and the host would only log that.
        .disabled(bridge?.activeGame == nil)
        // Disarms itself, so it cannot sit waiting for a stray glance — the panel is driven
        // by gaze and a pinch, the cheapest possible input to hit by accident.
        .task(id: armed) {
            guard armed else { return }
            try? await Task.sleep(for: .seconds(4))
            armed = false
        }
    }

    @ViewBuilder
    private var labelContent: some View {
        if armed {
            if iconOnly {
                Text("quit?").font(.caption2)
            } else {
                Label("Really quit?", systemImage: "xmark.octagon.fill")
            }
        } else if iconOnly {
            // The two label styles are distinct types, so this cannot be a ternary.
            Label(title, systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon)
        }
    }

    private var title: String {
        guard let game = bridge?.activeGame else { return "Quit title" }
        // "hello_xr.exe" → "hello_xr": the extension is noise at this size.
        let trimmed = game.hasSuffix(".exe") ? String(game.dropLast(4)) : game
        return trimmed.count <= 14 ? "Quit \(trimmed)" : "Quit title"
    }
}
#endif
