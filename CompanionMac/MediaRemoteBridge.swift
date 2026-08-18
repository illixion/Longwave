import Foundation
import os

/// System-wide now-playing metadata, for *any* player — Music.app (local files
/// and Apple Music streaming alike), Spotify, video in Safari/Chrome/Firefox,
/// podcasts. This is the data behind the macOS menu bar's Now Playing widget.
///
/// Reading it needs a detour. Since macOS 15.4 the private MediaRemote
/// framework answers only processes whose code-signing identifier begins with
/// `com.apple.`; an ordinary app gets `Operation not permitted` and empty
/// metadata. So the actual reading happens inside `/usr/bin/perl` — an Apple
/// platform binary, identifier `com.apple.perl` — which loads our
/// `longwave-mediaremote.dylib` and streams newline-delimited JSON back over a
/// pipe. Longwave itself never loads that dylib or links MediaRemote.
///
/// Two consequences worth knowing:
///
/// - This rides on a private framework, so treat it as breakable. Everything
///   here degrades to `isAvailable == false`, and `NowPlayingCoordinator` falls
///   back to `MusicAppBridge`'s AppleScript path.
/// - Apple deprecated the bundled scripting runtimes back in macOS 10.15. If
///   `/usr/bin/perl` ever disappears, this reports unavailable on launch and
///   the fallback takes over.
final class MediaRemoteBridge {

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "pro.longwave.companion",
        category: "MediaRemote"
    )

    private static let perlPath = "/usr/bin/perl"
    private static let helperResource = "longwave-mediaremote"
    private static let streamSymbol = "longwave_mediaremote_stream"
    private static let sendSymbol = "longwave_mediaremote_send"

    /// Loads the helper and calls into it as an XS sub.
    ///
    /// The `dl_install_xsub` step matters: the entry point has to run *after*
    /// `dl_load_file` returns. Calling it from a library constructor instead
    /// leaves dyld's loader lock held, and MediaRemote's reply path lazily loads
    /// further images — so the completion blocks deadlock and never fire, which
    /// looks identical to being denied permission.
    private static let hostScript = """
    require DynaLoader;
    my ($lib, $symbol) = @ARGV;
    my $handle = DynaLoader::dl_load_file($lib, 0)
      or die "cannot load $lib\\n";
    my $address = DynaLoader::dl_find_symbol($handle, $symbol)
      or die "symbol $symbol not found\\n";
    DynaLoader::dl_install_xsub("main::entry", $address);
    main::entry();
    """

    /// How long the helper gets to produce its `ready` line before we treat the
    /// MediaRemote route as broken and let the fallback take over.
    private static let readyTimeout: Duration = .seconds(5)
    private static let maxRestarts = 3

    /// Fires with the new state and, when the artwork changed, freshly scaled
    /// JPEG data (nil = artwork unchanged, matching `MusicAppBridge`).
    var onNowPlaying: ((NowPlayingInfo?, Data?) -> Void)?
    /// Fires when the helper becomes usable, or gives up.
    var onAvailabilityChange: ((Bool) -> Void)?

    private(set) var current: NowPlayingInfo?
    /// True once the helper has confirmed it can talk to MediaRemote.
    private(set) var isAvailable = false

    /// Bundle identifier of the app that currently owns Now Playing, when known.
    private(set) var sourceBundleID: String?

    private var process: Process?
    /// Held for the lifetime of the child: the helper watches its stdin for EOF
    /// so it exits if the companion dies without reaping it.
    private var stdinPipe: Pipe?
    private var wantsRunning = false
    private var restartCount = 0
    private var readyTask: Task<Void, Never>?

    private let parseQueue = DispatchQueue(label: "pro.longwave.mediaremote.parse")

    /// Absolute path to the bundled helper, or nil if it isn't in the app.
    private var helperPath: String? {
        Bundle.main.url(forResource: Self.helperResource, withExtension: "dylib")?.path
    }

    // MARK: - Lifecycle

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        restartCount = 0
        launch()
    }

    func stop() {
        wantsRunning = false
        readyTask?.cancel()
        readyTask = nil
        terminateChild()
        current = nil
        sourceBundleID = nil
        setAvailable(false)
    }

    private func terminateChild() {
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        stdinPipe = nil
    }

    private func launch() {
        guard wantsRunning else { return }

        guard FileManager.default.isExecutableFile(atPath: Self.perlPath) else {
            Self.log.log("\(Self.perlPath, privacy: .public) missing — using AppleScript fallback")
            setAvailable(false)
            return
        }
        guard let helperPath else {
            Self.log.log("longwave-mediaremote.dylib not bundled — using AppleScript fallback")
            setAvailable(false)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.perlPath)
        task.arguments = ["-e", Self.hostScript, helperPath, Self.streamSymbol]

        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        task.standardOutput = output
        task.standardError = errors
        task.standardInput = input

        let accumulator = LineAccumulator()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // Parsing and artwork re-encoding happen here, off the main thread;
            // only the finished snapshot is handed back.
            for line in accumulator.take(chunk) {
                guard let update = HelperUpdate(line: line) else { continue }
                Task { @MainActor [weak self] in
                    self?.handle(update)
                }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let text = String(data: chunk, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return }
            Self.log.log("helper stderr: \(text, privacy: .public)")
        }

        task.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.handleTermination(status: finished.terminationStatus)
            }
        }

        do {
            try task.run()
        } catch {
            Self.log.error("failed to launch helper: \(error.localizedDescription, privacy: .public)")
            setAvailable(false)
            return
        }

        process = task
        stdinPipe = input

        // If the helper can't reach MediaRemote it simply never reports ready.
        readyTask?.cancel()
        readyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.readyTimeout)
            guard !Task.isCancelled, let self, !self.isAvailable else { return }
            Self.log.log("helper did not report ready — using AppleScript fallback")
            self.setAvailable(false)
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        stdinPipe = nil
        guard wantsRunning else { return }

        // Exit code 2 is the helper telling us MediaRemote is unreachable;
        // restarting would just fail again.
        guard status != 2 else {
            Self.log.log("helper reports MediaRemote unavailable — using AppleScript fallback")
            setAvailable(false)
            return
        }
        guard restartCount < Self.maxRestarts else {
            Self.log.log("helper exited \(status) too often — using AppleScript fallback")
            setAvailable(false)
            return
        }

        restartCount += 1
        let delay = Duration.seconds(1 << (restartCount - 1))
        Self.log.log("helper exited \(status); restart \(self.restartCount) in \(delay.components.seconds)s")
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.wantsRunning else { return }
            self.launch()
        }
    }

    private func setAvailable(_ available: Bool) {
        guard available != isAvailable else { return }
        isAvailable = available
        onAvailabilityChange?(available)
    }

    // MARK: - Updates

    private func handle(_ update: HelperUpdate) {
        switch update {
        case .ready:
            readyTask?.cancel()
            readyTask = nil
            // A working helper resets the restart budget, so a one-off crash
            // days into a session doesn't count against a later one.
            restartCount = 0
            setAvailable(true)

        case .cleared:
            sourceBundleID = nil
            guard current != nil else { return }
            current = nil
            onNowPlaying?(nil, nil)

        case let .playing(info, artwork, bundleID):
            sourceBundleID = bundleID
            current = info
            onNowPlaying?(info, artwork)
        }
    }

    // MARK: - Transport

    /// Sends a transport command to whichever app owns Now Playing — which is
    /// why this beats the AppleScript path: it reaches Spotify and browsers, not
    /// just Music.app.
    ///
    /// Waits for the helper to exit and reports whether it actually succeeded,
    /// so the caller can fall back. Launching successfully is not evidence the
    /// command worked, and treating it as such is exactly how a dead play button
    /// hides: the helper exits 1 when MediaRemote refuses the command and 2 when
    /// it can't reach MediaRemote at all.
    func send(_ command: MediaCommand) async -> Bool {
        guard isAvailable, let helperPath else { return false }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.perlPath)
        task.arguments = ["-e", Self.hostScript, helperPath, Self.sendSymbol]
        var environment = ProcessInfo.processInfo.environment
        environment["LW_MR_COMMAND"] = command.rawValue
        task.environment = environment
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            task.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try task.run()
            } catch {
                task.terminationHandler = nil
                let reason = error.localizedDescription
                Self.log.error("transport \(command.rawValue, privacy: .public) failed to launch: \(reason, privacy: .public)")
                continuation.resume(returning: false)
            }
        }
    }
}

// MARK: - Wire format

/// One decoded line of the helper's NDJSON stream.
private enum HelperUpdate {
    case ready
    case cleared
    case playing(NowPlayingInfo, artwork: Data?, bundleID: String?)

    /// Decoded on the parse queue, artwork re-encoding included.
    init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        if object["ready"] as? Bool == true { self = .ready; return }
        if object["none"] as? Bool == true { self = .cleared; return }
        guard let title = object["title"] as? String else { return nil }

        // The helper sends artwork bytes only when the image actually changed,
        // which is the same "nil means unchanged" contract MusicAppBridge uses.
        var artwork: Data?
        if let base64 = object["artwork"] as? String,
           let raw = Data(base64Encoded: base64) {
            artwork = NowPlayingArtwork.scaledJPEG(from: raw)
        }

        var info = NowPlayingInfo(
            title: title,
            artist: object["artist"] as? String,
            album: object["album"] as? String,
            isPlaying: object["playing"] as? Bool ?? false,
            durationSeconds: object["duration"] as? Double,
            elapsedSeconds: object["elapsed"] as? Double,
            artworkID: object["artworkKey"] as? String
        )
        // Never advertise artwork we failed to decode: the receiver pairs the
        // id with a cached image and would show the previous track's cover.
        if artwork == nil, object["artwork"] != nil { info.artworkID = nil }

        self = .playing(info, artwork: artwork, bundleID: object["bundleID"] as? String)
    }
}

/// Splits the child's byte stream into newline-delimited lines. Confined to the
/// bridge's parse queue, which is why it can be `nonisolated` and mutable.
private nonisolated final class LineAccumulator {
    private var buffer = Data()
    /// Guards against a wedged child growing the buffer without bound; a real
    /// line is at most a few hundred KB of base64 artwork.
    private static let maxBuffered = 8 * 1024 * 1024

    func take(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > Self.maxBuffered { buffer.removeAll(keepingCapacity: false) }
        return lines
    }
}
