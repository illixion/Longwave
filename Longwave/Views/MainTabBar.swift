import SwiftUI

/// Compact ornament tab bar: icon-only buttons where the selected tab
/// expands into a labeled glass pill. Design imported from Spatial Stash's
/// `TabBarOrnament`. Live broadcast/view-sharing indicators appear on the
/// trailing side while streaming.
struct MainTabBar: View {
    @Environment(BroadcastManager.self) private var broadcastManager
    @Binding var selectedTab: MainView.Tab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MainView.Tab.allCases, id: \.self) { tab in
                TabBarButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    action: { selectedTab = tab }
                )
            }
            if broadcastManager.state == .broadcasting || broadcastManager.viewSharingActive {
                Divider()
                    .frame(height: 24)
                if broadcastManager.state == .broadcasting {
                    LiveIndicator(systemImage: "dot.radiowaves.left.and.right", help: "Broadcasting camera")
                }
                if broadcastManager.viewSharingActive {
                    LiveIndicator(systemImage: "eye.fill", help: "Sharing your view")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
        .animation(.smooth(duration: 0.22), value: broadcastManager.state == .broadcasting)
        .animation(.smooth(duration: 0.22), value: broadcastManager.viewSharingActive)
    }
}

/// Non-interactive live-stream chip, matching the tab buttons' metrics.
private struct LiveIndicator: View {
    let systemImage: String
    let help: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(.red)
            .frame(minWidth: 44, minHeight: 32)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .help(help)
            .transition(.opacity)
    }
}

private struct TabBarButton: View {
    let tab: MainView.Tab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.title3)
                if isSelected {
                    Text(tab.rawValue)
                        .font(.callout)
                        .fontWeight(.medium)
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 44, minHeight: 32)
            .padding(.horizontal, isSelected ? 14 : 10)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(TabBarButtonStyle(isSelected: isSelected))
        .hoverEffect(.highlight)
        .help(tab.rawValue)
        .animation(.smooth(duration: 0.22), value: isSelected)
    }
}

private struct TabBarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? .primary : .secondary)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.thinMaterial)
                        .overlay(
                            Capsule()
                                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        )
                }
            }
    }
}
