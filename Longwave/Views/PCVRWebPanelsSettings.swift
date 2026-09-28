//
//  PCVRWebPanelsSettings.swift
//  Longwave
//
//  The PCVR tab's list of pinned web panels: add Twitch chat for a channel or any
//  page, pick where it is pinned, how see-through it is, and switch it off or
//  remove it. Changes reach a running session on the next frame.
//
//  Gated behind FOVEATED_ENABLED.
//

#if FOVEATED_ENABLED
import SwiftUI

struct PCVRWebPanelsSettings: View {
    @State private var store = PCVRWebPanelStore.shared
    @State private var channel = ""
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pages pinned to a wrist or to a spot in your view while you play: Twitch chat on your wrist, say. They are view-only in a game. Use the Web panels buttons on the palm HUD to touch a page (to scroll or sign in) or to move and resize the panels, then Done on the panel. Pages share one sign-in, kept apart from the rest of Longwave.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(store.panels) { panel in
                row(panel)
                Divider()
            }

            HStack {
                TextField("Twitch channel", text: $channel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add chat") {
                    store.add(PCVRWebPanelConfig(address: PCVRWebPanelConfig.twitchChat(channel: channel)))
                    channel = ""
                }
                .disabled(channel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                TextField("Any web address", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Add page") {
                    store.add(PCVRWebPanelConfig(address: address, mount: .view))
                    address = ""
                }
                .disabled(PCVRWebPanelConfig(address: address).url == nil)
            }
        }
    }

    private func row(_ panel: PCVRWebPanelConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: binding(panel, \.enabled)) {
                    Text(panel.url?.host() ?? panel.address)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button(role: .destructive) {
                    store.remove(panel.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
            }
            Picker("Pinned to", selection: binding(panel, \.mount)) {
                ForEach(PCVRWebPanelConfig.Mount.allCases) { mount in
                    Text(mount.label).tag(mount)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: binding(panel, \.opacity), in: 0.3...1)
            }
            .font(.caption)
            if panel.offset != nil {
                Button("Reset position") {
                    var reset = panel
                    reset.offset = nil
                    store.update(reset)
                }
                .font(.caption)
            }
        }
    }

    private func binding<Value>(_ panel: PCVRWebPanelConfig,
                                _ keyPath: WritableKeyPath<PCVRWebPanelConfig, Value>) -> Binding<Value> {
        Binding {
            store.panels.first { $0.id == panel.id }?[keyPath: keyPath] ?? panel[keyPath: keyPath]
        } set: { value in
            var changed = store.panels.first { $0.id == panel.id } ?? panel
            changed[keyPath: keyPath] = value
            // A moved panel's offset belongs to its old mount.
            if keyPath == \PCVRWebPanelConfig.mount { changed.offset = nil }
            store.update(changed)
        }
    }
}
#endif
