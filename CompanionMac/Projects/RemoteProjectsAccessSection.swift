import SwiftUI

struct RemoteProjectsAccessSection: View {
    @Environment(CompanionProjectsServer.self) private var server
    @State private var name = "Mobile device"
    @State private var host = ProcessInfo.processInfo.hostName
    @State private var message: String?

    var body: some View {
        Section("Remote Projects access") {
            Text("Give each device its own invitation. It grants access to imported sandbox projects and agent sessions. Agent logins and the sandbox SSH key stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Device name", text: $name)
            TextField("This Mac's address (LAN or Tailscale)", text: $host)
            Button("Create and Copy Invitation") {
                do {
                    Pasteboard.copy(try server.invite(name: name, host: host))
                    message = "Invitation copied. Paste it in Longwave → Projects → Companion Sandbox on that device."
                } catch { message = error.localizedDescription }
            }
            ForEach(server.devices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(device.host).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy Invitation") {
                        do { Pasteboard.copy(try server.invitation(for: device)); message = "Invitation copied." }
                        catch { message = error.localizedDescription }
                    }
                    Button("Revoke", role: .destructive) {
                        do { try server.revoke(device); message = "Access revoked. Running agents remain in the sandbox." }
                        catch { message = error.localizedDescription }
                    }
                }
            }
            if !server.devices.isEmpty {
                Label(server.listening ? "Projects service running on port \(ProjectsProtocol.port)" : "Projects service unavailable",
                      systemImage: server.listening ? "network" : "exclamationmark.triangle")
                    .font(.caption)
            }
            if let error = server.error { Text(error).foregroundStyle(.red) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
