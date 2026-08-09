import SwiftUI
import AppKit
import os

/// Menu bar companion app for Longwave (macOS side): streams system audio
/// to the Vision Pro via a Core Audio process tap, relays Music.app now-playing
/// metadata + transport, and offers keyboard text injection and SSH key setup.
///
/// The audio path works around macOS forcing Spatial Audio on for Mac Virtual
/// Display — audio played by the visionOS app honors the per-app setting.
@main
struct CompanionApp: App {
    @State private var controller = AudioStreamerController()
    @State private var broadcastServer = BroadcastServerManager()

    init() {
        // Surface the Local Network permission prompt at launch rather than
        // waiting for the first stream — reading hostName performs a
        // local-network lookup, which is enough to trigger the dialog.
        let hostName = ProcessInfo.processInfo.hostName
        Logger(subsystem: "com.illixion.LongwaveCompanion", category: "App")
            .info("Local network access prompt triggered (host: \(hostName, privacy: .private))")
    }

    var body: some Scene {
        MenuBarExtra {
            CompanionMenuView(controller: controller, broadcastServer: broadcastServer)
        } label: {
            // Priority: injecting > now-playing track > audio idle/active.
            if controller.isInjecting {
                Image(systemName: "keyboard.fill")
            } else if let track = controller.menuBarTrackText {
                Text("\(track) ♪")
            } else {
                Image(systemName: controller.isRunning ? "speaker.wave.2.fill" : "speaker.slash")
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
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
    }
}
