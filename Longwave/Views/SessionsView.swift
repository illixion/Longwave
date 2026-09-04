import SwiftUI

/// Sessions tab: lists every window the app currently has open and lets the
/// user "summon" any of them to their current position. On visionOS a window
/// can be snapped in another room, becoming unreachable until you walk back —
/// summoning calls `openWindow(id:)`, which brings the existing window to the
/// user. Windows in another room are flagged so it's clear which ones are out
/// of reach.
struct SessionsView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(AudioStreamManager.self) private var audioManager
    #if os(visionOS)
    @Environment(MacNativeStreamManager.self) private var macNativeManager
    #endif
    #if MOONLIGHT_ENABLED
    @Environment(MoonlightSessionStore.self) private var moonlightSessions
    #endif
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var registry: WindowSessionRegistry { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if registry.summonableIDs.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(registry.summonableIDs, id: \.self) { id in
                                if let kind = WindowSessionRegistry.kind(for: id) {
                                    sessionRow(kind)
                                }
                            }
                        } footer: {
                            Text("Summon brings a window to where you're standing — useful when one was left snapped in another room.")
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Open Windows",
            systemImage: "macwindow.on.rectangle",
            description: Text("Remote desktop, game stream, audio, and keyboard windows you open will appear here so you can summon them back to you.")
        )
    }

    private func sessionRow(_ kind: WindowSessionRegistry.WindowKind) -> some View {
        let inRoom = registry.isInActiveRoom(kind.id)
        return HStack(spacing: 16) {
            Image(systemName: kind.systemImage)
                .font(.title2)
                .frame(width: 44)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.headline)
                if let subtitle = subtitle(for: kind.id), !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Label(
                    inRoom ? "In this room" : "In another room",
                    systemImage: inRoom ? "location.fill" : "location.slash"
                )
                .font(.caption)
                .foregroundStyle(inRoom ? Color.secondary : Color.orange)
            }

            Spacer()

            Button {
                // Re-opening an already-open window makes visionOS bring it to the
                // user's current position. Via the registry, because some of these
                // windows are value-matched and a bare id would open nothing.
                surface(kind.id)
            } label: {
                Label("Summon", systemImage: "arrow.down.right.and.arrow.up.left.rectangle")
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                close(kind.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close this window")
        }
        .padding(.vertical, 6)
    }

    /// Moonlight windows are keyed per session; the one holding input focus is
    /// the one the user is playing on, so that is what a Summon or close targets.
    private func surface(_ id: String) {
        #if MOONLIGHT_ENABLED
        if id == "moonlight-stream" || id == "moonlight-keyboard" {
            openWindow(id: id, value: MoonlightSessionID(slot: moonlightSessions.focusedSlot))
            return
        }
        #endif
        WindowSessionRegistry.surface(id, using: openWindow)
    }

    private func close(_ id: String) {
        #if MOONLIGHT_ENABLED
        if id == "moonlight-stream" || id == "moonlight-keyboard" {
            dismissWindow(id: id, value: MoonlightSessionID(slot: moonlightSessions.focusedSlot))
            return
        }
        #endif
        dismissWindow(id: id)
    }

    /// Live connection label for a window, where one applies.
    private func subtitle(for id: String) -> String? {
        switch id {
        case "remote-desktop":
            return connectionManager.connectionTitle
        case "audio-stream":
            return audioManager.connectionTitle
        #if os(visionOS)
        case "mac-native-stream", "mac-native-unity-controls":
            return macNativeManager.title
        #endif
        #if MOONLIGHT_ENABLED
        case "moonlight-stream":
            let hosts = moonlightSessions.streamingSessions.compactMap { $0.serverInfo?.hostname }
            return hosts.isEmpty ? nil : hosts.joined(separator: ", ")
        #endif
        default:
            return nil
        }
    }
}
