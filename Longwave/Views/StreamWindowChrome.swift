#if os(visionOS)
import SwiftUI
import UIKit

/// The window chrome every visionOS remote-desktop window shares — VNC, the
/// Native desktop and Moonlight — so they look and behave as one app: a
/// `.plain` window with rounded corners, a controls ornament *below* the
/// window (over it, the bar hid the Dock or the Start menu), and in mouse
/// mode the picture as a padded tile above a connection strip.

// MARK: - Mouse-mode layout

/// In mouse mode the picture is one tile of a padded layout, the way Hypnos's
/// thumbnail grid is: dead space around it and between it and the strip,
/// which is what holds the system pointer on the tile instead of letting it
/// slide onto the window bar and corners. More (32pt outside, 44pt above the
/// strip) did not help: fast motion still reached the window bar, which
/// visionOS pulls the pointer onto by proximity. Diagonal pushes into a corner
/// can still escape; otherwise the pointer stops at the edges (headset,
/// 2026-10-08). That was on the curved Native desktop, whose curve leaves a
/// band of its own inside the pane. A flat picture fills its pane, and 16pt
/// let a fast mouse straight through onto the strip and the window bar
/// (Moonlight, headset, 2026-11-13), so the gaps are wider now.
enum StreamMouseLayout {
    static let inset: CGFloat = 32
    static let gap: CGFloat = 64
    static let stripHeight: CGFloat = 60
    static let paneCornerRadius: CGFloat = 20
    static let windowCornerRadius: CGFloat = 24

    /// What the layout adds around the picture's pane, for the aspect lock.
    static func extras(mouseOwnsPointer: Bool) -> CGSize {
        guard mouseOwnsPointer else { return .zero }
        return CGSize(width: 2 * inset, height: 2 * inset + gap + stripHeight)
    }
}

/// The picture's pane, with the connection strip under it in mouse mode.
struct StreamPane<Content: View, Strip: View>: View {
    let mouseOwnsPointer: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var strip: () -> Strip

    var body: some View {
        VStack(spacing: mouseOwnsPointer ? StreamMouseLayout.gap : 0) {
            content()
                .clipShape(RoundedRectangle(
                    cornerRadius: mouseOwnsPointer ? StreamMouseLayout.paneCornerRadius : 0,
                    style: .continuous
                ))
            if mouseOwnsPointer {
                strip()
            }
        }
        .padding(mouseOwnsPointer ? StreamMouseLayout.inset : 0)
    }
}

/// What streams, under the picture in mouse mode. Presses on it stay off the
/// remote while the pointer is here.
struct StreamConnectionStrip<Trailing: View>: View {
    let status: String
    let streamSize: CGSize
    let mouse: StreamMouseBridge
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 28) {
            Label(status, systemImage: "dot.radiowaves.left.and.right")
            if streamSize.width > 0 {
                Text("\(Int(streamSize.width)) × \(Int(streamSize.height))")
                    .monospacedDigit()
            }
            Spacer()
            trailing()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 32)
        .frame(height: StreamMouseLayout.stripHeight)
        .frame(maxWidth: .infinity)
        .glassBackgroundEffect()
        .onHover { mouse.pointerOverControls = $0 }
    }
}

// MARK: - Controls ornament

/// The Audio button: one button on every desktop, doing what audio means for
/// that connection — the Native desktop's audio stream and player, VNC's
/// companion player, muting a Moonlight stream.
struct StreamAudioButton {
    var isOn: Binding<Bool>
    var systemImage: String
    var disabled = false
    var help: String
    /// Shown from the button while it's on (VNC's player).
    var popover: AnyView?
}

/// The controls under every stream window, in one order:
/// Connections · [Screen] · Direct/Touchpad · Right-click · Mouse · Display ·
/// Keyboard · Audio · Disconnect.
/// A button a connection can't use is left out, never moved. Display and
/// Audio are shared buttons whose content is the connection's own: Native's
/// desktop and curve, or Moonlight's stats and spatial audio, behind the one
/// Display popover. The pointer group shows only while there's a picture.
struct StreamControlsBar<Screen: View, Display: View>: View {
    let target: any RemotePointerTarget
    let mouse: StreamMouseBridge
    var showsPointerControls = true
    let keyboardOpen: Bool
    let toggleKeyboard: () -> Void
    var audio: StreamAudioButton?
    let disconnect: () -> Void
    @ViewBuilder var screen: () -> Screen
    /// Display popover content; `EmptyView` leaves the button out.
    @ViewBuilder var display: () -> Display

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 12) {
            Button {
                WindowSessionRegistry.surface("main", using: openWindow)
            } label: {
                Label("Connections", systemImage: "house")
            }
            .help("Open the connection manager")

            screen()

            if showsPointerControls {
                Button {
                    target.touchMode = target.touchMode == .absolute ? .relative : .absolute
                } label: {
                    Label(
                        target.touchMode == .absolute ? "Direct" : "Touchpad",
                        systemImage: target.touchMode == .absolute
                            ? "hand.tap" : "rectangle.and.hand.point.up.left"
                    )
                }

                Button {
                    target.pointerClick(.right)
                } label: {
                    Label("Right-click", systemImage: "cursorarrow.click.2")
                }

                if mouse.isConnected {
                    Toggle(isOn: Binding(
                        get: { mouse.captureEnabled },
                        set: { mouse.captureEnabled = $0 }
                    )) {
                        Label("Mouse", systemImage: "computermouse")
                    }
                    .toggleStyle(.button)
                    .help(mouse.captureEnabled
                        ? "The mouse controls the remote; hand gestures are off until you turn this off"
                        : "Use the mouse on the remote desktop")
                }

                if Display.self != EmptyView.self {
                    displayButton
                }
            }

            Button(action: toggleKeyboard) {
                Label("Keyboard", systemImage: keyboardOpen ? "keyboard.fill" : "keyboard")
            }
            .tint(keyboardOpen ? .accentColor : nil)

            if let audio {
                audioButton(audio)
            }

            Button(action: disconnect) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
        .glassBackgroundEffect()
        .onHover { mouse.pointerOverControls = $0 }
    }

    /// A popover rather than a menu: a popover's open state is ours to know,
    /// and the mouse hit target has to stand aside, and presses be held back,
    /// for exactly as long as it shows. A menu offers no such signal.
    private var displayButton: some View {
        Button {
            mouse.menuOpen.toggle()
        } label: {
            Label("Display", systemImage: "display.2")
        }
        .help("How the stream is shown")
        .popover(isPresented: Binding(
            get: { mouse.menuOpen },
            set: { mouse.menuOpen = $0 }
        ), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 16) {
                display()
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    @ViewBuilder
    private func audioButton(_ audio: StreamAudioButton) -> some View {
        let toggle = Toggle(isOn: audio.isOn) {
            Label("Audio", systemImage: audio.systemImage)
        }
        .toggleStyle(.button)
        .disabled(audio.disabled)
        .help(audio.help)
        if let popover = audio.popover {
            toggle
                .popover(isPresented: audio.isOn, arrowEdge: .top) { popover }
                // The popover sits outside the bar, so its hover doesn't
                // cover it: hold the mouse back while it shows.
                .onChange(of: audio.isOn.wrappedValue) { _, open in mouse.menuOpen = open }
        } else {
            toggle
        }
    }
}

// MARK: - Badges

/// A small notice at the top of the picture: a held drag, latched modifiers,
/// input going elsewhere.
struct StreamBadge: View {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassBackgroundEffect()
            .padding(.top, 8)
    }
}

extension StreamBadge {
    /// Shown while a gaze drag lock holds the left button down.
    static var dragLock: StreamBadge {
        StreamBadge("Dragging — tap to drop", systemImage: "hand.draw")
    }
}

// MARK: - Aspect lock

/// Keeps the window resizable only into shapes the picture fills, so a stream
/// never sits in black bars (or, on a curve, runs its forward corners over the
/// ornament). In mouse mode the pane sits inside fixed padding and a strip, so
/// the window's aspect that puts the picture's own on the pane depends on the
/// width; a resize re-fits, so the drift between sizes settles.
struct StreamAspectLock: ViewModifier {
    /// The picture's aspect (width / height), or nil to leave the window free.
    let aspect: Double?
    /// The pane the picture fills, in points.
    let paneSize: CGSize
    /// What surrounds the pane (`StreamMouseLayout.extras`).
    let extras: CGSize

    @State private var windowScene: UIWindowScene?
    @State private var task: Task<Void, Never>?
    @State private var lockedAspect: Double?

    func body(content: Content) -> some View {
        content
            .background {
                WindowSceneReader { scene in
                    windowScene = scene
                    schedule()
                }
                .frame(width: 1, height: 1)
            }
            .onChange(of: aspect) { schedule() }
            .onChange(of: extras) { schedule() }
            // A curve's outline changes shape slightly as it grows; re-fit
            // once the resize settles.
            .onChange(of: paneSize) { schedule(after: .milliseconds(600)) }
            .onDisappear {
                task?.cancel()
                windowScene?.lockAspect(nil)
                lockedAspect = nil
            }
    }

    private func schedule(after delay: Duration = .zero) {
        task?.cancel()
        task = Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let windowScene else { return }
            guard let aspect, aspect > 0, paneSize.width > 0, paneSize.height > 0 else {
                if lockedAspect != nil {
                    windowScene.lockAspect(nil)
                    lockedAspect = nil
                }
                return
            }
            let windowWidth = paneSize.width + extras.width
            let target = windowWidth / (paneSize.width / aspect + extras.height)
            // Within 1% of both the lock and the window is close enough;
            // re-requesting would only jitter.
            let windowAspect = windowWidth / (paneSize.height + extras.height)
            if let lockedAspect, abs(lockedAspect - target) / target < 0.01,
               abs(windowAspect - target) / target < 0.01 { return }
            windowScene.lockAspect(target)
            lockedAspect = target
        }
    }
}

extension View {
    func streamAspectLock(_ aspect: Double?, paneSize: CGSize, mouseOwnsPointer: Bool) -> some View {
        modifier(StreamAspectLock(
            aspect: aspect,
            paneSize: paneSize,
            extras: StreamMouseLayout.extras(mouseOwnsPointer: mouseOwnsPointer)
        ))
    }
}
#endif
