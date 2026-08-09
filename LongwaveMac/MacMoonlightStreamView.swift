#if MOONLIGHT_ENABLED
import SwiftUI
import AppKit
@preconcurrency import MoonlightCommonC

/// macOS Moonlight session window. Hosts the video layer and forwards real
/// mouse + keyboard `NSEvent`s straight to moonlight-common-c (`LiSend*`),
/// mirroring the visionOS gesture handlers. Absolute pointing by default.
struct MacMoonlightStreamView: View {
    @Environment(MoonlightConnectionManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var viewSize: CGSize = .zero
    @State private var modifiers: Int8 = 0
    @State private var scrollAccum: CGFloat = 0
    @State private var showStats = false
    @State private var showDisconnectAlert = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let layer = manager.displayLayer {
                GeometryReader { geo in
                    ZStack {
                        MacVideoLayerView(displayLayer: layer)
                        MacInputSurface(
                            onMouseMove: { handleMove($0, in: geo.size) },
                            onMouseDown: { b, p in handleButton(b, p, in: geo.size, press: true) },
                            onMouseUp: { b, p in handleButton(b, p, in: geo.size, press: false) },
                            onScroll: handleScroll,
                            onKeyDown: handleKeyDown,
                            onKeyUp: handleKeyUp,
                            onFlagsChanged: handleFlags,
                            hideCursorWhenInside: manager.hideLocalCursor
                        )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { viewSize = geo.size }
                    .onChange(of: geo.size) { _, s in viewSize = s }
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text(manager.statusMessage).foregroundStyle(.secondary)
                }
            }

            if showStats { StreamStatsOverlay().environment(manager) }
        }
        .navigationTitle("Moonlight")
        .toolbar { toolbarContent }
        .onDisappear {
            manager.stopStreaming()
            dismissWindow(id: "moonlight-keyboard")
        }
        .alert("Disconnect", isPresented: $showDisconnectAlert) {
            Button("Keep Running") {
                manager.stopStreaming()
                dismissWindow(id: "moonlight-keyboard")
                dismissWindow(id: "moonlight-stream")
            }
            Button("End Session", role: .destructive) {
                manager.stopStreamingAndQuit()
                dismissWindow(id: "moonlight-keyboard")
                dismissWindow(id: "moonlight-stream")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you want to end the session on the server, or keep it running for later?")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            // No touch-mode toggle on macOS — a Mac always uses absolute pointing.
            Button { openWindow(id: "moonlight-keyboard") } label: {
                Label("Keyboard", systemImage: "keyboard")
            }
            Button { showStats.toggle() } label: {
                Label("Stats", systemImage: "chart.bar")
            }
            Button(role: .destructive) { showDisconnectAlert = true } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
            }
        }
    }

    // MARK: - Mouse

    @State private var lastMove: CGPoint = .zero

    private func handleMove(_ p: CGPoint, in size: CGSize) {
        if manager.touchMode == .absolute {
            let (x, y) = mapToStream(p, in: size)
            LiSendMousePositionEvent(x, y, Int16(manager.streamWidth), Int16(manager.streamHeight))
        } else {
            let dx = p.x - lastMove.x
            let dy = p.y - lastMove.y
            LiSendMouseMoveEvent(Int16(dx), Int16(dy))
        }
        lastMove = p
    }

    private func handleButton(_ button: Int, _ p: CGPoint, in size: CGSize, press: Bool) {
        if manager.touchMode == .absolute {
            let (x, y) = mapToStream(p, in: size)
            LiSendMousePositionEvent(x, y, Int16(manager.streamWidth), Int16(manager.streamHeight))
        }
        let action = Int8(press ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE)
        let b: Int32
        switch button { case 1: b = BUTTON_RIGHT; case 2: b = BUTTON_MIDDLE; default: b = BUTTON_LEFT }
        LiSendMouseButtonEvent(action, b)
    }

    private func handleScroll(_ dx: CGFloat, _ dy: CGFloat) {
        scrollAccum += dy
        let threshold: CGFloat = 4
        while abs(scrollAccum) >= threshold {
            let up = scrollAccum > 0
            LiSendHighResScrollEvent(Int16(up ? 120 : -120))
            scrollAccum += up ? -threshold : threshold
        }
    }

    private func mapToStream(_ point: CGPoint, in viewSize: CGSize) -> (Int16, Int16) {
        let streamW = CGFloat(manager.streamWidth)
        let streamH = CGFloat(manager.streamHeight)
        guard streamW > 0, streamH > 0, viewSize.width > 0, viewSize.height > 0 else { return (0, 0) }
        let streamAspect = streamW / streamH
        let viewAspect = viewSize.width / viewSize.height

        let renderRect: CGRect
        if viewAspect > streamAspect {
            let h = viewSize.height
            let w = h * streamAspect
            renderRect = CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: h)
        } else {
            let w = viewSize.width
            let h = w / streamAspect
            renderRect = CGRect(x: 0, y: (viewSize.height - h) / 2, width: w, height: h)
        }
        let cx = min(max(point.x, renderRect.minX), renderRect.maxX)
        let cy = min(max(point.y, renderRect.minY), renderRect.maxY)
        let nx = (cx - renderRect.minX) / renderRect.width
        let ny = (cy - renderRect.minY) / renderRect.height
        return (Int16(nx * streamW), Int16(ny * streamH))
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: NSEvent) {
        sendKey(event, down: true)
    }

    private func handleKeyUp(_ event: NSEvent) {
        sendKey(event, down: false)
    }

    private func sendKey(_ event: NSEvent, down: Bool) {
        let action = Int8(down ? KEY_ACTION_DOWN : KEY_ACTION_UP)
        if let vk = MacKeyMaps.windowsKeyCode(for: event.keyCode) {
            LiSendKeyboardEvent(vk, action, modifiers)
        } else if let ch = event.charactersIgnoringModifiers?.first,
                  let vk = MoonlightKeyCodes.windowsKeyCode(for: ch) {
            LiSendKeyboardEvent(vk, action, modifiers)
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let kc = event.keyCode
        let modBit = MacKeyMaps.moonlightModifierFlag(for: kc)
        guard let flag = MacKeyMaps.modifierFlag(for: kc),
              let vk = MacKeyMaps.windowsKeyCode(for: kc) else { return }
        let isDown = event.modifierFlags.contains(flag)
        if isDown && modBit != 0 { modifiers |= modBit }
        LiSendKeyboardEvent(vk, Int8(isDown ? KEY_ACTION_DOWN : KEY_ACTION_UP), modifiers)
        if !isDown && modBit != 0 { modifiers &= ~modBit }
    }
}
#endif
