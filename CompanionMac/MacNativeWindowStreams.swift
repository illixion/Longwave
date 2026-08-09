import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// Everything the input path needs to know about one streamed window:
/// where it is on the real desktop (for coordinate mapping), who owns it
/// (for raising/activation), and how stream pixels map back to points.
struct MacNativeWindowTarget: Sendable {
    let windowID: UInt32
    let processID: pid_t
    let title: String
    /// Window frame in global point coordinates (CG top-left-origin space —
    /// the same space `CGEvent` and the Accessibility API use).
    let frame: CGRect
    /// Stream pixels per point — divide a stream-space coordinate by this
    /// before adding `frame.origin`.
    let pixelScale: CGFloat
}

/// Captures and encodes a single Mac window (Unity-style per-window stream).
/// One SCStream with a desktop-independent window filter feeding one
/// HEVC-with-alpha encoder; the owning coordinator handles inventory,
/// lifecycle, and resize tracking.
final class MacNativeWindowStreamer: NSObject, @unchecked Sendable {
    nonisolated(unsafe) var onFormatDescription: (@Sendable (Data) -> Void)?
    nonisolated(unsafe) var onFrame: (@Sendable (Data, Bool, UInt64, UInt64) -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (String) -> Void)?

    let windowID: UInt32
    private(set) var pixelScale: CGFloat = 2

    private let outputQueue: DispatchQueue
    private var stream: SCStream?
    private nonisolated(unsafe) var encoder: MacHEVCAlphaEncoder?
    private var lastConfiguredSize: CGSize = .zero

    nonisolated init(windowID: UInt32) {
        self.windowID = windowID
        self.outputQueue = DispatchQueue(
            label: "pro.longwave.companion.mac-native.window-\(windowID)",
            qos: .userInteractive
        )
        super.init()
    }

    func start(window: SCWindow) async throws {
        guard stream == nil else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        pixelScale = CGFloat(filter.pointPixelScale)

        let configuration = makeConfiguration(for: window.frame.size)
        lastConfiguredSize = window.frame.size

        // Bitrate scales with the encoded pixel area (≈4 bit/px/s at 60 fps),
        // bounded so a huge window can't monopolize the link and a tiny one
        // still gets enough for crisp text.
        let pixelArea = Double(configuration.width * configuration.height)
        let bitrate = Int(max(3_000_000, min(15_000_000, pixelArea * 4)))
        let encoder = MacHEVCAlphaEncoder(bitrate: bitrate)
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
        self.encoder = encoder
        self.stream = stream
    }

    /// Re-syncs capture with the window's current size (the filter itself
    /// follows moves and content changes live). The encoder notices the new
    /// pixel-buffer dimensions and re-emits a format description on its own.
    func update(window: SCWindow) async {
        guard let stream else { return }
        let size = window.frame.size
        guard abs(size.width - lastConfiguredSize.width) >= 1
                || abs(size.height - lastConfiguredSize.height) >= 1 else { return }
        lastConfiguredSize = size
        do {
            try await stream.updateContentFilter(SCContentFilter(desktopIndependentWindow: window))
            try await stream.updateConfiguration(makeConfiguration(for: size))
        } catch {
            onError?("Window stream reconfigure failed: \(error.localizedDescription)")
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
        }
        stream = nil
        encoder?.invalidate()
        encoder = nil
    }

    private func makeConfiguration(for pointSize: CGSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // Capture at native (retina) scale, dimensions rounded to even for
        // the encoder's 4:2:0 chroma.
        let maxDimension: CGFloat = 4096
        var scale = pixelScale
        let longest = max(pointSize.width, pointSize.height) * scale
        if longest > maxDimension {
            scale = maxDimension / max(pointSize.width, pointSize.height)
            pixelScale = scale
        }
        configuration.width = max(2, Int(pointSize.width * scale / 2) * 2)
        configuration.height = max(2, Int(pointSize.height * scale / 2) * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.shouldBeOpaque = false
        configuration.showsCursor = true
        // The visionOS scene provides its own chrome/shadow; a baked-in Mac
        // shadow would just be a fuzzy transparent margin.
        configuration.ignoreShadowsSingleWindow = true
        configuration.includeChildWindows = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        return configuration
    }
}

extension MacNativeWindowStreamer: SCStreamOutput {
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

extension MacNativeWindowStreamer: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Window capture stopped: \(error.localizedDescription)")
    }
}

/// Publishes the streamable-window inventory and owns the per-window
/// streamers for the active v2 viewer. All stream callbacks are tagged with
/// the window ID so the server can multiplex them over one connection.
final class MacNativeWindowStreamCoordinator {
    nonisolated(unsafe) var onInventoryChanged: (@Sendable ([MacNativeStreamProtocol.WindowInfo]) -> Void)?
    nonisolated(unsafe) var onWindowFormatDescription: (@Sendable (UInt32, Data) -> Void)?
    nonisolated(unsafe) var onWindowFrame: (@Sendable (UInt32, Data, Bool, UInt64, UInt64) -> Void)?
    nonisolated(unsafe) var onWindowClosed: (@Sendable (UInt32, String?) -> Void)?

    /// Encoder budget: at most this many simultaneous window streams.
    static let maxStreams = 6

    private var streamers: [UInt32: MacNativeWindowStreamer] = [:]
    private var targets: [UInt32: MacNativeWindowTarget] = [:]
    private var lastInventory: [MacNativeStreamProtocol.WindowInfo] = []
    private var pollTask: Task<Void, Never>?
    private var generation = 0

    func start() {
        generation += 1
        let myGeneration = generation
        pollTask?.cancel()
        lastInventory = []
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == myGeneration else { return }
                await self.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        lastInventory = []
        let oldStreamers = streamers
        streamers = [:]
        targets = [:]
        Task {
            for streamer in oldStreamers.values {
                await streamer.stop()
            }
        }
    }

    func target(for windowID: UInt32) -> MacNativeWindowTarget? {
        targets[windowID]
    }

    func startStream(windowID: UInt32) {
        guard streamers[windowID] == nil else { return }
        guard streamers.count < Self.maxStreams else {
            onWindowClosed?(windowID, "Window stream limit reached (\(Self.maxStreams)).")
            return
        }
        let generation = generation
        let streamer = MacNativeWindowStreamer(windowID: windowID)
        streamer.onFormatDescription = { [weak self] data in
            self?.onWindowFormatDescription?(windowID, data)
        }
        streamer.onFrame = { [weak self] data, keyFrame, sequence, timestamp in
            self?.onWindowFrame?(windowID, data, keyFrame, sequence, timestamp)
        }
        streamer.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.closeStream(windowID: windowID, reason: message)
            }
        }
        streamers[windowID] = streamer

        Task { [weak self] in
            do {
                guard let window = try await Self.findWindow(windowID) else {
                    throw StreamError.windowGone
                }
                guard let self, self.generation == generation,
                      self.streamers[windowID] === streamer else {
                    await streamer.stop()
                    return
                }
                try await streamer.start(window: window)
                guard self.generation == generation,
                      self.streamers[windowID] === streamer else {
                    await streamer.stop()
                    return
                }
            } catch {
                guard let self, self.streamers[windowID] === streamer else { return }
                self.closeStream(windowID: windowID, reason: error.localizedDescription)
            }
        }
    }

    func stopStream(windowID: UInt32) {
        guard let streamer = streamers.removeValue(forKey: windowID) else { return }
        Task {
            await streamer.stop()
        }
    }

    private func closeStream(windowID: UInt32, reason: String?) {
        guard let streamer = streamers.removeValue(forKey: windowID) else { return }
        Task {
            await streamer.stop()
        }
        onWindowClosed?(windowID, reason)
    }

    private enum StreamError: LocalizedError {
        case windowGone

        var errorDescription: String? {
            "The window is no longer on screen."
        }
    }

    private static func findWindow(_ windowID: UInt32) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        return content.windows.first { $0.windowID == windowID }
    }

    // MARK: - Inventory poll

    private func poll() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        ) else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = content.windows.filter { window in
            window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width >= 64
                && window.frame.height >= 64
                && window.owningApplication != nil
                && window.owningApplication?.processID != ownPID
        }

        let focusedID = Self.frontmostWindowID()
        var inventory: [MacNativeStreamProtocol.WindowInfo] = []
        var newTargets: [UInt32: MacNativeWindowTarget] = [:]
        var byID: [UInt32: SCWindow] = [:]
        for window in candidates {
            let id = UInt32(window.windowID)
            byID[id] = window
            inventory.append(MacNativeStreamProtocol.WindowInfo(
                id: id,
                title: window.title ?? "",
                appName: window.owningApplication?.applicationName ?? "",
                width: window.frame.width,
                height: window.frame.height,
                isFocused: id == focusedID
            ))
            newTargets[id] = MacNativeWindowTarget(
                windowID: id,
                processID: window.owningApplication?.processID ?? 0,
                title: window.title ?? "",
                frame: window.frame,
                pixelScale: streamers[id]?.pixelScale ?? 2
            )
        }
        targets = newTargets

        // Streams whose window vanished (closed, minimized, other Space).
        for windowID in streamers.keys where byID[windowID] == nil {
            closeStream(windowID: windowID, reason: "The window left the screen.")
        }
        // Live streams follow window resizes.
        for (windowID, streamer) in streamers {
            guard let window = byID[windowID] else { continue }
            Task {
                await streamer.update(window: window)
            }
        }

        if inventory != lastInventory {
            lastInventory = inventory
            onInventoryChanged?(inventory)
        }
    }

    /// The frontmost layer-0 window on screen (front-to-back order comes from
    /// the window server, which SCShareableContent doesn't guarantee).
    private static func frontmostWindowID() -> UInt32? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        for entry in info {
            guard let layer = entry[kCGWindowLayer] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID] as? Int32, pid != ownPID,
                  let number = entry[kCGWindowNumber] as? UInt32 else { continue }
            return number
        }
        return nil
    }

    /// Whether `target`'s window is the topmost layer-0 window at `point`
    /// (global CG coordinates) — when it isn't, a click there would land on
    /// whatever occludes it, so the caller should raise the window first.
    static func isTopmost(_ target: MacNativeWindowTarget, at point: CGPoint) -> Bool {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return true }
        for entry in info {
            guard let layer = entry[kCGWindowLayer] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber] as? UInt32,
                  let boundsDict = entry[kCGWindowBounds] as? [String: CGFloat] else { continue }
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            guard bounds.contains(point) else { continue }
            return number == target.windowID
        }
        return true
    }
}
