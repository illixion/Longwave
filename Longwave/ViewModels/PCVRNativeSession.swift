#if FOVEATED_ENABLED && os(visionOS)
import DebugTrace
import AVFoundation
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
            UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey)
            sendPreferences()
        }
    }
    var frameRate: PCVRFrameRatePreset {
        didSet {
            UserDefaults.standard.set(frameRate.rawValue, forKey: Self.frameRateKey)
            sendPreferences()
        }
    }

    /// Eye-tracked or low latency (`PCVRNativePresenterChoice`). Changing it
    /// while streaming switches presenter at once.
    var presenterChoice: PCVRNativePresenterChoice = .stored {
        didSet {
            guard presenterChoice != oldValue else { return }
            UserDefaults.standard.set(presenterChoice.rawValue, forKey: PCVRNativePresenterChoice.defaultsKey)
            if isActive { Task { await switchPresenter() } }
        }
    }

    /// The headset's microphone to the PC (capability `microphone`), on by
    /// default as CloudXR's was: the PC plays it into a virtual cable that
    /// games choose as their microphone.
    var microphoneEnabled: Bool = UserDefaults.standard.object(forKey: PCVRNativeSession.microphoneKey) as? Bool ?? true {
        didSet {
            guard microphoneEnabled != oldValue else { return }
            UserDefaults.standard.set(microphoneEnabled, forKey: Self.microphoneKey)
            Task { await updateMicrophone() }
        }
    }
    /// Why the microphone isn't reaching the PC, when it isn't; nil when it is
    /// (or off by choice).
    private(set) var microphoneMessage: String?
    /// Whether the PC takes the microphone (it has a virtual cable to play it
    /// into), as the stream last said; nil before it has.
    private(set) var microphoneTakenByPC: Bool?
    static let microphoneKey = "pcvr.native.microphone"

    /// What the wearer can pick between in this build.
    var availableChoices: [PCVRNativePresenterChoice] { PCVRNativePresenters.availableChoices }

    static let qualityKey = "pcvr.native.quality"
    static let frameRateKey = "pcvr.native.frameRate"

    /// The library the PCVR tab shows (the CloudXR manager's, so both modes share it).
    @ObservationIgnored private(set) var gameLibrary: FoveatedGameLibrary?
    @ObservationIgnored private var presenter: (any PCVRNativePresenter)?
    @ObservationIgnored private weak var remote: PCVRV3Remote?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var bridgeHost: String?
    /// The running session's target and shell, to restart it with another presenter.
    @ObservationIgnored private var activeTarget: PCVRV3Target?
    @ObservationIgnored private weak var activeShell: PCVRShellSession?
    @ObservationIgnored private var isSwitching = false
    @ObservationIgnored private var microphone: MicrophoneUplink?
    /// The remote the running uplink feeds.
    @ObservationIgnored private weak var microphoneRemote: PCVRV3Remote?
    private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRNative")

    init() {
        let defaults = UserDefaults.standard
        quality = PCVRQualityPreset(rawValue: defaults.integer(forKey: Self.qualityKey)) ?? .quality
        frameRate = PCVRFrameRatePreset(rawValue: defaults.integer(forKey: Self.frameRateKey)) ?? .matchDisplay
        PCVRGuardianDriver.shared.nativeSession = self
    }

    /// The presets as sent: the frame-rate cap worked out for the display now.
    var preferences: PCVRPreferences {
        PCVRPlatformProfile.preferences(quality: quality, frameRate: frameRate, displayHertz: display?.hertz)
    }
    @ObservationIgnored private var appliedCap: UInt32?

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
        activeTarget = target
        activeShell = shell
        let presenter = PCVRNativePresenters.make(presenterChoice, shell: shell)
        self.presenter = presenter
        presenterName = presenter.displayName
        bridgeHost = target.host
        let events = PCVRNativePresenterEvents()
        events.remoteStarted = { [weak self] remote in self?.adopt(remote) }
        events.displayChanged = { [weak self] rate in self?.displayChanged(rate) }
        // Tied to this presenter: one replaced by a switch can still report its
        // end afterwards, and must not stop the session that replaced it.
        let identity = ObjectIdentifier(presenter)
        events.ended = { [weak self] reason in
            Task { @MainActor in await self?.presenterEnded(reason, presenter: identity) }
        }
        appliedCap = nil
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
        stopMicrophone()
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

    /// Ends the session. `endingPCVR`: the wearer stopped, so the PC may stop
    /// its stack now; a session that dropped leaves it running for a while.
    func stop(endingPCVR: Bool = true) async {
        if endingPCVR { remote?.endPCVR() }
        statusTask?.cancel()
        statusTask = nil
        stopMicrophone()
        stopControllerBridge()
        await presenter?.stop()
        presenter = nil
        remote = nil
        hostSession = nil
        microphoneTakenByPC = nil
        presenterName = nil
        state = .idle
    }

    /// Restarts the running session with the presenter now chosen. Ending the
    /// old one doesn't end PCVR on the PC (`endingPCVR: false`), so its stack and
    /// the game keep running across the switch.
    private func switchPresenter() async {
        guard isActive, !isSwitching, let target = activeTarget, let shell = activeShell,
              let gameLibrary else { return }
        isSwitching = true
        defer { isSwitching = false }
        log.notice("switching native PCVR presenter to \(self.presenterChoice.rawValue, privacy: .public)")
        await stop(endingPCVR: false)
        await start(target: target, shell: shell, gameLibrary: gameLibrary)
    }

    private func presenterEnded(_ reason: String?, presenter identity: ObjectIdentifier) async {
        guard isActive, !isSwitching, let presenter, ObjectIdentifier(presenter) == identity else { return }
        await stop(endingPCVR: false)
        if let reason { state = .failed(reason) }
    }

    // MARK: The stream

    private func adopt(_ remote: PCVRV3Remote) {
        self.remote = remote
        Task { await updateMicrophone() }
        remote.setPreferences(preferences)
        if let display { remote.setDisplay(display) }
        remote.onInputBridge = { [weak self] bytes in
            Task { @MainActor in self?.inputBridgeArrived(bytes) }
        }
        statusTask?.cancel()
        statusTask = Task { [weak self, weak remote] in
            while !Task.isCancelled, let remote {
                let (session, microphone) = remote.status.withLock {
                    ($0.hostSession, $0.state.hasPrefix("Connected") || $0.state == "Streaming" ? $0.microphoneNegotiated : nil)
                }
                if self?.hostSession != session { self?.hostSession = session }
                if let microphone, self?.microphoneTakenByPC != microphone { self?.microphoneTakenByPC = microphone }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: The microphone

    /// Runs the uplink into the current stream while the setting is on and a
    /// stream exists; a new stream (a reconnect through the presenter, a
    /// switch) gets a fresh uplink bound to it.
    private func updateMicrophone() async {
        guard microphoneEnabled, isActive, state != .paused, let remote else {
            stopMicrophone()
            microphoneMessage = nil
            return
        }
        if microphone != nil, microphoneRemote === remote { return }
        stopMicrophone()
        guard await AVAudioApplication.requestRecordPermission() else {
            microphoneMessage = "Allow microphone access for Longwave in Settings."
            return
        }
        guard microphoneEnabled, isActive, self.remote === remote else { return }
        let uplink = MicrophoneUplink(packets: { [weak remote] packet in
            remote?.sendMicrophone(firstSample: packet.stamp.sampleIndex, resumed: packet.stamp.flags.contains(.resumed),
                                   samples: packet.samples)
        })
        uplink.onStart = { [weak remote] rate in
            remote?.setMicrophone(MicrophoneFormat(sampleRate: UInt32(rate.rounded())))
        }
        do {
            try uplink.start()
        } catch {
            microphoneMessage = error.localizedDescription
            log.error("PCVR microphone could not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        microphone = uplink
        microphoneRemote = remote
        microphoneMessage = nil
    }

    private func stopMicrophone() {
        guard let microphone else { return }
        microphone.stop()
        self.microphone = nil
        microphoneRemote?.setMicrophone(.stopped)
        microphoneRemote = nil
    }


    private func displayChanged(_ rate: PCVRDisplayRate) {
        guard rate != display else { return }
        display = rate
        remote?.setDisplay(rate)
        log.notice("display \(rate.hertz, privacy: .public) Hz reported to the PC")
        sendPreferences()   // a half-rate cap follows the display
    }

    private func sendPreferences() {
        let preferences = preferences
        remote?.setPreferences(preferences)
        let cap = preferences.maxStreamMillihertz
        guard cap != appliedCap, isActive, let presenter else { return }
        appliedCap = cap
        Task { await presenter.frameRateCapChanged(cap) }
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
    static func target(pcvrHost: String, connections: [SavedConnection],
                       windowsHostIDs: Set<String> = []) throws -> PCVRV3Target {
        let companions = connections.filter { $0.connectionType == .native && $0.companionCredential?.deviceID != nil }
        /* With no address typed, PCVR can only mean a Windows PC: a Mac's Companion answers the
           hello too, without PCVR, and the session then retries forever. Prefer the one seen
           advertising as Windows, then any Windows-looking address, before "the first". */
        let preferred = companions.first(where: { !pcvrHost.isEmpty && $0.hostname == pcvrHost })
            ?? companions.first(where: { $0.companionMacID.map(windowsHostIDs.contains) ?? false })
        guard let companion = preferred ?? companions.first,
              let credential = companion.companionCredential else { throw PCVRNativeSessionError.noCompanion }
        let host = pcvrHost.isEmpty ? companion.hostname : pcvrHost
        return PCVRV3Target(host: host, credential: credential, deviceName: DeviceName.current)
    }
}
#endif
