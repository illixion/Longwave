import SwiftUI
import AppKit
import RoyalVNCKit

/// macOS VNC session window. Displays the framebuffer and forwards real mouse +
/// keyboard `NSEvent`s (via `MacInputSurface`) to the shared
/// `VNCConnectionManager`. Always absolute pointing — a Mac has a real pointer,
/// so the visionOS gaze "trackpad" / drag-lock modes aren't needed.
struct MacRemoteDesktopView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewSize: CGSize = .zero
    @State private var leftDown = false
    @State private var scrollAccumY: CGFloat = 0
    @State private var scrollAccumX: CGFloat = 0
    @State private var lastFB: (x: UInt16, y: UInt16) = (0, 0)
    @State private var showAudioPanel = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                ZStack {
                    if let cgImage = connectionManager.framebufferImage {
                        Image(decorative: cgImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        statusView
                    }

                    MacInputSurface(
                        onMouseMove: handleMove,
                        onMouseDown: handleDown,
                        onMouseUp: handleUp,
                        onScroll: handleScroll,
                        onKeyDown: handleKeyDown,
                        onKeyUp: handleKeyUp,
                        onFlagsChanged: handleFlags,
                        hideCursorWhenInside: connectionManager.hideLocalCursor
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear { viewSize = geo.size }
                .onChange(of: geo.size) { _, s in viewSize = s }
            }
        }
        .navigationTitle(connectionManager.connectionTitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: Bindable(connectionManager).isCredentialPromptPresented) {
            CredentialPromptView()
        }
        .onDisappear {
            dismissWindow(id: "keyboard")
            if connectionManager.connectionState.isActive { connectionManager.disconnect() }
        }
        .onChange(of: connectionManager.connectionState) { _, newValue in
            if case .disconnected = newValue {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    dismissWindow(id: "keyboard")
                    dismissWindow(id: "remote-desktop")
                }
            }
        }
    }

    // MARK: - Status

    private var statusView: some View {
        VStack(spacing: 20) {
            if case .disconnected(let error) = connectionManager.connectionState {
                Image(systemName: "xmark.circle").font(.system(size: 48)).foregroundStyle(.red)
                Text(error ?? "Disconnected").font(.headline)
                Button("Close") { dismissWindow(id: "remote-desktop") }
            } else {
                ProgressView().controlSize(.large)
                Text(connectionManager.connectionState.statusText).font(.headline)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { openWindow(id: "keyboard") } label: {
                Label("Keyboard", systemImage: "keyboard")
            }
            if connectionManager.hasCompanionAudio {
                Button { showAudioPanel.toggle() } label: {
                    Label("Audio", systemImage: audioManager.state == .streaming ? "speaker.wave.2.fill" : "speaker.wave.2")
                }
                .popover(isPresented: $showAudioPanel, arrowEdge: .bottom) {
                    AudioPlayerPanel(width: 360, showsVolume: true)
                        .padding(.vertical, 8)
                        .environment(audioManager)
                }
            }
            Button(action: sendCtrlAltDel) {
                Label("Ctrl+Alt+Del", systemImage: "power")
            }
            Button(role: .destructive) {
                connectionManager.disconnect()
                dismissWindow(id: "keyboard")
                dismissWindow(id: "remote-desktop")
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - Coordinate mapping

    private var translator: GestureTranslator? {
        guard connectionManager.framebufferSize.width > 0, viewSize.width > 0 else { return nil }
        return GestureTranslator(
            framebufferSize: connectionManager.framebufferSize,
            viewSize: viewSize,
            trackpadOnly: false
        )
    }

    // MARK: - Mouse

    private func handleMove(_ p: CGPoint) {
        guard let fb = translator?.viewToFramebuffer(p) else { return }
        lastFB = (fb.x, fb.y)
        if leftDown {
            connectionManager.sendMouseMove(x: fb.x, y: fb.y)
        } else {
            connectionManager.moveCursorAbsolute(x: fb.x, y: fb.y)
        }
    }

    private func handleDown(_ button: Int, _ p: CGPoint) {
        guard let fb = translator?.viewToFramebuffer(p) else { return }
        lastFB = (fb.x, fb.y)
        let b = vncButton(button)
        if b == .left { leftDown = true }
        connectionManager.sendMouseDown(button: b, x: fb.x, y: fb.y)
    }

    private func handleUp(_ button: Int, _ p: CGPoint) {
        guard let fb = translator?.viewToFramebuffer(p) else { return }
        lastFB = (fb.x, fb.y)
        let b = vncButton(button)
        if b == .left { leftDown = false }
        connectionManager.sendMouseUp(button: b, x: fb.x, y: fb.y)
    }

    private func vncButton(_ i: Int) -> VNCMouseButton {
        switch i { case 1: return .right; case 2: return .middle; default: return .left }
    }

    /// Accumulate scroll deltas and emit one wheel step per threshold crossed,
    /// so a trackpad's fine-grained deltas don't flood the server.
    private func handleScroll(_ dx: CGFloat, _ dy: CGFloat) {
        scrollAccumY += dy
        scrollAccumX += dx
        let threshold: CGFloat = 6
        while abs(scrollAccumY) >= threshold {
            let up = scrollAccumY > 0
            connectionManager.sendScroll(wheel: up ? .up : .down, x: lastFB.x, y: lastFB.y, steps: 1)
            scrollAccumY += up ? -threshold : threshold
        }
        while abs(scrollAccumX) >= threshold {
            let right = scrollAccumX < 0   // natural: swipe left (negative) scrolls content right
            connectionManager.sendScroll(wheel: right ? .right : .left, x: lastFB.x, y: lastFB.y, steps: 1)
            scrollAccumX += right ? threshold : -threshold
        }
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: NSEvent) {
        if let vk = MacKeyMaps.vncKeyCode(for: event.keyCode) {
            connectionManager.sendKeyDown(vk)
        } else {
            for ch in (event.charactersIgnoringModifiers ?? "") {
                for kc in VNCKeyCode.withCharacter(ch) { connectionManager.sendKeyDown(kc) }
            }
        }
    }

    private func handleKeyUp(_ event: NSEvent) {
        if let vk = MacKeyMaps.vncKeyCode(for: event.keyCode) {
            connectionManager.sendKeyUp(vk)
        } else {
            for ch in (event.charactersIgnoringModifiers ?? "") {
                for kc in VNCKeyCode.withCharacter(ch) { connectionManager.sendKeyUp(kc) }
            }
        }
    }

    private func handleFlags(_ event: NSEvent) {
        guard let vk = MacKeyMaps.vncKeyCode(for: event.keyCode),
              let flag = MacKeyMaps.modifierFlag(for: event.keyCode) else { return }
        if event.modifierFlags.contains(flag) {
            connectionManager.sendKeyDown(vk)
        } else {
            connectionManager.sendKeyUp(vk)
        }
    }

    private func sendCtrlAltDel() {
        connectionManager.sendKeyDown(.control)
        connectionManager.sendKeyDown(.option)
        connectionManager.sendKeyDown(.forwardDelete)
        connectionManager.sendKeyUp(.forwardDelete)
        connectionManager.sendKeyUp(.option)
        connectionManager.sendKeyUp(.control)
    }
}
