import RAVEUI
import SwiftUI

/// Compact ornament tab bar. The bar itself — the icon-only button that expands
/// into a labelled glass pill when selected, and its metrics — is RAVEUI's
/// `RAVETabBar`; this file used to carry a re-typed copy of Spatial Stash's,
/// which its own header credited. What stays here is the live broadcast /
/// view-sharing indicators, which are this app's alone.
struct MainTabBar: View {
    @Environment(BroadcastManager.self) private var broadcastManager
    @Binding var selectedTab: MainView.Tab

    private var isBroadcasting: Bool { broadcastManager.state == .broadcasting }
    private var isSharingView: Bool { broadcastManager.viewSharingActive }

    var body: some View {
        RAVETabBar(tabs: MainView.Tab.allCases, selection: $selectedTab) {
            if isBroadcasting || isSharingView {
                RAVETabBarDivider(height: 24)
                if isBroadcasting {
                    RAVETabBarIndicator(
                        systemImage: "dot.radiowaves.left.and.right",
                        help: "Broadcasting camera"
                    )
                }
                if isSharingView {
                    RAVETabBarIndicator(systemImage: "eye.fill", help: "Sharing your view")
                }
            }
        }
        .animation(.smooth(duration: 0.22), value: isBroadcasting)
        .animation(.smooth(duration: 0.22), value: isSharingView)
    }
}
