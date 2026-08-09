#if os(visionOS)
import AVFoundation
import Speech

/// In-app dictation for the terminal composer, transcribed on device.
///
/// Two things this is not, and why:
///
/// - **Not the system keyboard's dictation.** visionOS hosts that in the keyboard,
///   and its session dies when the app drives UIKit hard from *any* window — one
///   streaming terminal is enough (`TextInputActivity` pages down the producers to
///   keep it alive). Running the recognizer in-process means there is no keyboard
///   session to lose in the first place.
/// - **Not the agent CLI's own `/voice`.** That records from an input device on the
///   machine running the CLI and refuses outright on a host with no microphone,
///   which is every SSH target. Relaying microphone audio to the host would mean
///   giving it a virtual capture device (a driver install on macOS, a Pulse/PipeWire
///   pipe-source on Linux) and, on macOS, microphone consent for a process sshd
///   launched — which the system never prompts for. Transcribing here and sending
///   text needs nothing from the host, and works for every agent, not just Claude.
///
/// Text is published as it arrives: `transcript` is the finalized phrases plus the
/// in-flight one, so a caller can mirror it straight into a composer.
@MainActor
@Observable
final class DictationController {
    enum Status: Equatable {
        case idle
        /// Downloading the on-device model for the chosen locale (first run only).
        case preparing
        case listening
        /// Dictation can't run at all — no supported locale, or consent refused.
        case unavailable(String)
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// Everything recognized this session: settled phrases plus the phrase still
    /// being revised. Volatile text is included so the composer reads as live.
    var transcript: String { finalized + volatile }

    /// Settled phrases only. For a consumer that forwards each change onward — the
    /// VNC keyboard types its field's delta into the remote desktop — where the
    /// revisions behind `transcript` would go out as backspace-and-retype storms.
    var settledTranscript: String { finalized }

    var isListening: Bool { status == .listening }
    var isBusy: Bool { status == .preparing }

    private var finalized = ""
    private var volatile = ""

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var reservedLocale: Locale?
    private var restoreSession: (category: AVAudioSession.Category,
                                mode: AVAudioSession.Mode,
                                options: AVAudioSession.CategoryOptions)?

    // MARK: - Control

    /// Begin a session. Clears any previous transcript, so a caller should have
    /// already consumed it.
    func start() async {
        guard status != .listening, status != .preparing else { return }
        finalized = ""
        volatile = ""
        status = .preparing

        guard await requestMicrophoneConsent() else {
            status = .unavailable("Microphone access is off for Longwave. Turn it on in Settings › Privacy.")
            return
        }

        do {
            let locale = try await installedLocale()
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            try await installAssetsIfNeeded(for: transcriber, locale: locale)

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            ) else {
                throw DictationError.noAudioFormat
            }

            self.transcriber = transcriber
            self.analyzer = analyzer
            observeResults(from: transcriber)

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputContinuation = continuation
            try await analyzer.start(inputSequence: stream)
            try startCapture(into: continuation, analyzerFormat: analyzerFormat)

            status = .listening
        } catch {
            await teardown()
            status = .failed(Self.message(for: error))
            AppLog.app.line("Dictation start failed: \(error)")
        }
    }

    /// Stop listening and flush whatever the recognizer is still holding, so the
    /// last words land in `transcript` rather than being dropped.
    func stop() async {
        guard status == .listening || status == .preparing else { return }
        stopCapture()
        inputContinuation?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await drainResults()
        finalized += volatile
        volatile = ""
        await teardown()
        if case .failed = status {} else { status = .idle }
    }

    /// Drop the session and its text (the user cancelled).
    func cancel() async {
        stopCapture()
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        await teardown()
        finalized = ""
        volatile = ""
        if case .failed = status {} else { status = .idle }
    }

    // MARK: - Results

    private func observeResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalized += text
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                }
            } catch {
                // A cancelled task is us tearing the session down, not a failure.
                guard let self, !Task.isCancelled else { return }
                AppLog.app.line("Dictation results ended: \(error)")
                self.status = .failed("Dictation stopped unexpectedly.")
            }
        }
    }

    /// Wait for the recognizer to close out its results, but never indefinitely:
    /// if finalizing doesn't end the sequence, stopping still has to release the
    /// microphone rather than hanging with it open.
    private func drainResults() async {
        guard let resultsTask else { return }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(2))
            resultsTask.cancel()
        }
        await resultsTask.value
        deadline.cancel()
    }

    // MARK: - Capture

    /// Tap the input node and hand converted buffers to the analyzer. The tap's
    /// own format is whatever the current route gives us, so it is converted to the
    /// format the transcriber asked for — the analyzer does no conversion itself.
    private func startCapture(into continuation: AsyncStream<AnalyzerInput>.Continuation,
                              analyzerFormat: AVAudioFormat) throws {
        try activateRecordingSession()

        let input = engine.inputNode
        let captureFormat = input.outputFormat(forBus: 0)
        guard captureFormat.sampleRate > 0 else { throw DictationError.noInput }
        let converter = AVAudioConverter(from: captureFormat, to: analyzerFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        try engine.start()
    }

    private func stopCapture() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Resample a captured buffer into the analyzer's format. Returns nil rather
    /// than throwing: a dropped buffer costs a syllable, not the session.
    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer,
                                            using converter: AVAudioConverter?,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer.format == format ? buffer : nil }
        if buffer.format == format { return buffer }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let outcome = converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard outcome != .error, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: - Audio session

    /// Take the session to `.playAndRecord`, mixably, and remember what it was.
    /// Mixable matters: an exclusive grab would interrupt whatever else the app is
    /// playing — the companion audio stream in particular (see `AudioStreamManager`,
    /// which is deliberately careful about not re-asserting the category).
    private func activateRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord {
            try session.setActive(true)
            return
        }
        restoreSession = (session.category, session.mode, session.categoryOptions)
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    private func restoreAudioSession() {
        guard let restoreSession else { return }
        self.restoreSession = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(restoreSession.category,
                                    mode: restoreSession.mode,
                                    options: restoreSession.options)
        } catch {
            AppLog.app.line("Dictation: failed to restore the audio session: \(error)")
        }
    }

    private func requestMicrophoneConsent() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Locale and assets

    /// The locale to transcribe in: the device's own if the transcriber knows it,
    /// else any English one, else give up — guessing a language would transcribe
    /// gibberish.
    private func installedLocale() async throws -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        if let english = await SpeechTranscriber.supportedLocales.first(where: {
            $0.language.languageCode?.identifier == "en"
        }) {
            return english
        }
        throw DictationError.noSupportedLocale
    }

    /// Models are system-managed and shared between apps, so this is usually a
    /// no-op after the first run. The reservation is what keeps ours installed.
    private func installAssetsIfNeeded(for transcriber: SpeechTranscriber,
                                       locale: Locale) async throws {
        if reservedLocale != locale {
            if let previous = reservedLocale {
                await AssetInventory.release(reservedLocale: previous)
            }
            if try await AssetInventory.reserve(locale: locale) {
                reservedLocale = locale
            }
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Teardown

    private func teardown() async {
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        stopCapture()
        restoreAudioSession()
    }

    private enum DictationError: Error {
        case noSupportedLocale
        case noAudioFormat
        case noInput
    }

    private static func message(for error: Error) -> String {
        switch error {
        case DictationError.noSupportedLocale:
            return "No dictation language is available for this device."
        case DictationError.noAudioFormat:
            return "This device can't transcribe speech on device."
        case DictationError.noInput:
            return "No microphone input is available."
        default:
            return "Dictation couldn't start."
        }
    }
}
#endif
