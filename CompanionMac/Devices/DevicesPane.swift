import AppKit
import SwiftUI

/// The Companion window's Devices tab: how headsets find and pair with this
/// Mac, every paired device with what it may do, and the shared token from
/// before per-device pairing while anything still uses it.
struct DevicesPane: View {
    @Bindable var controller: AudioStreamerController
    @State private var linkCopied = false
    @State private var confirmRevoke: CompanionDevice?
    @State private var confirmStopLegacy = false

    private var devices: CompanionDeviceRegistry { controller.devices }

    var body: some View {
        Form {
            Section {
                LabeledContent("Pairing") {
                    Text("In Longwave, add a Native connection and pick this Mac under Macs Nearby. This Mac then shows a code to compare and asks what the device may do.")
                        .foregroundStyle(.secondary)
                }
                if controller.presence.localNetworkDenied {
                    LabeledContent("Local Network") {
                        Button("Allow in System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                        }
                    }
                    Text("macOS is blocking Longwave Companion from the local network, so headsets can't find this Mac. Turn it on under Privacy & Security → Local Network.")
                        .foregroundStyle(.red)
                }
                if !controller.presence.knockingHeadsets.isEmpty {
                    LabeledContent("Nearby", value: controller.presence.knockingHeadsets.joined(separator: ", "))
                }
                if let status = controller.pairingStatus {
                    LabeledContent("Last pairing", value: status)
                }
                Toggle("Allow connections by address", isOn: $controller.allowConnectionsByAddress)
            } header: {
                Text("Headsets Nearby")
            } footer: {
                Text("Off, this Mac's ports stay closed until a paired device on the same network asks for them, so a port scan finds nothing. Keep it on to connect over Tailscale, a VPN, or any network where devices can't see this Mac.")
            }

            Section {
                HStack {
                    Button {
                        guard let url = controller.makeAddressLink(),
                              let service = NSSharingService(named: .sendViaAirDrop) else { return }
                        service.perform(withItems: [url])
                    } label: {
                        Label("AirDrop This Mac's Address", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        guard let url = controller.makeAddressLink() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        linkCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            linkCopied = false
                        }
                    } label: {
                        Label(linkCopied ? "Copied" : "Copy Link", systemImage: linkCopied ? "checkmark" : "doc.on.doc")
                    }
                }
                if let until = controller.addressLinkOpenUntil, until > Date() {
                    Text("Pairing by address is open until \(until.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Pair by Address")
            } footer: {
                Text("For a device that can't see this Mac over Bonjour. The link lists this Mac's addresses and nothing else — no key or token — and opening it on the device starts the same code comparison as pairing nearby.")
            }

            Section("Paired Devices") {
                if devices.devices.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(devices.devices.sorted { $0.pairedAt > $1.pairedAt }) { device in
                    DeviceRow(device: device, devices: devices, revoke: { confirmRevoke = device })
                }
            }

            if devices.acceptsLegacyToken {
                Section {
                    LabeledContent("Last used") {
                        Text(devices.legacyLastSeen.map { $0.formatted(.relative(presentation: .named)) } ?? "Not since this update")
                    }
                    Button("Stop Accepting the Shared Token…", role: .destructive) { confirmStopLegacy = true }
                } header: {
                    Text("Older Pairings")
                } footer: {
                    Text("Devices paired before each got its own key still use the one token this Mac used to share, with screen, audio and control. Longwave asks them to pair again; once they have, stop accepting it.")
                }
            }
        }
        .confirmationDialog("Revoke “\(confirmRevoke?.name ?? "")”?", isPresented: Binding(
            get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } })) {
            Button("Revoke", role: .destructive) {
                if let device = confirmRevoke { devices.revoke(device.id) }
                confirmRevoke = nil
            }
        } message: {
            Text("It's disconnected now and has to pair again to connect. Agent sessions it started keep running in the sandbox.")
        }
        .confirmationDialog("Stop accepting the shared token?", isPresented: $confirmStopLegacy) {
            Button("Stop Accepting", role: .destructive) { devices.stopAcceptingLegacyToken() }
        } message: {
            Text("Every device still using it is disconnected and has to pair again.")
        }
    }
}

private struct DeviceRow: View {
    let device: CompanionDevice
    let devices: CompanionDeviceRegistry
    let revoke: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(CompanionGrant.allCases.filter { $0 != .sshKey || devices.offersSSH(device.id) }) { grant in
                Toggle(grant.title, isOn: Binding(
                    get: { device.grants.contains(grant) },
                    set: { on in
                        var grants = device.grants
                        if on { grants.insert(grant) } else { grants.remove(grant) }
                        devices.setGrants(grants, for: device.id)
                    }))
            }
            Button("Revoke…", role: .destructive, action: revoke)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let allowed = CompanionGrant.allCases.filter { device.grants.contains($0) }.map(\.shortTitle)
        let seen = device.lastSeen.map { "seen " + $0.formatted(.relative(presentation: .named)) } ?? "never connected"
        return (allowed.isEmpty ? "Nothing allowed" : allowed.joined(separator: ", ")) + " · " + seen
    }
}

extension CompanionGrant {
    var shortTitle: String {
        switch self {
        case .screen: "Screen"
        case .audio: "Audio"
        case .input: "Control"
        case .projects: "Projects"
        case .sshKey: "SSH"
        }
    }
}
