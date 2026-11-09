#if FOVEATED_ENABLED && os(visionOS)
import Foundation
import StreamWire
import SwiftUI

/// Something that shows the native (v3) PCVR stream on this headset: it opens
/// whatever space it draws in, makes the `PCVRV3Remote` with what it needs from
/// the stream (decoded pictures, or the encoded access units), produces the
/// head poses that go up the uplink, and says what the display runs at.
///
/// The built-in one is Shell A (CompositorServices, `PCVRShellPresenter`). A
/// build may carry another: a class named `presenterPluginClassName` that
/// conforms to `PCVRNativePresenterPlugin` is preferred when present, so a
/// presenter that can't ship with the app plugs in without the app naming it.
@MainActor
protocol PCVRNativePresenter: AnyObject {
    /// Shown in the PCVR tab ("Presented with ...").
    var displayName: String { get }
    /// Begins presenting `target`'s stream. `events` hears the remote once it
    /// exists, display-rate changes and the end of presentation.
    func start(target: PCVRV3Target, events: PCVRNativePresenterEvents) async throws
    /// Stops drawing and holds the stream; `resume` picks it up again.
    func pause() async
    func resume() async throws
    func stop() async
    /// The stream's frame-rate cap changed (millihertz, 0 = follow the display).
    /// A presenter that can make the display or its receiver run at that rate
    /// does, so frames meet refreshes evenly; one that can't ignores it.
    func frameRateCapChanged(_ millihertz: UInt32) async
}

extension PCVRNativePresenter {
    func frameRateCapChanged(_ millihertz: UInt32) async {}
}

/// What a presenter tells the session controller (`PCVRNativeSession`).
@MainActor
final class PCVRNativePresenterEvents {
    /// The run's v3 client, each time one starts.
    var remoteStarted: (PCVRV3Remote) -> Void = { _ in }
    /// The display's refresh changed, as the presenter knows it best.
    var displayChanged: (PCVRDisplayRate) -> Void = { _ in }
    /// Presentation ended on its own (the space closed, the system took it).
    var ended: (String?) -> Void = { _ in }
}

/// A presenter carried by the build rather than the app.
protocol PCVRNativePresenterPlugin: AnyObject {
    @MainActor static func makePresenter() -> (any PCVRNativePresenter)?
}

enum PCVRNativePresenters {
    /// The class a build's presenter plugin goes by.
    static let presenterPluginClassName = "LongwavePCVRPresenterPlugin"

    /// The plugin's presenter if the build carries one, else Shell A.
    @MainActor
    static func preferred(shell: PCVRShellSession) -> any PCVRNativePresenter {
        if let type = NSClassFromString(presenterPluginClassName) as? PCVRNativePresenterPlugin.Type,
           let presenter = type.makePresenter() {
            return presenter
        }
        return PCVRShellPresenter(shell: shell)
    }
}

/// The display rate from how often the presenter's pose producer ticks: one
/// pose per display frame, snapped to the rates a headset runs at. For a
/// presenter that has no better source.
struct PCVRDisplayRateEstimator {
    static let rates: [Double] = [60, 72, 90, 96, 100, 120]

    static func display(forPosesPerSecond rate: Double) -> Double? {
        guard rate > 0, let nearest = rates.min(by: { abs($0 - rate) < abs($1 - rate) }),
              abs(nearest - rate) <= nearest * 0.05 else { return nil }
        return nearest
    }
}

/// Shell A as a presenter: its CompositorServices space draws the decoded
/// stream, and its pose producer ticks once per display frame.
@MainActor
final class PCVRShellPresenter: PCVRNativePresenter {
    let shell: PCVRShellSession
    private var target: PCVRV3Target?
    private var events: PCVRNativePresenterEvents?
    private var rateTask: Task<Void, Never>?
    private var lastRate: Double?

    init(shell: PCVRShellSession) {
        self.shell = shell
    }

    var displayName: String { "Longwave's immersive renderer" }

    func start(target: PCVRV3Target, events: PCVRNativePresenterEvents) async throws {
        self.target = target
        self.events = events
        shell.v3Target = target
        shell.onRemoteStarted = { remote in events.remoteStarted(remote) }
        try await open()
        rateTask?.cancel()
        rateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleRate()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func open() async throws {
        guard let openSpace = shell.openSpace else { throw PCVRNativeSessionError.noSpaceControl }
        switch await openSpace() {
        case .opened: break
        case .userCancelled: throw PCVRNativeSessionError.cancelled
        case .error: throw PCVRNativeSessionError.spaceFailed
        @unknown default: throw PCVRNativeSessionError.spaceFailed
        }
    }

    private func sampleRate() {
        guard let status = shell.v3Status, let rate = PCVRDisplayRateEstimator.display(forPosesPerSecond: status.posesPerSecond),
              rate != lastRate else { return }
        lastRate = rate
        // Only what was measured: the rates a display can run differ by model
        // (the M5 Vision Pro reaches 120 Hz, the M2 stops at 100), and no API says.
        events?.displayChanged(PCVRDisplayRate(hertz: rate))
    }

    func pause() async {
        await shell.dismissSpace?()
    }

    func resume() async throws {
        try await open()
    }

    func stop() async {
        rateTask?.cancel()
        rateTask = nil
        shell.onRemoteStarted = nil
        await shell.dismissSpace?()
        shell.stop()
        shell.v3Target = nil
    }
}
#endif
