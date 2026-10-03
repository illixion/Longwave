import DebugTrace
import DebugTraceServer
import SwiftUI
import AppKit

/// Menu bar companion app for Longwave (macOS side): streams system audio
/// to the Vision Pro via a Core Audio process tap, relays Music.app now-playing
/// metadata + transport, and offers keyboard text injection and SSH key setup.
///
/// The audio path works around macOS forcing Spatial Audio on for Mac Virtual
/// Display — audio played by the visionOS app honors the per-app setting.
@main
struct CompanionApp: App {
    @State private var controller: AudioStreamerController
    @State private var broadcastServer: BroadcastServerManager
    // Projects: the local agent sandbox (scripts/agent-sandbox) and the
    // scheduler that fires recurring headless runs into it while the app runs.
    @State private var sandbox: LocalSandboxController
    @State private var scheduler: LocalScheduler

    init() {
        // Before any controller reads its settings (see the type's comment).
        LongwaveMacSettingsMigration.runOnce()
        _controller = State(initialValue: AudioStreamerController())
        _broadcastServer = State(initialValue: BroadcastServerManager())
        let sandbox = LocalSandboxController()
        let scheduler = LocalScheduler(sandbox: sandbox)
        _sandbox = State(initialValue: sandbox)
        _scheduler = State(initialValue: scheduler)
        // Here rather than in a window's task: the Companion runs windowless
        // in the menu bar, and schedules must fire without any window open.
        // The agent's desktop session is *not* started here: it is logged in
        // only when the user asks (Log In, setup, Device Hub) or a schedule
        // resets the sandbox — never just because the Companion launched.
        scheduler.start()

        DebugTrace.configure(.init(subsystems: [Bundle.main.bundleIdentifier, "pro.longwave.companion"]
            .compactMap { $0 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }))
        DebugTraceServer.startIfRequested()
        // Surface the Local Network permission prompt at launch rather than
        // waiting for the first stream — reading hostName performs a
        // local-network lookup, which is enough to trigger the dialog.
        let hostName = ProcessInfo.processInfo.hostName
        DebugLogger(subsystem: "pro.longwave.companion", category: "App")
            .info("Local network access prompt triggered (host: \(hostName, privacy: .private))")
    }

    var body: some Scene {
        MenuBarExtra {
            CompanionMenuView(
                controller: controller, broadcastServer: broadcastServer, showsProjects: true,
                grantFullDiskAccess: sandbox.availability == .ready && !sandbox.hasFullDiskAccess
                    ? { sandbox.openFullDiskAccessSettings() } : nil)
        } label: {
            // Priority: injecting > now-playing track > audio idle/active.
            if controller.isInjecting {
                Image(systemName: "keyboard.fill")
            } else if let track = controller.menuBarTrackText {
                // Already carries the ♪ and is pre-trimmed to the room the menu
                // bar has — the label can't constrain its own width, so the
                // string is what has to be the right length.
                Text(track)
            } else {
                // The app icon's wave as a template glyph; it goes flat while audio is stopped.
                Image(controller.isRunning ? "MenuBarWave" : "MenuBarWaveOff")
                    .accessibilityLabel(controller.isRunning ? "Longwave, audio on" : "Longwave, audio off")
            }
        }
        .menuBarExtraStyle(.window)

        // Sidebar + detail panes with all configuration. A Settings scene
        // (not a Window) keeps the app menu-bar-only: it never auto-opens
        // at launch and isn't restored on relaunch — it only appears from
        // the popover's button. While open, the activation policy flips to
        // .regular (dock icon, Cmd-Tab, standard focus) and reverts to
        // .accessory on close, so there's no permanent dock presence.
        Settings {
            CompanionWindowView(controller: controller, broadcastServer: broadcastServer)
                .companionWindowActivation()
        }

        // The agent sandbox: projects, sessions, sign-ins and schedules.
        // Also opened by longwave-companion://projects (LongwaveMac's Projects
        // entry): SwiftUI routes a URL to the scene whose matching set the URL
        // contains, so the x-callback-url form works too.
        Window("Projects", id: "projects") {
            NavigationStack {
                MacProjectsView()
            }
            .environment(sandbox)
            .environment(scheduler)
            .frame(minWidth: 620, minHeight: 520)
            .companionWindowActivation()
        }
        .defaultSize(width: 720, height: 760)
        .handlesExternalEvents(matching: ["projects"])
    }
}

/// While any Companion window is open the app is a regular app (Dock icon,
/// Cmd-Tab, normal focus); with none open it goes back to menu-bar only. Counted
/// so closing one window doesn't hide the app while another is still open.
private struct CompanionWindowActivation: ViewModifier {
    @MainActor private static var openCount = 0

    func body(content: Content) -> some View {
        content
            .onAppear {
                Self.openCount += 1
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear {
                Self.openCount = max(0, Self.openCount - 1)
                if Self.openCount == 0 { NSApp.setActivationPolicy(.accessory) }
            }
    }
}

extension View {
    func companionWindowActivation() -> some View { modifier(CompanionWindowActivation()) }
}
