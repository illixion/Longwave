import SwiftUI

struct WatchHomeView: View {
    @Environment(WatchHostStore.self) private var hosts

    var body: some View {
        NavigationStack {
            if let host = hosts.host {
                List {
                    NavigationLink {
                        WatchDesktopView(host: host)
                    } label: {
                        Label("Desktop", systemImage: "display")
                    }
                    Section {
                        Text(host.name)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Forget This Mac", role: .destructive) { hosts.forget() }
                    }
                }
                .navigationTitle("Longwave")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "applewatch.radiowaves.left.and.right")
                            .font(.title2)
                        Text("No Mac yet")
                            .font(.headline)
                        Text("Pairing from the iPhone app isn't built yet. In the simulator, launch with -watchHost <address> -watchToken <token>.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Longwave")
            }
        }
    }
}
