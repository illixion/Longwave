import SwiftUI

/// The full app's single Settings window (Cmd-,): the client's new-connection
/// **defaults** plus all the **host** (companion) configuration in one tabbed
/// surface, so there's one place for everything instead of a separate sidebar
/// "Settings" and a separate host window. Reuses `SettingsView` (the client
/// defaults) and the companion's panes (`NativePane` … `KeyboardPane`) directly —
/// no duplicated forms.
struct MacSettingsView: View {
    @Bindable var controller: AudioStreamerController
    @Bindable var broadcastServer: BroadcastServerManager

    var body: some View {
        TabView {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            NativePane(controller: controller)
                .tabItem { Label("Native", systemImage: "macwindow.on.rectangle") }
            AccessTokenPane(controller: controller)
                .tabItem { Label("Token", systemImage: "key") }
            BroadcastPane(broadcastServer: broadcastServer)
                .tabItem { Label("Broadcast", systemImage: "dot.radiowaves.left.and.right") }
            RemoteControlPane(controller: controller)
                .tabItem { Label("Remote", systemImage: "terminal") }
            KeyboardPane(controller: controller)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
        }
        .formStyle(.grouped)
        // Fixed size (System Settings convention) so tall panes scroll inside
        // their grouped Form rather than growing the window off-screen.
        .frame(width: 660, height: 560)
        .onAppear {
            controller.refreshKeys()
            controller.injection.refreshAccessibility()
        }
    }
}
