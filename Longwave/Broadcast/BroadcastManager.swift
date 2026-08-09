import Foundation
import AVFoundation
import CoreMedia
import Observation

/// Orchestrates the broadcast pipeline:
/// capture (camera + mic) → H.264/Opus encode → RTSP publish to mediamtx.
///
/// MainActor state holder for the Broadcast tab; the pipeline itself runs on
/// capture/encoder threads via the nonisolated `PipelineLink`. Lives at app
/// scope (injected via `.environment()`) so the stream survives tab switches —
/// but not app backgrounding: visionOS pauses capture when the app loses
/// visibility, so the app must stay in front while broadcasting.
@Observable
final class BroadcastManager {

    enum State: Equatable {
        case idle
        case starting
        case broadcasting
        case error(String)
    }

    struct CameraOption: Identifiable, Equatable {
        let id: String
        let name: String
    }

    private(set) var state: State = .idle
    private(set) var cameras: [CameraOption] = []
    /// The Broadcast tab's preview layer registers itself here; capture
    /// frames are mirrored into it while broadcasting (visionOS has no
    /// `AVCaptureVideoPreviewLayer`).
    @ObservationIgnored let previewTarget = BroadcastPreviewTarget()

    // Stats (refreshed ~1 Hz while broadcasting)
    private(set) var statsFPS: Int = 0
    private(set) var statsKbps: Int = 0
    private(set) var audioActive = false
    /// The Mirror My View extension is publishing (polled from its
    /// shared-defaults heartbeat — it runs in a separate process).
    private(set) var viewSharingActive = false

    var selectedCameraID: String? {
        didSet { defaults.set(selectedCameraID, forKey: Keys.camera) }
    }
    var micEnabled: Bool {
        didSet { defaults.set(micEnabled, forKey: Keys.mic) }
    }
    var host: String {
        didSet { defaults.set(host, forKey: Keys.host) }
    }
    var port: Int {
        didSet { defaults.set(port, forKey: Keys.port) }
    }
    var streamPath: String {
        didSet { defaults.set(streamPath, forKey: Keys.path) }
    }
    /// Stream path for the Mirror My View broadcast extension (a separate
    /// mediamtx path so Persona and view streams can run concurrently).
    var viewStreamPath: String {
        didSet { defaults.set(viewStreamPath, forKey: Keys.viewPath) }
    }
    var username: String {
        didSet { defaults.set(username, forKey: Keys.username) }
    }
    var password: String {
        didSet { BroadcastShared.setPassword(password) }
    }
    var bitrateMbps: Int {
        didSet { defaults.set(bitrateMbps, forKey: Keys.bitrate) }
    }
    /// SHA-256 of the server TLS cert (hex) from companion pairing.
    /// Non-empty switches both publishers to RTSPS with pinning.
    var certFingerprint: String {
        didSet { defaults.set(certFingerprint, forKey: Keys.certFingerprint) }
    }

    private typealias Keys = BroadcastShared.Keys

    /// App-group defaults so the broadcast extension sees the same config.
    private let defaults = BroadcastShared.defaults
    @ObservationIgnored private var capture: BroadcastCaptureSession?
    @ObservationIgnored private var micCapture: BroadcastMicCapture?
    @ObservationIgnored private var videoEncoder: BroadcastVideoEncoder?
    @ObservationIgnored private var audioEncoder: BroadcastAudioEncoder?
    @ObservationIgnored private var link: PipelineLink?
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var viewSharingTimer: Timer?
    @ObservationIgnored private var userStopped = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    init() {
        // Settings predating the broadcast extension lived in standard
        // defaults / the default keychain group — migrate them over once.
        let standard = UserDefaults.standard
        let migrate = BroadcastShared.defaults
        if migrate.string(forKey: Keys.host) == nil,
           let oldHost = standard.string(forKey: Keys.host) {
            for key in [Keys.camera, Keys.host, Keys.path, Keys.username] {
                migrate.set(standard.string(forKey: key), forKey: key)
            }
            for key in [Keys.mic, Keys.port, Keys.bitrate] where standard.object(forKey: key) != nil {
                migrate.set(standard.object(forKey: key), forKey: key)
            }
            _ = oldHost
        }
        if BroadcastShared.getPassword() == nil,
           let oldPassword = KeychainStore.get(service: BroadcastShared.keychainService,
                                               account: BroadcastShared.keychainAccount) {
            BroadcastShared.setPassword(oldPassword)
            KeychainStore.delete(service: BroadcastShared.keychainService,
                                 account: BroadcastShared.keychainAccount)
        }

        selectedCameraID = defaults.string(forKey: Keys.camera)
        micEnabled = defaults.object(forKey: Keys.mic) as? Bool ?? true
        host = defaults.string(forKey: Keys.host) ?? ""
        port = defaults.object(forKey: Keys.port) as? Int ?? 8554
        streamPath = defaults.string(forKey: Keys.path) ?? "visionpro"
        viewStreamPath = defaults.string(forKey: Keys.viewPath) ?? "visionpro-view"
        username = defaults.string(forKey: Keys.username) ?? ""
        password = BroadcastShared.getPassword() ?? ""
        bitrateMbps = defaults.object(forKey: Keys.bitrate) as? Int ?? 10
        certFingerprint = defaults.string(forKey: Keys.certFingerprint) ?? ""

        viewSharingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.viewSharingActive = BroadcastShared.isViewSharingActive()
            }
        }
    }

    /// Applies a pairing payload AirDropped from the macOS companion
    /// (`longwave://…/setBroadcastServer`).
    func importSetup(_ setup: BroadcastSetup) {
        if isActive { stop() }
        host = setup.host
        port = Int(setup.port)
        streamPath = setup.streamPath
        viewStreamPath = setup.viewStreamPath
        username = setup.username
        password = setup.password
        certFingerprint = setup.certFingerprintHex ?? ""
        AppLog.broadcast.line("📥 Imported broadcast server setup for \(setup.host) (TLS: \(certFingerprint.isEmpty ? "off" : "pinned"), group: \(BroadcastShared.appGroup))")
    }

    var isActive: Bool {
        state == .starting || state == .broadcasting
    }

    func refreshCameras() {
        let devices = BroadcastCaptureSession.availableCameras()
        cameras = devices.map { CameraOption(id: $0.uniqueID, name: $0.localizedName) }
        if selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = cameras.first?.id
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isActive else { return }
        guard !host.isEmpty else {
            state = .error("Set the server address first")
            return
        }
        userStopped = false
        state = .starting

        guard await AVCaptureDevice.requestAccess(for: .video) else {
            state = .error("Camera access denied — enable it in Settings")
            return
        }
        var useMic = micEnabled
        if useMic {
            useMic = await AVCaptureDevice.requestAccess(for: .audio)
            if !useMic { AppLog.broadcast.line("⚠️ Mic access denied — broadcasting video-only") }
        }

        refreshCameras()
        guard let cameraID = selectedCameraID,
              let camera = BroadcastCaptureSession.availableCameras().first(where: { $0.uniqueID == cameraID }) else {
            state = .error("No camera available")
            return
        }

        let capture = BroadcastCaptureSession()
        do {
            try capture.configure(camera: camera)
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        var micCapture: BroadcastMicCapture?
        if useMic {
            let mic = BroadcastMicCapture()
            do {
                try mic.start()
                micCapture = mic
            } catch {
                AppLog.broadcast.line("⚠️ Mic capture failed (\(error.localizedDescription)) — broadcasting video-only")
                useMic = false
            }
        }

        let link = PipelineLink()
        let videoEncoder = BroadcastVideoEncoder(bitrate: bitrateMbps * 1_000_000)
        let audioEncoder = useMic ? BroadcastAudioEncoder(channels: 1) : nil

        let previewTarget = self.previewTarget
        capture.onVideoSample = { [weak videoEncoder] sampleBuffer in
            previewTarget.enqueue(sampleBuffer)
            videoEncoder?.encode(sampleBuffer)
        }
        micCapture?.onBuffer = { [weak audioEncoder] buffer in
            audioEncoder?.encode(buffer)
        }

        videoEncoder.onParameterSets = { [weak self] sps, pps in
            // First SPS/PPS unblocks ANNOUNCE (the SDP embeds them).
            guard let self, !link.publisherStarted else { return }
            link.publisherStarted = true
            Task { @MainActor in
                self.startPublisher(sps: sps, pps: pps, hasAudio: audioEncoder != nil, link: link)
            }
        }
        videoEncoder.onEncodedFrame = { nalUnits, pts, _ in
            let seconds = CMTimeGetSeconds(pts)
            guard seconds.isFinite else { return }
            let timestamp = UInt32(truncatingIfNeeded: Int64((seconds * 90_000).rounded()))
            link.publisher?.sendVideo(nalUnits: nalUnits, timestamp90k: timestamp)
            link.frameCount.add(1)
            link.byteCount.add(nalUnits.reduce(0) { $0 + $1.count })
        }
        videoEncoder.onError = { [weak self] message in
            Task { @MainActor in self?.handlePipelineFailure(message) }
        }
        audioEncoder?.onEncodedFrame = { frame, timestamp in
            link.publisher?.sendAudio(frame: frame, timestamp48k: timestamp)
            link.byteCount.add(frame.count)
            link.audioFrames.add(1)
        }
        audioEncoder?.onError = { [weak self] message in
            // Non-fatal: continue video-only.
            AppLog.broadcast.line("⚠️ \(message) — continuing video-only")
            Task { @MainActor in self?.audioActive = false }
        }

        self.capture = capture
        self.micCapture = micCapture
        self.videoEncoder = videoEncoder
        self.audioEncoder = audioEncoder
        self.link = link
        self.audioActive = useMic

        capture.start()
        startStatsTimer()
        AppLog.broadcast.line("▶️ Broadcast starting: \(host):\(port)/\(streamPath)")
    }

    func stop() {
        userStopped = true
        reconnectTask?.cancel(); reconnectTask = nil
        teardownPipeline()
        state = .idle
    }

    private func teardownPipeline() {
        statsTimer?.invalidate(); statsTimer = nil
        link?.publisher?.stop()
        link = nil
        capture?.stop()
        capture?.onVideoSample = nil
        capture = nil
        micCapture?.stop()
        micCapture = nil
        videoEncoder?.invalidate()
        videoEncoder = nil
        audioEncoder = nil
        previewTarget.clear()
        statsFPS = 0
        statsKbps = 0
        audioActive = false
    }

    private func startPublisher(sps: Data, pps: Data, hasAudio: Bool, link: PipelineLink) {
        guard isActive, self.link === link else { return }
        let sdp = SDPBuilder.build(sessionName: "Longwave Broadcast", sps: sps, pps: pps,
                                   audioChannels: hasAudio ? 1 : nil)
        let publisher = RTSPPublisher(
            host: host, port: UInt16(clamping: port), path: streamPath,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            sdp: sdp,
            pinnedCertSHA256: BroadcastShared.dataFromHex(certFingerprint))
        publisher.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.link === link else { return }
                switch event {
                case .ready:
                    self.state = .broadcasting
                case .failed(let message):
                    self.handlePipelineFailure(message)
                }
            }
        }
        link.publisher = publisher
        publisher.start()
    }

    private func handlePipelineFailure(_ message: String) {
        guard !userStopped, isActive else { return }
        AppLog.broadcast.line("❌ Broadcast error: \(message) — retrying in 3 s")
        teardownPipeline()
        state = .error(message)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, !self.userStopped else { return }
            await self.start()
        }
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let link = self.link else { return }
                self.statsFPS = link.frameCount.takeAndReset()
                self.statsKbps = link.byteCount.takeAndReset() * 8 / 1000
                if self.audioActive && link.audioFrames.takeAndReset() == 0 && self.state == .broadcasting {
                    // Mic configured but silent pipeline — likely converter
                    // never produced output; keep UI honest.
                    self.audioActive = false
                }
            }
        }
    }
}

/// Bridges capture frames to the Broadcast tab's `AVSampleBufferDisplayLayer`
/// (set from the view, enqueued from the capture thread). Capture buffers
/// carry live PTS, so frames are marked for immediate display.
final class BroadcastPreviewTarget: @unchecked Sendable {
    nonisolated(unsafe) weak var layer: AVSampleBufferDisplayLayer?

    nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let layer, layer.status != .failed else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        layer.enqueue(sampleBuffer)
    }

    nonisolated func clear() {
        layer?.flushAndRemoveImage()
    }
}

/// Shared mutable state between the MainActor manager and the pipeline
/// threads. Single-writer counters; stats reads are racy-but-benign.
private final class PipelineLink: @unchecked Sendable {
    nonisolated(unsafe) var publisher: RTSPPublisher?
    nonisolated(unsafe) var publisherStarted = false
    let frameCount = RacyCounter()
    let byteCount = RacyCounter()
    let audioFrames = RacyCounter()
}

/// Approximate counter for UI stats — torn reads are acceptable, lock-free.
final class RacyCounter: @unchecked Sendable {
    private nonisolated(unsafe) var value = 0
    nonisolated func add(_ delta: Int) { value += delta }
    nonisolated func takeAndReset() -> Int {
        let current = value
        value = 0
        return current
    }
}
