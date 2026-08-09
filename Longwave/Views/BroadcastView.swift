import SwiftUI
import AVFoundation
import ReplayKit

/// Broadcast tab: stream a visionOS camera (Persona / Mirror My View) plus
/// the mic to a mediamtx RTSP server, for OBS / video-call capture on the
/// receiving computer. The stream survives tab switches (the manager is
/// app-scoped) but not app backgrounding — visionOS pauses capture when
/// the app loses visibility.
struct BroadcastView: View {
    @Environment(BroadcastManager.self) private var manager
    @State private var pickerProxy = BroadcastPickerProxy()

    var body: some View {
        @Bindable var manager = manager
        NavigationStack {
            // Two panes: live panel (preview + actions) left, settings right —
            // everything visible without scrolling.
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    BroadcastPreview(target: manager.previewTarget)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            if !manager.isActive {
                                Label("Preview starts with the broadcast", systemImage: "video.slash")
                                    .foregroundStyle(.secondary)
                            }
                        }

                    statusRow
                        .font(.callout)

                    Button {
                        if manager.isActive {
                            manager.stop()
                        } else {
                            Task { await manager.start() }
                        }
                    } label: {
                        Label(manager.isActive ? "Stop Broadcast" : "Start Broadcast",
                              systemImage: manager.isActive ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(manager.isActive ? .red : .accentColor)

                    Text("Camera capture pauses if Longwave leaves the foreground.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    HStack {
                        Label("Mirror My View", systemImage: "eye")
                        Spacer()
                        if manager.viewSharingActive {
                            Label("Live", systemImage: "record.circle")
                                .foregroundStyle(.red)
                        } else {
                            Text("Off")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)

                    Button {
                        pickerProxy.present()
                    } label: {
                        Label(manager.viewSharingActive ? "Stop View Sharing…" : "Start View Sharing…",
                              systemImage: "shared.with.you")
                            .frame(maxWidth: .infinity)
                    }
                    .background {
                        BroadcastPickerHost(proxy: pickerProxy)
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
                    }

                    Text("Streams everything you see — select \"Longwave View\" in the system dialog. Keeps running while the app is in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .frame(width: 400)
                .padding(.top, 18)

                Form {
                    Section("Source") {
                        Picker("Camera", selection: $manager.selectedCameraID) {
                            ForEach(manager.cameras) { camera in
                                Text(camera.name).tag(Optional(camera.id))
                            }
                        }
                        Toggle("Microphone", isOn: $manager.micEnabled)
                        Picker("Video bitrate", selection: $manager.bitrateMbps) {
                            ForEach([5, 10, 15, 20], id: \.self) { Text("\($0) Mbps").tag($0) }
                        }
                    }
                    .disabled(manager.isActive)

                    Section {
                        TextField("Host", text: $manager.host, prompt: Text("100.x.x.x or hostname"))
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Port", value: $manager.port, format: .number.grouping(.never))
                        TextField("Stream path", text: $manager.streamPath)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("View stream path", text: $manager.viewStreamPath)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("Username", text: $manager.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $manager.password)
                        LabeledContent("Encryption") {
                            Label(manager.certFingerprint.isEmpty ? "None — use Tailscale/VPN" : "RTSPS, pinned certificate",
                                  systemImage: manager.certFingerprint.isEmpty ? "lock.open" : "lock.fill")
                                .foregroundStyle(manager.certFingerprint.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                                .font(.callout)
                        }
                    } header: {
                        Text("Server (mediamtx over RTSP)")
                    } footer: {
                        Text("Easiest setup: press \"Set Up Broadcast Server\" in the Mac companion, then AirDrop the pairing link — it fills all of this in, including the encryption certificate.")
                    }
                    .disabled(manager.isActive)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .padding(.horizontal, 24)
            .navigationTitle("Broadcast")
        }
        .task {
            if manager.cameras.isEmpty { manager.refreshCameras() }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch manager.state {
        case .idle:
            Label("Idle", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .starting:
            Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .broadcasting:
            HStack {
                Label("Live", systemImage: "record.circle")
                    .foregroundStyle(.red)
                Spacer()
                Text("\(manager.statsFPS) fps · \(manager.statsKbps.formatted()) kbps" +
                     (manager.audioActive ? " · mic" : ""))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// Forwards a SwiftUI button tap to the system broadcast picker's internal
/// UIButton. RPSystemBroadcastPickerView only exposes a bare icon button
/// (near-invisible on visionOS glass), so the picker is hosted offscreen and
/// a regular labeled button drives it.
@MainActor
final class BroadcastPickerProxy {
    fileprivate weak var picker: RPSystemBroadcastPickerView?

    func present() {
        guard let picker else { return }
        let button = picker.subviews.lazy.compactMap { $0 as? UIButton }.first
        button?.sendActions(for: .touchUpInside)
    }
}

private struct BroadcastPickerHost: UIViewRepresentable {
    let proxy: BroadcastPickerProxy

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = BroadcastShared.extensionBundleID
        picker.showsMicrophoneButton = true
        // Kept in the hierarchy (required for the tap forward to work) but
        // visually hidden behind the SwiftUI button.
        picker.alpha = 0.02
        proxy.picker = picker
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        proxy.picker = uiView
    }
}

/// Live broadcast preview: an `AVSampleBufferDisplayLayer` that
/// `BroadcastPreviewTarget` feeds raw capture frames into (visionOS has no
/// `AVCaptureVideoPreviewLayer`).
private struct BroadcastPreview: UIViewRepresentable {
    let target: BroadcastPreviewTarget

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.displayLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        target.layer = uiView.displayLayer
    }
}
