#if MOONLIGHT_ENABLED
import SwiftUI

/// Displays pairing status and PIN for Moonlight server pairing.
struct MoonlightPairingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(MoonlightConnectionManager.self) private var manager

    let connection: SavedConnection

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch manager.connectionState {
                case .connecting, .fetchingServerInfo:
                    connectingView

                case .pairing(let pin):
                    pairingView(pin: pin)

                case .paired, .fetchingApps:
                    fetchingAppsView

                case .ready:
                    appListView

                case .launching:
                    launchingView

                case .streaming:
                    streamingView

                case .error(let message):
                    errorView(message: message)

                default:
                    ProgressView()
                }
            }
            .padding(32)
            // macOS sheets size to content; pin a stable size so switching
            // between pairing / app-list states doesn't jump and the list has room.
            #if os(macOS)
            .frame(width: 460, height: 580)
            #endif
            .navigationTitle(connection.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        manager.disconnect()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - State Views

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(manager.statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    private func pairingView(pin: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Enter this PIN on your server")
                .font(.headline)

            Text(pin)
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))

            ProgressView()
                .controlSize(.regular)

            Text("Open your Sunshine web interface and enter this PIN when prompted.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var fetchingAppsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Paired!")
                .font(.headline)

            ProgressView("Fetching apps...")
        }
    }

    private var appListView: some View {
        @Bindable var manager = manager
        return VStack(spacing: 16) {
            if manager.apps.isEmpty {
                ContentUnavailableView(
                    "No Apps Found",
                    systemImage: "app.dashed",
                    description: Text("No applications are available on the server.")
                )
            } else {
                Text("Available Apps")
                    .font(.headline)

                // Display picker when server reports multiple displays
                if let modes = manager.serverInfo?.displayModes, modes.count > 1 {
                    Picker("Display", selection: $manager.selectedDisplayIndex) {
                        Text("Connection Default").tag(0)
                        ForEach(Array(modes.enumerated()), id: \.offset) { index, mode in
                            Text("\(mode.width)x\(mode.height) @ \(mode.refreshRate) Hz")
                                .tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // Show "Quit Session" button if an app is currently running
                if let info = manager.serverInfo, info.currentGameId != 0 {
                    let runningApp = manager.apps.first { $0.id == info.currentGameId }
                    Button(role: .destructive) {
                        manager.quitServerSession()
                    } label: {
                        Label(
                            "Quit \(runningApp?.name ?? "Active Session")",
                            systemImage: "stop.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                List(manager.apps) { app in
                    Button {
                        manager.launchApp(app)
                        // Open as a sibling window; the main window stays open.
                        // Value-keyed so this session gets its own window even
                        // while another session is streaming.
                        openWindow(id: "moonlight-stream", value: manager.sessionID)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: app.isAppCollectorGame ? "folder" : "gamecontroller")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            Text(app.name)
                                .font(.body)

                            Spacer()

                            if let info = manager.serverInfo, info.currentGameId == app.id {
                                Text("Running")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.green.opacity(0.2), in: Capsule())
                            }

                            if app.hdrSupported {
                                Text("HDR")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.yellow.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                }
                .listStyle(.plain)
                // A List has no intrinsic height inside a VStack/sheet on macOS,
                // so without a minHeight it collapses and the rows (which ARE
                // there) don't show. minHeight forces it to take space.
                .frame(minHeight: 260, maxHeight: 400)
            }
        }
    }

    private var launchingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(manager.statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    private var streamingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Streaming")
                .font(.headline)
            Text("The stream is active in the Moonlight Stream window.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("Error")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                manager.retry(connection: connection)
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
#endif
