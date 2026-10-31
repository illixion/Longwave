//  PCVRTrackersSection.swift
//
//  Aligning and assigning the PC's tracked devices, from the headset. It lives in the PCVR
//  control window because the person doing it is wearing the devices: they can see the
//  outline the immersive space draws on each one, which is the only honest check that an
//  alignment is right.
//
//  Shown only once the host has sent its tracker state (0x11), so a host without the
//  feature, or no host at all, never sees an empty card. Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI

/// Shows the section only once the host has spoken, without making the caller observe
/// the feed.
struct PCVRTrackersGate: View {
    let hub: TrackerHubModel

    var body: some View {
        if hub.hasHost { PCVRTrackersSection(hub: hub) }
    }
}

struct PCVRTrackersSection: View {
    let hub: TrackerHubModel
    @State private var showDevices = false

    var body: some View {
        // Observation reads happen in here, not in the parent: the control window above
        // is a big view and should not rebuild at the tracker feed's rate.
        VStack(alignment: .leading, spacing: 10) {
            header
            if let status = hub.alignment {
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(status.tone == .warning ? Color.orange : status.tone == .good ? Color.green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = hub.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .onTapGesture { hub.dismissError() }
            }
            controls
            if !hub.devices.isEmpty {
                DisclosureGroup(isExpanded: $showDevices) {
                    VStack(spacing: 8) {
                        ForEach(hub.devices) { device in
                            TrackerDeviceRow(device: device, hub: hub)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Devices (\(hub.devices.count))").font(.subheadline)
                }
            }
            Toggle(isOn: Bindable(hub).showAlways) {
                Label("Show tracked devices", systemImage: "cube.transparent")
                    .font(.subheadline)
            }
            Toggle(isOn: Binding(get: { hub.autoAlign }, set: { hub.setAutoAlign($0) })) {
                Label("Align automatically", systemImage: "wand.and.stars")
                    .font(.subheadline)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { hub.panelAppeared() }
        .onDisappear { hub.panelDisappeared() }
    }

    /// Liveness is not observed (the feed would rebuild this at 30 Hz), so a once-a-second
    /// timeline is what notices the host going quiet.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 8) {
                Image(systemName: "figure.walk.motion")
                    .foregroundStyle(hub.isLive() ? Color.accentColor : .secondary)
                Text("Trackers").font(.headline)
                Spacer()
                if !hub.isLive() {
                    Text("not reporting").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The primary button changes with the state: while it is collecting, the only useful
    /// thing is to stop; with everything aligned, the useful thing is to start over.
    private var controls: some View {
        HStack(spacing: 12) {
            switch hub.phase {
            case .collecting:
                Button { hub.alignStop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
            case .waiting:
                // Waiting is passive when it is automatic; a person who turned that off
                // asked for it, and can call it off.
                if !hub.autoAlign {
                    Button { hub.alignStop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .idle, .done:
                if hub.everythingAligned {
                    Button { hub.realign() } label: {
                        Label("Realign", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { hub.alignStart() } label: {
                        Label("Align trackers", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Button { hub.reset() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .help("Forget every alignment")
            .accessibilityLabel("Forget every alignment")
            Spacer()
        }
        .controlSize(.small)
    }
}

private struct TrackerDeviceRow: View {
    let device: ControllerBridgeTrackerDevice
    let hub: TrackerHubModel

    private var role: TrackerRole { TrackerRole(rawValue: device.role) ?? .none }

    private var icon: String {
        switch device.kind {
        case .touch: "gamecontroller"
        case .wand: "wand.and.rays"
        case .tracker: "circle.circle"
        case .other: "questionmark.square.dashed"
        }
    }

    /// One short line for the state; what matters is whether it can be drawn and used.
    private var stateText: String {
        if !device.isTracked { return "not seen" }
        if !device.isAligned { return "not aligned" }
        if device.flags.contains(.warm) { return "aligned last time" }
        if device.ownsHand >= 0 { return device.ownsHand == 0 ? "left hand" : "right hand" }
        return device.flags.contains(.held) ? "in a hand" : "aligned"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(device.isAligned && device.isTracked ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(TrackerNaming.name(for: device)).font(.subheadline)
                Text(stateText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if device.battery <= 100 {
                Text("\(device.battery)%").font(.caption2).foregroundStyle(.secondary)
            }
            // Movement, so "which one is this" is answered by picking it up.
            ProgressView(value: Double(min(max(device.speed, 0), 1.5)), total: 1.5)
                .frame(width: 44)
                .opacity(device.isTracked ? 1 : 0.3)
            Menu {
                Picker("Role", selection: Binding(
                    get: { role },
                    set: { hub.assign(device.key, role: $0) })) {
                    ForEach(TrackerRole.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Text(role.label).font(.caption).lineLimit(1)
                    .frame(minWidth: 80)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
#endif
