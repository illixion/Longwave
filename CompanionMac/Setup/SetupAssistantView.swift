import AppKit
import SwiftUI

/// What the user wants to do from the headset. Each feature switches itself on
/// when chosen (so nothing waits behind a default-off switch) and names the
/// grants it needs, so the assistant asks only for those.
enum CompanionFeature: String, CaseIterable, Identifiable {
    case screen, audio, control, projects
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: "See this Mac's screen"
        case .audio: "Hear this Mac's audio"
        case .control: "Control this Mac"
        case .projects: "Run coding agents"
        }
    }

    var detail: String {
        switch self {
        case .screen: "Stream the desktop, or a virtual display made for the headset."
        case .audio: "Stream system audio with now-playing info and playback controls."
        case .control: "Use a mouse, keyboard shortcuts and typing from the headset."
        case .projects: "Claude, Codex and Copilot in a separate sandbox account, started from the headset."
        }
    }

    var systemImage: String {
        switch self {
        case .screen: "display"
        case .audio: "speaker.wave.2"
        case .control: "cursorarrow.motionlines"
        case .projects: "hammer"
        }
    }

    var permissions: [PermissionCenter.Kind] {
        switch self {
        case .screen: [.localNetwork, .screenRecording, .notifications]
        case .audio: [.localNetwork, .systemAudio, .musicAutomation]
        case .control: [.accessibility]
        case .projects: [.sandboxInstalled, .remoteLogin, .screenSharing, .fullDiskAccess]
        }
    }

    static let projectsWantedKey = "setup.wantsProjects"
}

extension PermissionCenter.Kind {
    var title: String {
        switch self {
        case .localNetwork: "Local Network"
        case .screenRecording: "Screen Recording"
        case .systemAudio: "System Audio Recording"
        case .accessibility:
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "Device Control" : "Accessibility"
        case .notifications: "Notifications"
        case .musicAutomation: "Control Music"
        case .sandboxInstalled: "Agent sandbox"
        case .fullDiskAccess: "Full Disk Access"
        case .remoteLogin: "Remote Login"
        case .screenSharing: "Screen Sharing"
        }
    }

    var reason: String {
        switch self {
        case .localNetwork: "Lets headsets find this Mac and connect to it."
        case .screenRecording: "Captures the desktop for the headset. Asked here so it never pops up while you're wearing it."
        case .systemAudio: "Captures what the Mac plays, without the Companion's own sounds."
        case .accessibility: "Moves the pointer, presses keys and types for the headset."
        case .notifications: "Tells you when a headset connects or a scheduled run finishes."
        case .musicAutomation: "Optional: now-playing and controls for Music when nothing else reports them."
        case .sandboxInstalled: "A hidden standard account the agents run as. Installed once, with your administrator password."
        case .fullDiskAccess: "Lets the Companion reset the sandbox and save its home. macOS never asks for this one."
        case .remoteLogin: "Agents run in the sandbox over SSH on this Mac. Turn on under General → Sharing."
        case .screenSharing: "Gives the sandbox a desktop session, which simulators need. Turn on under General → Sharing."
        }
    }

    var isOptional: Bool { self == .musicAutomation || self == .notifications }

    /// Rows a button can't fix: they only open System Settings.
    var opensSettings: Bool { [.localNetwork, .fullDiskAccess, .remoteLogin, .screenSharing].contains(self) }
}

/// First-run setup: features first, then only the grants they need, each with
/// live status and one button. Opens by itself until the user finishes it, and
/// any time from the menu bar's "Set Up…".
struct SetupAssistantView: View {
    @Bindable var controller: AudioStreamerController
    @Environment(LocalSandboxController.self) private var sandbox
    @Environment(SandboxInstaller.self) private var installer
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var permissions = PermissionCenter.shared
    @AppStorage(CompanionFeature.projectsWantedKey) private var wantsProjects = false
    @AppStorage(SetupAssistantView.completedKey) private var completed = false

    static let completedKey = "setup.completed.v1"

    var body: some View {
        Form {
            Section {
                ForEach(CompanionFeature.allCases) { feature in
                    Toggle(isOn: binding(for: feature)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.title)
                                Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: feature.systemImage)
                        }
                    }
                }
            } header: {
                Text("What do you want to do from your headset?")
            } footer: {
                Text("You can change these any time in the Companion window.")
            }

            if !neededPermissions.isEmpty {
                Section {
                    ForEach(neededPermissions) { kind in
                        PermissionRow(kind: kind, status: permissions.status(kind), action: { act(on: kind) },
                                      installer: kind == .sandboxInstalled ? installer : nil)
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Each switch in System Settings takes effect right away, except Full Disk Access and sometimes Screen Recording, which need the Companion to relaunch.")
                }
            }

            Section("Next") {
                Text("In Longwave on your headset, add a Native connection and pick this Mac under Computers Nearby. Compare the code it shows with this Mac's, then choose what that headset may do.")
                    .foregroundStyle(.secondary)
                HStack {
                    if neededPermissions.contains(where: { $0 == .fullDiskAccess || $0 == .screenRecording }) {
                        Button("Relaunch Companion") { LocalSandboxController.relaunchApp() }
                    }
                    Spacer()
                    Button(completed ? "Done" : "Finish Setup") {
                        completed = true
                        dismissWindow(id: "setup")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
        .onAppear {
            permissions.beginWatching()
            Task { await sandbox.refresh(); permissions.refresh() }
        }
        .onDisappear { permissions.endWatching() }
    }

    private var chosen: [CompanionFeature] {
        CompanionFeature.allCases.filter { isOn($0) }
    }

    private var neededPermissions: [PermissionCenter.Kind] {
        var seen = Set<PermissionCenter.Kind>()
        return chosen.flatMap(\.permissions).filter { seen.insert($0).inserted }
    }

    private func isOn(_ feature: CompanionFeature) -> Bool {
        let native = controller.macNativeStreaming
        return switch feature {
        case .screen: native.enabled
        case .audio: controller.isRunning
        case .control: native.mouseControlEnabled || native.keyboardShortcutsEnabled || controller.injectionEnabled
        case .projects: wantsProjects
        }
    }

    private func binding(for feature: CompanionFeature) -> Binding<Bool> {
        Binding(get: { isOn(feature) }, set: { on in
            switch feature {
            case .screen: controller.macNativeStreaming.enabled = on
            case .audio: controller.isRunning = on
            case .control:
                controller.macNativeStreaming.mouseControlEnabled = on
                controller.macNativeStreaming.keyboardShortcutsEnabled = on
                controller.injectionEnabled = on
            case .projects: wantsProjects = on
            }
        })
    }

    private func act(on kind: PermissionCenter.Kind) {
        if kind == .sandboxInstalled {
            Task {
                if await installer.install() { await sandbox.refresh() }
                permissions.refresh()
            }
        } else {
            permissions.request(kind)
        }
    }
}

private struct PermissionRow: View {
    let kind: PermissionCenter.Kind
    let status: PermissionCenter.Status
    let action: () -> Void
    var installer: SandboxInstaller?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title + (kind.isOptional ? " (optional)" : ""))
                Text(kind.reason).font(.caption).foregroundStyle(.secondary)
                if let installer {
                    switch installer.state {
                    case .running(let step):
                        HStack { ProgressView().controlSize(.small); Text(step).font(.caption) }
                    case .failed(let message):
                        Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    default:
                        EmptyView()
                    }
                }
            }
            Spacer()
            if status != .granted {
                Button(buttonTitle, action: action)
                    .disabled(installer?.isRunning == true)
            }
        }
    }

    private var buttonTitle: String {
        if kind == .sandboxInstalled { return "Install…" }
        if status == .denied || kind.opensSettings { return "Open Settings…" }
        if status == .unknown && kind == .musicAutomation { return "Ask…" }
        return "Allow…"
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .notDetermined, .unknown:
            Image(systemName: kind.isOptional ? "circle.dashed" : "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
}
