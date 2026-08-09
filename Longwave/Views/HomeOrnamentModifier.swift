import SwiftUI

/// Bottom ornament with a Home button that surfaces the main connection
/// manager window. visionOS reopens the app's last-used window, so a
/// sub-window (stream, keyboard, audio) can come back without any way to
/// reach the connection list — this gives every pop-out window a way home.
struct HomeOrnament: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.ornament(attachmentAnchor: .scene(.bottomFront)) {
            Button {
                openWindow(id: "main", value: MainWindowID.shared)
            } label: {
                Label("Connections", systemImage: "house")
                    .labelStyle(.iconOnly)
            }
            .help("Open the connection manager")
            .padding(8)
            .glassBackgroundEffect()
        }
    }
}

extension View {
    /// Adds the Home ornament. Apply to every pop-out window's root view.
    func homeOrnament() -> some View {
        modifier(HomeOrnament())
    }
}
