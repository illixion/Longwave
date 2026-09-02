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
    /// The captured display's frame in the global (point-space) coordinate
    /// system — the same space `CGEvent` mouse coordinates use. Fired once
    /// capture starts and again whenever the display-refresh poll resolves a
    /// changed frame, so remote-control input can map a stream-space (x, y)
    /// back to a real screen position, including on a non-main display.
    nonisolated(unsafe) var onDisplayFrame: (@Sendable (CGRect) -> Void)?

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
    private var refreshTask: Task<Void, Never>?
    // Bumped on every start()/stop() so a start() resuming after an `await`
    // can tell whether a subsequent stop() (or restart) already superseded
    // it, instead of clobbering state a later call already tore down.
    private var generation = 0

    nonisolated override init() {
        super.init()
    }

    func start() async throws {
        generation += 1
        let myGeneration = generation
        guard stream == nil else { return }
        let display = try await Self.mainDisplay()
        guard myGeneration == generation else { return }

        let filter = Self.makeFilter(display: display)
        let configuration = makeConfiguration(display: display)
        // Opaque full display: no alpha layer to spend bits or decode cycles on.
        let encoder = MacHEVCEncoder(preservesAlpha: false)
        encoder.onFormatDescription = { [weak self] data in
            self?.onFormatDescription?(data)
        }
        encoder.onFrame = { [weak self] data, keyFrame, sequence, timestamp in
            self?.onFrame?(data, keyFrame, sequence, timestamp)
        }
        encoder.onError = { [weak self] message in
            self?.onError?(message)
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
        self.encoder = encoder
        self.stream = stream
        onDisplayFrame?(display.frame)
        startDisplayRefresh()
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

    /// Everything on the display, nothing excluded — including the companion's
    /// own window, so the Mac's settings stay reachable from the headset.
    private nonisolated static func makeFilter(display: SCDisplay) -> SCContentFilter {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        filter.includeMenuBar = true
        return filter
    }

    /// The display the stream follows: the main one, or the first available.
    private nonisolated static func mainDisplay() async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        return display
    }

    private func makeConfiguration(display: SCDisplay) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
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
        return configuration
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
            try await stream.updateContentFilter(Self.makeFilter(display: refreshed))
            try await stream.updateConfiguration(makeConfiguration(display: refreshed))
            self.display = refreshed
            onDisplayFrame?(refreshed.frame)
        } catch {
            onError?("Display refresh failed: \(error.localizedDescription)")
        }
    }

    private enum CaptureError: LocalizedError {
        case noDisplay

        var errorDescription: String? {
            "No capturable Mac display is available."
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
