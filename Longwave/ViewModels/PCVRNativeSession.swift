#if FOVEATED_ENABLED && os(visionOS)
import DebugTrace
import Foundation
import Observation
import StreamWire
import os
import RAVECompanion

enum PCVRNativeSessionError: LocalizedError {
    case noCompanion
    case noSpaceControl
    case cancelled
    case spaceFailed

    var errorDescription: String? {
        switch self {
        case .noCompanion: "Pair this headset with the PC's Companion first (Connections → Native)."
        case .noSpaceControl: "The immersive space isn't ready yet; try again."
        case .cancelled: "Opening the immersive space was cancelled."
        case .spaceFailed: "The immersive space couldn't open."
        }
    }
}

/// The native (v3) PCVR session the PCVR tab runs: one presenter (Shell A, or a
/// build's presenter plugin), the wearer's quality and frame-rate presets, the
/// display rate reported as visionOS changes it, and the PC's controller and
/// library bridge found through the stream. Mode-neutral state for the tab:
/// nothing here knows which presenter draws.
@MainActor
@Observable
final class PCVRNativeSession {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        case paused
        case failed(String)
    }

    private(set) var state: State = .idle
    /// What the host settled on, for the tab.
    private(set) var hostSession: PCVRSessionState?
    private(set) var display: PCVRDisplayRate?
    private(set) var presenterName: String?
    private(set) var controllerBridge: ControllerBridgeSender?

    var quality: PCVRQualityPreset {
        didSet {
            UserDefaults.standard.set(Int(quality.rawValue), forKey: Self.qualityKey)
            sendPreferences()
        }
    }
    var frameRate: PCVRFrameRatePreset {
        didSet {
            UserDefaults.standard.set(Int(frameRate.rawValue), forKey: Self.frameRateKey)
            sendPreferences()
        }
    }

    static let qualityKey = "pcvr.native.quality"
    static let frameRateKey = "pcvr.native.frameRate"

    /// The library the PCVR tab shows (the CloudXR manager's, so both modes share it).
    @ObservationIgnored private(set) var gameLibrary: FoveatedGameLibrary?
    @ObservationIgnored private var presenter: (any PCVRNativePresenter)?
    @ObservationIgnored private weak var remote: PCVRV3Remote?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var bridgeHost: String?
    private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRNative")

    init() {
        let defaults = UserDefaults.standard
        quality = PCVRQualityPreset(rawValue: UInt8(clamping: defaults.integer(forKey: Self.qualityKey))) ?? .quality
        frameRate = PCVRFrameRatePreset(rawValue: UInt8(clamping: defaults.integer(forKey: Self.frameRateKey))) ?? .matchDisplay
    }

    var preferences: PCVRPreferences { PCVRPreferences(quality: quality, frameRate: frameRate) }

    var isActive: Bool {
        switch state {
        case .connecting, .streaming, .paused: true
        case .idle, .failed: false
        }
    }

    // MARK: Lifecycle

    func start(target: PCVRV3Target, shell: PCVRShellSession, gameLibrary: FoveatedGameLibrary) async {
        guard !isActive else { return }
        state = .connecting
        self.gameLibrary = gameLibrary
        let presenter = PCVRNativePresenters.preferred(shell: shell)
        self.presenter = presenter
        presenterName = presenter.displayName
        bridgeHost = target.host
        let events = PCVRNativePresenterEvents()
        events.remoteStarted = { [weak self] remote in self?.adopt(remote) }
        events.displayChanged = { [weak self] rate in self?.displayChanged(rate) }
        events.ended = { [weak self] reason in
            Task { @MainActor in await self?.presenterEnded(reason) }
        }
        do {
            try await presenter.start(target: target, events: events)
            state = .streaming
            log.notice("native PCVR session started (\(presenter.displayName, privacy: .public))")
        } catch {
            await presenter.stop()
            self.presenter = nil
            state = .failed(error.localizedDescription)
            log.error("native PCVR session could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func pause() async {
        guard state == .streaming, let presenter else { return }
        await presenter.pause()
        state = .paused
    }

    func resume() async {
        guard state == .paused, let presenter else { return }
        do {
            try await presenter.resume()
            state = .streaming
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        statusTask?.cancel()
        statusTask = nil
        stopControllerBridge()
        await presenter?.stop()
        presenter = nil
        remote = nil
        hostSession = nil
        presenterName = nil
        state = .idle
    }

    private func presenterEnded(_ reason: String?) async {
        guard isActive else { return }
        await stop()
        if let reason { state = .failed(reason) }
    }

    // MARK: The stream

    private func adopt(_ remote: PCVRV3Remote) {
        self.remote = remote
        remote.setPreferences(preferences)
        if let display { remote.setDisplay(display) }
        remote.onInputBridge = { [weak self] bytes in
            Task { @MainActor in self?.inputBridgeArrived(bytes) }
        }
        statusTask?.cancel()
        statusTask = Task { [weak self, weak remote] in
            while !Task.isCancelled, let remote {
                let session = remote.status.withLock { $0.hostSession }
                if self?.hostSession != session { self?.hostSession = session }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func displayChanged(_ rate: PCVRDisplayRate) {
        guard rate != display else { return }
        display = rate
        remote?.setDisplay(rate)
        log.notice("display \(rate.hertz, privacy: .public) Hz reported to the PC")
    }

    private func sendPreferences() {
        remote?.setPreferences(preferences)
    }

    // MARK: Controller and library bridge

    /// The PC's rendezvous arrived (or changed) in the stream: adopt it, which
    /// opens the sealed input link and the library's control stream.
    private func inputBridgeArrived(_ bytes: Data) {
        guard let rendezvous = ControllerBridgeRendezvous(bytes) else {
            log.notice("input-bridge rendezvous unreadable (\(bytes.count, privacy: .public) bytes)")
            return
        }
        if controllerBridge == nil {
            let bridge = ControllerBridgeSender(host: bridgeHost ?? "")
            bridge.start()
            gameLibrary?.attach(to: bridge)
            controllerBridge = bridge
            log.notice("controller and library bridge started from the stream's rendezvous")
        }
        controllerBridge?.adopt(rendezvous: rendezvous)
    }

    private func stopControllerBridge() {
        gameLibrary?.detach()
        controllerBridge?.stop()
        controllerBridge = nil
    }

    // MARK: Finding the PC

    /// The PCVR tab's PC with the credential from pairing with its Companion:
    /// the paired Native connection at the tab's address, else the first one.
    static func target(pcvrHost: String, connections: [SavedConnection]) throws -> PCVRV3Target {
        let companions = connections.filter { $0.connectionType == .native && $0.companionCredential?.deviceID != nil }
        guard let companion = companions.first(where: { !pcvrHost.isEmpty && $0.hostname == pcvrHost }) ?? companions.first,
              let credential = companion.companionCredential else { throw PCVRNativeSessionError.noCompanion }
        let host = pcvrHost.isEmpty ? companion.hostname : pcvrHost
        return PCVRV3Target(host: host, credential: credential, deviceName: DeviceName.current)
    }
}
#endif
