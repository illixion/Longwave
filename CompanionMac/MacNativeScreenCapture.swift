import Foundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// Captures a display-sized composition of visible application windows over a
/// clear background. The desktop picture and Dock are intentionally absent.
final class MacNativeScreenCapture: NSObject, @unchecked Sendable {
    nonisolated(unsafe) var onFormatDescription: (@Sendable (Data) -> Void)?
    nonisolated(unsafe) var onFrame: (@Sendable (Data, Bool, UInt64, UInt64) -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (String) -> Void)?

    private let outputQueue = DispatchQueue(
        label: "com.illixion.VisionVNCCompanion.mac-native.capture",
        qos: .userInteractive
    )
    private nonisolated(unsafe) var stream: SCStream?
    private nonisolated(unsafe) var encoder: MacHEVCAlphaEncoder?
    private nonisolated(unsafe) var display: SCDisplay?
    private nonisolated(unsafe) var refreshTask: Task<Void, Never>?

    nonisolated override init() {
        super.init()
    }

    nonisolated func start() async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = makeFilter(content: content, display: display)
        let configuration = makeConfiguration(display: display)
        let encoder = MacHEVCAlphaEncoder()
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

        self.display = display
        self.encoder = encoder
        self.stream = stream
        startFilterRefresh()
    }

    nonisolated func stop() async {
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

    private nonisolated func makeFilter(
        content: SCShareableContent,
        display: SCDisplay
    ) -> SCContentFilter {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter { window in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 2,
                  window.frame.height >= 2 else {
                return false
            }
            return window.owningApplication?.processID != ownPID
        }
        let filter = SCContentFilter(display: display, including: windows)
        filter.includeMenuBar = false
        return filter
    }

    private nonisolated func makeConfiguration(display: SCDisplay) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.backgroundColor = CGColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        configuration.shouldBeOpaque = false
        configuration.showsCursor = true
        configuration.ignoreShadowsDisplay = false
        configuration.includeChildWindows = true
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        return configuration
    }

    private nonisolated func startFilterRefresh() {
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.refreshFilter()
            }
        }
    }

    private nonisolated func refreshFilter() async {
        guard let stream, let display else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            guard let refreshedDisplay = content.displays.first(
                where: { $0.displayID == display.displayID }
            ) else {
                return
            }
            try await stream.updateContentFilter(
                makeFilter(content: content, display: refreshedDisplay)
            )
            self.display = refreshedDisplay
        } catch {
            onError?("Window inventory refresh failed: \(error.localizedDescription)")
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
