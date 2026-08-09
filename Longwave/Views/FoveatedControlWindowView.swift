//  FoveatedControlWindowView.swift
//
//  The small floating PCVR panel (window id "foveated-controls"), summoned from the
//  wrist HUD mid-session. Deliberately thin: connecting, settings and help all live
//  in the PCVR tab now, and this is only here because reaching a tab means finding
//  the main window, which is the wrong errand when you are inside a game and want
//  to pause. Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI

#if !targetEnvironment(simulator)
import FoveatedStreaming
#endif

struct FoveatedControlWindowView: View {
    @Environment(FoveatedConnectionManager.self) private var manager
    @Environment(\.openWindow) private var openWindow

    @State private var showAlignmentDebug = false

    var body: some View {
        NavigationStack {
            Group {
                if manager.isDisconnected {
                    idleState
                } else {
                    FoveatedControlsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring, value: manager.isDisconnected)
            .navigationTitle("PCVR")
            .toolbar {
                // Alignment is diagnosed in-session, so the HUD lives one tap away
                // from the live controls rather than in the tab's settings.
                if !manager.isDisconnected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAlignmentDebug = true
                        } label: {
                            Label("Hand Alignment", systemImage: "hand.raised.fingers.spread")
                        }
                    }
                }
            }
            .sheet(isPresented: $showAlignmentDebug) {
                NavigationStack {
                    FoveatedAlignmentDebugView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showAlignmentDebug = false }
                            }
                        }
                }
                .frame(minWidth: 560, minHeight: 620)
            }
        }
        .homeOrnament()
        .trackWindowSession(id: "foveated-controls")
    }

    private var idleState: some View {
        VStack(spacing: 16) {
            Image(systemName: "visionpro")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Not streaming")
                .font(.title3).fontWeight(.semibold)
            Text("Start a session from the PCVR tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open PCVR") {
                WindowSessionRegistry.surface("main", using: openWindow)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }
}
#endif
