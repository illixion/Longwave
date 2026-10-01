import AppKit
import SwiftUI

/// Walks the user through granting Full Disk Access, which macOS offers no API
/// or prompt for: an app only appears in that list once the user adds it. So
/// this opens the pane and floats a small panel beside it holding the app's own
/// icon, which drags straight into the list — no hunting for the bundle in
/// Finder. The grant only applies to processes started afterwards, hence the
/// Relaunch button.
@MainActor
final class FullDiskAccessAssistant {
    static let shared = FullDiskAccessAssistant()

    private var panel: NSPanel?

    func show() {
        NSWorkspace.shared.open(LocalSandbox.fullDiskAccessSettingsURL)
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Full Disk Access"
        panel.isFloatingPanel = true
        panel.level = .floating
        // System Settings takes focus when it opens; the panel has to stay up
        // beside it for the drag.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FullDiskAccessPanelView(
            relaunch: { LocalSandboxController.relaunchApp() },
            close: { [weak self] in self?.close() }))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 320, y: screen.maxY - 40))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct FullDiskAccessPanelView: View {
    let relaunch: () -> Void
    let close: () -> Void

    private let appURL = Bundle.main.bundleURL
    private var appName: String {
        FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .frame(width: 64, height: 64)
                .onDrag { NSItemProvider(object: appURL as NSURL) }
                .help("Drag into the Full Disk Access list")
            Text("Drag \(appName) into the Full Disk Access list, then switch it on.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS applies the grant when the app next starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Close", action: close)
                Button("Relaunch \(appName)", action: relaunch)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
