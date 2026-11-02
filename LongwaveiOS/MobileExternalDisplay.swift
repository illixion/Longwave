import AVFoundation
import SwiftUI
import UIKit

/// Shared app state for the supplementary HDMI scene. The tablet remains the
/// only input surface; this scene only renders the active desktop or stream.
@MainActor
@Observable
final class MobileExternalDisplayContext {
    static var current: MobileExternalDisplayContext?

    let connectionManager: VNCConnectionManager
    let nativeSessions: MacNativeSessionStore
    #if MOONLIGHT_ENABLED
    let moonlightSessions: MoonlightSessionStore
    #endif

    #if MOONLIGHT_ENABLED
    init(connectionManager: VNCConnectionManager, nativeSessions: MacNativeSessionStore, moonlightSessions: MoonlightSessionStore) {
        self.connectionManager = connectionManager
        self.nativeSessions = nativeSessions
        self.moonlightSessions = moonlightSessions
    }
    #else
    init(connectionManager: VNCConnectionManager, nativeSessions: MacNativeSessionStore) {
        self.connectionManager = connectionManager
        self.nativeSessions = nativeSessions
    }
    #endif
}

struct MobileExternalDisplayAccessoryHost: UIViewControllerRepresentable {
    let context: MobileExternalDisplayContext

    func makeUIViewController(context: Context) -> MobileExternalDisplayAccessoryController {
        MobileExternalDisplayContext.current = self.context
        return MobileExternalDisplayAccessoryController(displayContext: self.context)
    }

    func updateUIViewController(_ controller: MobileExternalDisplayAccessoryController, context: Context) {
        controller.displayContext = self.context
        MobileExternalDisplayContext.current = self.context
    }
}

@MainActor
final class MobileExternalDisplayAccessoryController: UIViewController {
    var displayContext: MobileExternalDisplayContext
    private var registration: AnyObject?

    init(displayContext: MobileExternalDisplayContext) {
        self.displayContext = displayContext
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard #available(iOS 27.0, *), registration == nil else { return }
        let configuration = UISceneConfiguration()
        configuration.delegateClass = MobileExternalDisplaySceneDelegate.self
        let accessory = UISceneAccessory.externalNonInteractive(
            sceneConfiguration: configuration,
            userInfo: displayContext
        )
        registration = registerSceneAccessory(accessory)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard #available(iOS 27.0, *), let registration = registration as? UISceneAccessoryRegistration else { return }
        unregisterSceneAccessory(registration)
        self.registration = nil
    }
}

@MainActor
final class MobileExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let context: MobileExternalDisplayContext?
        if #available(iOS 27.0, *) {
            context = options.sceneAccessoryUserInfo as? MobileExternalDisplayContext
                ?? MobileExternalDisplayContext.current
        } else {
            context = MobileExternalDisplayContext.current
        }
        guard let context else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MobileExternalDisplayView(context: context))
        self.window = window
        window.makeKeyAndVisible()
    }
}

private struct MobileExternalDisplayView: View {
    let context: MobileExternalDisplayContext

    var body: some View {
        activeDisplay
        .background(.black)
        .ignoresSafeArea()
        .statusBarHidden()
    }

    @ViewBuilder
    private var activeDisplay: some View {
        if let nativeID = context.nativeSessions.activeID,
           let native = context.nativeSessions.existingSession(for: nativeID),
           native.isEnabled {
            NativeExternalDesktopView(manager: native)
        } else {
            fallbackDisplay
        }
    }

    @ViewBuilder
    private var fallbackDisplay: some View {
        #if MOONLIGHT_ENABLED
        if let moonlight = context.moonlightSessions.activeSession {
            StreamExternalDesktopView(manager: moonlight, status: moonlight.statusMessage)
        } else {
            vncOrIdle
        }
        #else
        vncOrIdle
        #endif
    }

    @ViewBuilder
    private var vncOrIdle: some View {
        if context.connectionManager.connectionState.isActive || context.connectionManager.framebufferImage != nil {
            VNCExternalDesktopView(manager: context.connectionManager)
        } else {
            Color.black.overlay {
                VStack(spacing: 12) {
                    Image(systemName: "display")
                        .font(.system(size: 48))
                    Text("Connect to a desktop from Longwave on iPad")
                        .font(.headline)
                }
                .foregroundStyle(.white)
            }
        }
    }
}

private struct VNCExternalDesktopView: View {
    let manager: VNCConnectionManager

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image = manager.framebufferImage {
                    let rect = aspectFit(imageSize: CGSize(width: image.width, height: image.height), in: geometry.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    if manager.touchMode == .relative {
                        Circle()
                            .fill(.white)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.black, lineWidth: 2))
                            .position(
                                x: rect.minX + rect.width * CGFloat(manager.virtualCursorX) / CGFloat(max(1, image.width)),
                                y: rect.minY + rect.height * CGFloat(manager.virtualCursorY) / CGFloat(max(1, image.height))
                            )
                    }
                } else {
                    ProgressView(manager.connectionState.isActive ? "Waiting for desktop…" : manager.connectionState.statusText)
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

private struct NativeExternalDesktopView: View {
    let manager: MacNativeStreamManager
    @State private var mirrorLayer: AVSampleBufferDisplayLayer?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let layer = mirrorLayer, manager.streamSize.width > 0, manager.streamSize.height > 0 {
                    let rect = aspectFit(imageSize: manager.streamSize, in: geometry.size)
                    ExternalDisplayVideoLayer(displayLayer: layer)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    if manager.touchMode == .relative {
                        Circle()
                            .fill(.white.opacity(0.75))
                            .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1))
                            .frame(width: 16, height: 16)
                            .position(
                                x: rect.minX + rect.width * CGFloat(manager.virtualCursorX) / manager.streamSize.width,
                                y: rect.minY + rect.height * CGFloat(manager.virtualCursorY) / manager.streamSize.height
                            )
                    }
                } else {
                    ProgressView(manager.state == .connected ? "Waiting for the first frame…" : manager.state.statusText)
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
        }
        .onAppear { mirrorLayer = manager.makeExternalDisplayLayer() }
        .onDisappear {
            if let mirrorLayer { manager.removeExternalDisplayLayer(mirrorLayer) }
            mirrorLayer = nil
        }
    }
}

#if MOONLIGHT_ENABLED
private struct StreamExternalDesktopView: View {
    let manager: MoonlightConnectionManager
    let status: String
    @State private var mirrorLayer: AVSampleBufferDisplayLayer?

    var body: some View {
        GeometryReader { geometry in
            let streamSize = CGSize(width: manager.streamWidth, height: manager.streamHeight)
            let rect = aspectFit(imageSize: streamSize, in: geometry.size)
            ZStack {
                Color.black
                if let mirrorLayer {
                    ExternalDisplayVideoLayer(displayLayer: mirrorLayer)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                } else {
                    ProgressView(status)
                        .tint(.white)
                        .foregroundStyle(.white)
                }
                if manager.touchMode == .relative, streamSize.width > 0, streamSize.height > 0 {
                    Circle()
                        .fill(.white.opacity(0.85))
                        .overlay(Circle().stroke(.black.opacity(0.65), lineWidth: 1))
                        .frame(width: 16, height: 16)
                        .position(
                            x: rect.minX + rect.width * CGFloat(manager.virtualCursorX) / streamSize.width,
                            y: rect.minY + rect.height * CGFloat(manager.virtualCursorY) / streamSize.height
                        )
                }
            }
        }
        .onAppear { mirrorLayer = manager.makeExternalDisplayLayer() }
        .onDisappear {
            if let mirrorLayer { manager.removeExternalDisplayLayer(mirrorLayer) }
            mirrorLayer = nil
        }
    }
}
#endif

private struct ExternalDisplayVideoLayer: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> ExternalDisplayVideoLayerView {
        ExternalDisplayVideoLayerView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: ExternalDisplayVideoLayerView, context: Context) {}
}

private final class ExternalDisplayVideoLayerView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

private func aspectFit(imageSize: CGSize, in bounds: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
}
