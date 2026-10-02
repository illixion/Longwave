import Foundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// Captures the whole Mac display, exactly as it looks on the Mac: desktop
/// picture, menu bar, Dock, Stage Manager strip, notifications, menus and every
/// window, opaque edge to edge.
///
/// This used to be a composition of just the visible application windows over a
/// clear background, streamed as HEVC-with-alpha so the wallpaper's place showed
/// the room instead. That made whole classes of the Mac unreachable — the menu
/// bar and Dock were not in the frame at all, so neither was any menu opened
/// from them — and it made a remote desktop that did not look like the desktop.
/// Per-window streams (`MacNativeWindowStreams`) are where a chrome-free,
/// alpha-preserving Mac window still lives; this one is the whole display.
final class MacNativeScreenCapture: NSObject, @unchecked Sendable {
    nonisolated(unsafe) var onFormatDescription: (@Sendable (Data) -> Void)?
    nonisolated(unsafe) var onFrame: (@Sendable (Data, Bool, UInt64, UInt64) -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (String) -> Void)?
    /// One line describing what the capture actually settled on — size, chroma,
    /// and whether the encoder landed on the media engine. Fired once the first
    /// compression session exists, since "asked for hardware" and "got it" are
    /// different questions.
    nonisolated(unsafe) var onVideoSummary: (@Sendable (String) -> Void)?
    /// The captured display's frame in the global (point-space) coordinate
    /// system — the same space `CGEvent` mouse coordinates use — and the
    /// stream's pixels-per-point. Fired once capture starts and again whenever
    /// the display-refresh poll resolves a change, so remote-control input can
    /// map a stream-space (x, y) back to a real screen position, including on a
    /// non-main display and at Retina scale. The stream is in pixels and
    /// `CGEvent` is in points, so a receiver must divide before adding the
    /// origin — see `MacNativeStreamingController.globalPoint`.
    nonisolated(unsafe) var onDisplayGeometry: (@Sendable (CGRect, CGFloat) -> Void)?

    private let outputQueue = DispatchQueue(
        label: "pro.longwave.companion.mac-native.capture",
        qos: .userInteractive
    )
    // SCStream/display/refreshTask are only ever touched from start()/stop()/
    // refreshDisplay() below, which are MainActor-isolated (the project
    // default) so those three calls can't run concurrently on different
    // threads. `encoder` stays nonisolated(unsafe): it's written here but
    // read from the SCStreamOutput callback on `outputQueue`.
    private var stream: SCStream?
    private nonisolated(unsafe) var encoder: MacHEVCEncoder?
    private var display: SCDisplay?
    /// Stream pixels per display point. Native backing scale, except on a
    /// display big enough to need `maxStreamDimension` to pull it back.
    private var pixelScale: CGFloat = 1
    private var refreshTask: Task<Void, Never>?
    // Bumped on every start()/stop() so a start() resuming after an `await`
    // can tell whether a subsequent stop() (or restart) already superseded
    // it, instead of clobbering state a later call already tore down.
    private var generation = 0
    /// Chroma for this capture's encoder, decided by what the connected viewer
    /// said it can hardware-decode. Fixed for the life of the capture: the
    /// profile is a property of the compression session, and a viewer swap
    /// restarts the whole thing anyway.
    private let chroma: MacHEVCEncoder.Chroma
    /// The display to capture, when it is not simply the main one — the
    /// companion's virtual display, which may not have been promoted to main
    /// yet when capture starts. `nil` follows `CGMainDisplayID()`.
    private let preferredDisplayID: CGDirectDisplayID?
    /// Capture and encode rate. Starts at what the display refreshes at, up
    /// to the headset's 120 Hz, and steps down to 60 if the encoder can't
    /// keep each frame inside its interval (see `checkEncoderKeepsUp`).
    private var frameRate = 60
    private var slowEncoderChecks = 0
    private var lastSessionSize: (width: Int, height: Int)?

    /// The bitrate this display and frame rate deserve on a good link — or
    /// the user's fixed choice — and what the encoder runs at right now,
    /// which drops when the link starts dropping frames and climbs back once
    /// it stops (`linkCongested`, `recoverBitrate`).
    private var bitrateCeiling: Int?
    private var targetBitrate = 0
    private var currentBitrate = 0
    private var lastCongestion: ContinuousClock.Instant?

    /// Frames slower than this to encode, sustained, mean 120 fps is costing
    /// latency instead of saving it: 8.3 ms is the whole interval.
    private nonisolated static let encodeBudgetAt120 = 7.0

    nonisolated init(
        chroma: MacHEVCEncoder.Chroma = .yuv420,
        displayID: CGDirectDisplayID? = nil,
        bitrateCeiling: Int? = nil
    ) {
        self.chroma = chroma
        self.preferredDisplayID = displayID
        self.bitrateCeiling = bitrateCeiling
        super.init()
    }

    /// A fixed bitrate (bits/s), or nil for the area-based automatic one.
    /// Applies to the running stream at once.
    func setBitrateCeiling(_ ceiling: Int?) {
        bitrateCeiling = ceiling
        guard let configuration = currentConfiguration else { return }
        retarget(for: configuration)
        currentBitrate = targetBitrate
        applyBitrate()
    }

    /// The link dropped frames: back off by 30%, at most twice a second, never
    /// below a quarter of the target.
    func linkCongested() {
        guard encoder != nil, targetBitrate > 0 else { return }
        let now = ContinuousClock.now
        if let lastCongestion, now - lastCongestion < .milliseconds(500) { return }
        lastCongestion = now
        let lowered = max(targetBitrate / 4, currentBitrate * 7 / 10)
        guard lowered < currentBitrate else { return }
        currentBitrate = lowered
        applyBitrate()
    }

    /// Climbs 20% back toward the target every check once the link has gone
    /// five seconds without dropping anything.
    private func recoverBitrate() {
        guard encoder != nil, currentBitrate < targetBitrate else { return }
        if let lastCongestion, ContinuousClock.now - lastCongestion < .seconds(5) { return }
        currentBitrate = min(targetBitrate, currentBitrate * 6 / 5)
        applyBitrate()
    }

    private var currentConfiguration: SCStreamConfiguration?

    private func retarget(for configuration: SCStreamConfiguration) {
        currentConfiguration = configuration
        targetBitrate = bitrateCeiling ?? Self.bitrate(for: configuration, frameRate: frameRate)
        currentBitrate = currentBitrate == 0 ? targetBitrate : min(currentBitrate, targetBitrate)
    }

    private func applyBitrate() {
        guard let encoder else { return }
        encoder.setLiveBitrate(currentBitrate)
        publishSummary(encoder)
    }

    func start() async throws {
        generation += 1
        let myGeneration = generation
        guard stream == nil else { return }
        let display = try await Self.captureDisplay(preferring: preferredDisplayID)
        guard myGeneration == generation else { return }

        frameRate = Self.frameRate(for: display.displayID)
        slowEncoderChecks = 0
        let filter = Self.makeFilter(display: display)
        let (configuration, pixelScale) = Self.makeConfiguration(
            display: display, filter: filter, frameRate: frameRate
        )
        currentBitrate = 0
        retarget(for: configuration)
        // Opaque full display: no alpha layer to spend bits or decode cycles on.
        let encoder = MacHEVCEncoder(
            bitrate: currentBitrate,
            frameRate: frameRate,
            preservesAlpha: false,
            chroma: chroma
        )
        encoder.onFormatDescription = { [weak self] data in
            self?.onFormatDescription?(data)
        }
        encoder.onFrame = { [weak self] data, keyFrame, sequence, timestamp in
            self?.onFrame?(data, keyFrame, sequence, timestamp)
        }
        encoder.onError = { [weak self] message in
            self?.onError?(message)
        }
        encoder.onSessionReady = { [weak self, weak encoder] width, height in
            guard let self, let encoder else { return }
            Task { @MainActor in
                self.lastSessionSize = (width, height)
                self.publishSummary(encoder)
            }
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        guard myGeneration == generation else {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
            encoder.invalidate()
            return
        }

        self.display = display
        self.pixelScale = pixelScale
        self.encoder = encoder
        self.stream = stream
        onDisplayGeometry?(display.frame, pixelScale)
        startDisplayRefresh()
    }

    /// Asks the encoder for a key frame on its next capture — what a viewer
    /// joining an already-running desktop stream needs to start decoding
    /// without waiting out the key-frame interval.
    func requestKeyFrame() {
        encoder?.requestKeyFrame()
    }

    func stop() async {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
        }
        stream = nil
        display = nil
        encoder?.invalidate()
        encoder = nil
    }

    private func publishSummary(_ encoder: MacHEVCEncoder) {
        guard let size = lastSessionSize else { return }
        let engine = encoder.usingHardwareEncoder ? "hardware" : "software"
        let rateControl = encoder.lowLatencyRateControl ? ", low-latency" : ""
        onVideoSummary?(
            "\(size.width)×\(size.height) HEVC \(encoder.chromaDescription) at \(encoder.expectedFrameRate) fps, "
                + "\(currentBitrate / 1_000_000) of \(targetBitrate / 1_000_000) Mbps, "
                + "\(engine) encode\(rateControl)"
        )
    }

    /// The display's own refresh rate, capped at the headset's 120 Hz. A
    /// virtual display is created at 120; a 60 Hz monitor can't produce more
    /// than 60 frames however fast it is captured, and telling the encoder to
    /// expect 120 would only halve its per-frame bit budget.
    private nonisolated static func frameRate(for displayID: CGDirectDisplayID) -> Int {
        let refresh = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        // Built-in panels report 0 (variable refresh); ProMotion ones go to 120.
        let rate = refresh > 0 ? refresh : (CGDisplayIsBuiltin(displayID) != 0 ? 120 : 60)
        return rate >= 100 ? 120 : 60
    }

    /// At 120 fps every frame has 8.3 ms to get through the encoder. If it
    /// keeps taking longer, frames back up inside VideoToolbox and the stream
    /// lags further behind the faster it runs — so step down to 60, which is
    /// slower but current. Two checks in a row, so one heavy key frame or a
    /// burst of redraw doesn't trip it.
    private func checkEncoderKeepsUp() async {
        guard frameRate > 60, let stream, let display, let encoder else { return }
        guard encoder.averageEncodeMilliseconds > Self.encodeBudgetAt120 else {
            slowEncoderChecks = 0
            return
        }
        slowEncoderChecks += 1
        guard slowEncoderChecks >= 2 else { return }
        let filter = Self.makeFilter(display: display)
        let (configuration, _) = Self.makeConfiguration(display: display, filter: filter, frameRate: 60)
        do {
            try await stream.updateConfiguration(configuration)
            frameRate = 60
            retarget(for: configuration)
            encoder.setFrameRate(60, bitrate: currentBitrate)
            publishSummary(encoder)
        } catch {
            onError?("Could not lower the capture rate: \(error.localizedDescription)")
        }
    }

    /// Everything on the display, nothing excluded — including the companion's
    /// own window, so the Mac's settings stay reachable from the headset.
    private nonisolated static func makeFilter(display: SCDisplay) -> SCContentFilter {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        filter.includeMenuBar = true
        return filter
    }

    /// The display the stream follows: the preferred one when asked for one,
    /// else the main one, else the first available. A preferred display is
    /// retried for a moment rather than substituted — a virtual display that
    /// just came online can take ScreenCaptureKit a few hundred milliseconds
    /// to list, a physical one coming back from the exclusive virtual
    /// display's blackout takes seconds, and falling back to the main display
    /// would silently stream the wrong desktop.
    private nonisolated static func captureDisplay(
        preferring preferredID: CGDirectDisplayID?
    ) async throws -> SCDisplay {
        let attempts = 40
        for attempt in 0..<attempts {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            if let preferredID {
                if let display = content.displays.first(where: { $0.displayID == preferredID }) {
                    return display
                }
                if attempt < attempts - 1 {
                    try await Task.sleep(for: .milliseconds(150))
                    continue
                }
                throw CaptureError.displayNotCapturable(preferredID)
            }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else {
                throw CaptureError.noDisplay
            }
            return display
        }
        throw CaptureError.noDisplay
    }

    /// Beyond this the encoder, the link and the headset's decoder all start
    /// paying for pixels nobody can resolve. A 5K Mac lands here and streams at
    /// something under its native scale; everything smaller streams at 2x.
    private nonisolated static let maxStreamDimension: CGFloat = 4096

    /// Capture at the display's native backing scale, so menu-bar and window
    /// text arrive with the pixels they were drawn with. Everything the viewer
    /// sends back is in these stream pixels, so the scale comes back with the
    /// configuration rather than being stashed here — the caller stores it only
    /// once the stream is actually running at that size, or a failed
    /// `updateConfiguration` would leave input dividing by a scale the live
    /// stream never adopted.
    private nonisolated static func makeConfiguration(
        display: SCDisplay,
        filter: SCContentFilter,
        frameRate: Int
    ) -> (configuration: SCStreamConfiguration, pixelScale: CGFloat) {
        let configuration = SCStreamConfiguration()
        let pointSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        // `pointPixelScale` is what ScreenCaptureKit itself would render at.
        // Guard it anyway: a zero would collapse the stream to 2x2.
        var scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : 1
        let longest = max(pointSize.width, pointSize.height)
        if longest * scale > maxStreamDimension, longest > 0 {
            scale = maxStreamDimension / longest
        }
        // Even dimensions for the encoder's 4:2:0 chroma.
        configuration.width = max(2, Int(pointSize.width * scale / 2) * 2)
        configuration.height = max(2, Int(pointSize.height * scale / 2) * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // The whole display covers every pixel, so there is no background to
        // show through and no `backgroundColor` to keep alive for the stream's
        // lifetime (ScreenCaptureKit reads that CGColor back later without
        // retaining it, and a dangling read there is a crash).
        configuration.shouldBeOpaque = true
        configuration.showsCursor = true
        configuration.ignoreShadowsDisplay = false
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        return (configuration, scale)
    }

    /// Scales with the encoded pixel area (≈12 bit/px/s at 60 fps, about 0.2
    /// bits per pixel per frame) so going Retina buys sharper pixels instead
    /// of the same bitrate spread over four times as many. The stream is
    /// mostly text, and scrolling or dragging a window is where a starved
    /// encoder smears it, so this aims high; `linkCongested` is what keeps a
    /// weak link from paying for that in queueing delay.
    private nonisolated static func bitrate(for configuration: SCStreamConfiguration, frameRate: Int) -> Int {
        let pixelArea = Double(configuration.width * configuration.height)
        let at60 = max(30_000_000, min(100_000_000, pixelArea * 12))
        // Twice the frames, each predicted from a picture half as old: deltas
        // shrink, so half again the bitrate keeps per-frame quality.
        return Int(frameRate > 60 ? min(150_000_000, at60 * 1.5) : at60)
    }

    /// The filter is the whole display and never needs rebuilding for a window
    /// coming or going — only for the display itself changing shape. This poll
    /// watches for a resolution or arrangement change (display swapped, mode
    /// changed, headset moved to another Mac display) and republishes the frame
    /// that remote-control input maps through.
    private func startDisplayRefresh() {
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.refreshDisplay()
                await self.checkEncoderKeepsUp()
                await self.recoverBitrate()
            }
        }
    }

    private func refreshDisplay() async {
        guard let stream, let display else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let refreshed = content.displays.first(
                where: { $0.displayID == display.displayID }
            ), refreshed.frame != display.frame
                || refreshed.width != display.width
                || refreshed.height != display.height else {
                return
            }
            let filter = Self.makeFilter(display: refreshed)
            let (configuration, scale) = Self.makeConfiguration(
                display: refreshed, filter: filter, frameRate: frameRate
            )
            try await stream.updateContentFilter(filter)
            try await stream.updateConfiguration(configuration)
            // The new size makes the encoder open a fresh session; give it the
            // bitrate for the new area rather than the one it was built with.
            retarget(for: configuration)
            encoder?.setBitrate(currentBitrate)
            self.display = refreshed
            self.pixelScale = scale
            onDisplayGeometry?(refreshed.frame, scale)
        } catch {
            onError?("Display refresh failed: \(error.localizedDescription)")
        }
    }

    private enum CaptureError: LocalizedError {
        case noDisplay
        case displayNotCapturable(CGDirectDisplayID)

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No capturable Mac display is available."
            case .displayNotCapturable(let id):
                return "The selected display (\(id)) never became capturable."
            }
        }
    }
}

extension MacNativeScreenCapture: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete else {
            return
        }
        encoder?.encode(sampleBuffer)
    }
}

extension MacNativeScreenCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Screen capture stopped: \(error.localizedDescription)")
    }
}
