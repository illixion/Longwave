//
//  PCVRWebPanelView.swift
//  Longwave
//
//  What a pinned web panel shows: the page, and while the panels are taking input
//  (touch or move mode, switched on from the palm HUD), a bar with Done under it.
//  In view mode nothing on the panel takes input at all, so a pinch aimed past it
//  still reaches the game.
//
//  Gated behind FOVEATED_ENABLED.
//

#if FOVEATED_ENABLED
import RAVEBrowser
import SwiftUI
import WebKit

struct PCVRWebPanelView: View {
    let page: PCVRWebPanelPage
    let store: PCVRWebPanelStore

    var body: some View {
        VStack(spacing: 8) {
            RAVEWebViewHost(webView: page.webView, isPaused: page.isPaused)
                .frame(width: PCVRWebPanelConfig.layoutPoints.width,
                       height: PCVRWebPanelConfig.layoutPoints.height)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .allowsHitTesting(store.mode == .touch)
            if store.mode != .view {
                bar
            }
        }
        .padding(store.mode == .view ? 0 : 10)
        .glassBackgroundEffect()
        .allowsHitTesting(store.mode != .view)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            if store.mode == .touch {
                Button {
                    page.webView.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                Button {
                    page.webView.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Spacer()
                Text("Touch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Drag the bar below to move, the corner to resize")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Button("Done") { store.mode = .view }
                .buttonStyle(.borderedProminent)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(width: PCVRWebPanelConfig.layoutPoints.width)
    }
}
#endif
