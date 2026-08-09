import Foundation
import AVFoundation

/// Camera capture for the broadcast pipeline. visionOS exposes a reduced
/// AVCapture surface (no session presets, no `AVCaptureAudioDataOutput`) —
/// video comes from `AVCaptureVideoDataOutput` at the device's native
/// format, and the mic is captured separately by `BroadcastMicCapture`.
final class BroadcastCaptureSession: NSObject, @unchecked Sendable {

    nonisolated(unsafe) var onVideoSample: ((CMSampleBuffer) -> Void)?

    /// Exposed for the SwiftUI preview layer. Configure/start/stop only
    /// through this class.
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.illixion.Longwave.broadcast-session")
    private let videoQueue = DispatchQueue(label: "com.illixion.Longwave.broadcast-video", qos: .userInteractive)

    /// Every video capture device visionOS will give us. The exact device
    /// types Persona / Mirror My View enumerate as are undocumented, so
    /// merge discovery with the system default and log what we find.
    nonisolated static func availableCameras() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video, position: .unspecified)
        var devices = discovery.devices
        if let fallback = AVCaptureDevice.default(for: .video),
           !devices.contains(where: { $0.uniqueID == fallback.uniqueID }) {
            devices.append(fallback)
        }
        for device in devices {
            AppLog.broadcast.line("📷 Video device: \(device.localizedName) [\(device.uniqueID)] type=\(device.deviceType.rawValue)")
        }
        return devices
    }

    enum ConfigurationError: Error, LocalizedError {
        case inputRejected(String)

        var errorDescription: String? {
            switch self {
            case .inputRejected(let detail): "Capture setup failed: \(detail)"
            }
        }
    }

    nonisolated func configure(camera: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        do {
            let videoInput = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(videoInput) else {
                throw ConfigurationError.inputRejected("video input not accepted")
            }
            session.addInput(videoInput)
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.inputRejected(error.localizedDescription)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        // NV12 is VideoToolbox's preferred input; drop late frames rather
        // than letting encode latency snowball.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else {
            throw ConfigurationError.inputRejected("video output not accepted")
        }
        session.addOutput(videoOutput)
    }

    nonisolated func start() {
        sessionQueue.async { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    nonisolated func stop() {
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
}

extension BroadcastCaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        onVideoSample?(sampleBuffer)
    }
}

/// Mic capture via an AVAudioEngine input tap (visionOS has no
/// `AVCaptureAudioDataOutput`). Emits PCM buffers on the engine's render
/// thread. Uses a mixable play-and-record session so it can coexist with
/// the audio-stream receiver, though running both at once is untested.
final class BroadcastMicCapture: @unchecked Sendable {

    nonisolated(unsafe) var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private nonisolated(unsafe) var engine: AVAudioEngine?

    nonisolated func start() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try audioSession.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        AppLog.broadcast.line("🎙️ Mic capture started: \(format.sampleRate) Hz \(format.channelCount)ch")
    }

    nonisolated func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
