import AppKit
import SwiftUI

/// Projects moved to Longwave Companion: the agent sandbox, sessions and
/// schedules are host-side and run in that process, not this client.
/// `longwave-companion://projects` launches the Companion if needed and brings
/// its Projects window forward.
struct MacProjectsPointerView: View {
    private static let companionBundleID = "pro.longwave.companion"
    private static let projectsURL = URL(string: "longwave-companion://projects")!
    @State private var companionURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: companionBundleID)

    var body: some View {
        ContentUnavailableView {
            Label("Projects are in Longwave Companion", systemImage: "sparkles")
        } description: {
            Text("The agent sandbox, its sessions and schedules run in Longwave Companion. Sandbox Desktop opens here.")
        } actions: {
            if let companionURL {
                Button("Open Projects") {
                    NSWorkspace.shared.open(Self.projectsURL)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Longwave Companion isn't installed.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Projects")
        .onAppear {
            companionURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.companionBundleID)
        }
    }
}
