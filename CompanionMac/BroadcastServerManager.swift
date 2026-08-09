import Foundation
import AppKit
import CryptoKit
import Observation
import os

/// One-button mediamtx management for the Vision Pro broadcast feature:
/// generates a publish password + self-signed TLS cert, writes the mediamtx
/// config (RTSPS ingest, localhost-only WHEP output), restarts the brew
/// service, and produces the `longwave://…/setBroadcastServer` pairing URL
/// (host = this Mac's Tailscale IP, credentials, cert fingerprint) for
/// AirDrop to the headset.
///
/// mediamtx itself is a prerequisite (`brew install mediamtx`) — the
/// companion configures it but deliberately doesn't install software.
@Observable
final class BroadcastServerManager {

    static let rtspsPort: UInt16 = 8322

    private(set) var statusText = "Not configured"
    private(set) var lastError: String?
    private(set) var isWorking = false
    private(set) var certFingerprintHex: String?
    private(set) var configuredHost: String?

    private let log = Logger(subsystem: "pro.longwave.companion", category: "BroadcastServer")

    var password: String = BroadcastServerManager.loadOrCreatePassword() {
        didSet { UserDefaults.standard.set(password, forKey: "broadcastPublishPassword") }
    }

    // OBS integration (obs-websocket v5 on localhost)
    private(set) var obsStatusText: String?
    private(set) var isOBSWorking = false
    var obsPassword: String = UserDefaults.standard.string(forKey: "obsWebSocketPassword") ?? "" {
        didSet { UserDefaults.standard.set(obsPassword, forKey: "obsWebSocketPassword") }
    }

    /// WHEP page URL for a stream path: controls hidden, UNMUTED — the page's
    /// video element must be unmuted for audio to exist; "Control audio via
    /// OBS" (reroute_audio) then keeps it in the mixer instead of the
    /// speakers.
    static func browserSourceURL(path: String) -> String {
        "http://127.0.0.1:8889/\(path)?controls=false&muted=false"
    }

    /// Creates/updates the two Browser Sources in OBS's current scene via
    /// obs-websocket (Tools → WebSocket Server Settings must be enabled).
    func addSourcesToOBS() {
        guard !isOBSWorking else { return }
        isOBSWorking = true
        obsStatusText = nil
        // No stored password → try the clipboard: OBS's "Show Connect Info"
        // dialog has a Copy Password button, so the natural flow is copy →
        // click here. Persisted only after a successful connect.
        var password = obsPassword
        var passwordFromClipboard = false
        if password.isEmpty,
           let clipboard = NSPasteboard.general.string(forType: .string)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !clipboard.isEmpty, clipboard.count <= 64, !clipboard.contains(where: \.isWhitespace) {
            password = clipboard
            passwordFromClipboard = true
        }
        Task { @MainActor in
            defer { isOBSWorking = false }
            do {
                try await OBSWebSocketClient.ensureBrowserSources(
                    password: password.isEmpty ? nil : password,
                    sources: [
                        // Bottom → top: camera ends up on top and visible;
                        // view starts hidden (its dead-stream error page
                        // would obscure the camera otherwise).
                        .init(name: "Vision Pro View",
                              url: Self.browserSourceURL(path: "visionpro-view"), visible: false),
                        .init(name: "Vision Pro Camera",
                              url: Self.browserSourceURL(path: "visionpro"), visible: true),
                    ])
                if passwordFromClipboard { obsPassword = password }
                obsStatusText = "OBS scene set up: \"Vision Pro Camera\" visible, \"Vision Pro View\" hidden — toggle its eye icon when view sharing."
            } catch {
                obsStatusText = error.localizedDescription
            }
        }
    }

    init() {
        refreshStatus()
    }

    var mediamtxInstalled: Bool { Self.mediamtxBinary() != nil }

    var shareURL: URL? {
        guard let host = configuredHost, let fingerprint = certFingerprintHex else { return nil }
        return BroadcastSetupURL.make(BroadcastSetup(
            host: host, port: Self.rtspsPort,
            streamPath: "visionpro", viewStreamPath: "visionpro-view",
            username: "visionpro", password: password,
            certFingerprintHex: fingerprint))
    }

    func refreshStatus() {
        guard let binary = Self.mediamtxBinary() else {
            statusText = "mediamtx not found — brew install mediamtx"
            configuredHost = nil
            return
        }
        certFingerprintHex = try? Self.certificateFingerprint(at: Self.certDirectory())
        let configured = (try? String(contentsOf: Self.configPath(forBinary: binary), encoding: .utf8))?
            .hasPrefix(Self.configMarker) ?? false
        configuredHost = configured ? Self.tailscaleIPv4() : nil
        statusText = configured
            ? (configuredHost != nil ? "Configured · Tailscale \(configuredHost!)" : "Configured · Tailscale IP not found")
            : "mediamtx found — not yet configured"
    }

    /// Generates password/cert as needed, writes the managed mediamtx config,
    /// and restarts the brew service.
    func setUpServer() {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        statusText = "Configuring…"
        let password = password
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<String, Error> = Result {
                try Self.performSetup(password: password)
            }
            await MainActor.run {
                guard let self else { return }
                self.isWorking = false
                switch result {
                case .success(let fingerprint):
                    self.certFingerprintHex = fingerprint
                    self.refreshStatus()
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    self.statusText = "Setup failed"
                }
            }
        }
    }

    // MARK: - Setup steps (background thread)

    private nonisolated static let configMarker = "# Managed by Longwave Companion"

    enum SetupError: LocalizedError {
        case mediamtxMissing
        case commandFailed(String, String)
        case certificateUnreadable

        var errorDescription: String? {
            switch self {
            case .mediamtxMissing:
                "mediamtx is not installed — run: brew install mediamtx"
            case .commandFailed(let command, let output):
                "\(command) failed: \(output)"
            case .certificateUnreadable:
                "Could not read the generated TLS certificate"
            }
        }
    }

    private nonisolated static func performSetup(password: String) throws -> String {
        guard let binary = mediamtxBinary() else { throw SetupError.mediamtxMissing }
        let certDir = certDirectory()
        try FileManager.default.createDirectory(at: certDir, withIntermediateDirectories: true)

        // Self-signed cert (10 y). Trust comes from fingerprint pinning on
        // the headset, not from the subject or a CA.
        let keyPath = certDir.appendingPathComponent("server.key").path
        let certPath = certDir.appendingPathComponent("server.crt").path
        if !FileManager.default.fileExists(atPath: keyPath) || !FileManager.default.fileExists(atPath: certPath) {
            try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048",
                                         "-keyout", keyPath, "-out", certPath,
                                         "-days", "3650", "-nodes",
                                         "-subj", "/CN=Longwave Broadcast"])
        }
        guard let fingerprint = try certificateFingerprint(at: certDir) else {
            throw SetupError.certificateUnreadable
        }

        let configURL = configPath(forBinary: binary)
        if let existing = try? String(contentsOf: configURL, encoding: .utf8),
           !existing.hasPrefix(configMarker) {
            // Preserve whatever was there before we first took over.
            let backup = configURL.appendingPathExtension("pre-longwave")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: configURL, to: backup)
            }
        }
        try configContents(password: password, keyPath: keyPath, certPath: certPath)
            .write(to: configURL, atomically: true, encoding: .utf8)

        let brew = URL(fileURLWithPath: binary).deletingLastPathComponent()
            .appendingPathComponent("brew").path
        try run(brew, ["services", "restart", "mediamtx"])
        return fingerprint
    }

    private nonisolated static func configContents(password: String, keyPath: String, certPath: String) -> String {
        """
        \(configMarker) — the "Set Up Broadcast Server" button regenerates this file.
        # Previous config (if any) was backed up as mediamtx.yml.pre-longwave.

        logLevel: info

        # RTSPS ingest: the Vision Pro publishes here (TLS, cert pinned on the
        # headset via the AirDropped pairing link).
        rtsp: yes
        rtspTransports: [tcp]
        rtspEncryption: strict
        rtspsAddress: :\(rtspsPort)
        rtspServerKey: \(keyPath)
        rtspServerCert: \(certPath)

        # WebRTC output, localhost only: add OBS Browser Sources at
        #   http://127.0.0.1:8889/visionpro?controls=false&muted=false
        #   http://127.0.0.1:8889/visionpro-view?controls=false&muted=false
        # (enable "Control audio via OBS" on each source for mixer audio —
        # or use the companion's "Add Sources to OBS" button)
        webrtc: yes
        webrtcAddress: 127.0.0.1:8889
        webrtcLocalUDPAddress: 127.0.0.1:8189

        rtmp: no
        hls: no
        srt: no
        api: no
        metrics: no
        playback: no

        # Reads only from this Mac (OBS); publishing requires credentials.
        authInternalUsers:
          - user: any
            ips: ['127.0.0.1', '::1']
            permissions:
              - action: read
          - user: visionpro
            pass: \(password)
            permissions:
              - action: publish
                path: visionpro
              - action: publish
                path: visionpro-view

        paths:
          visionpro:
          visionpro-view:
        """
    }

    // MARK: - Helpers

    private nonisolated static func mediamtxBinary() -> String? {
        ["/opt/homebrew/bin/mediamtx", "/usr/local/bin/mediamtx"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func configPath(forBinary binary: String) -> URL {
        // brew prefix derived from the binary location (…/bin/mediamtx).
        URL(fileURLWithPath: binary)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("etc/mediamtx/mediamtx.yml")
    }

    private nonisolated static func certDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Longwave Companion/broadcast", isDirectory: true)
    }

    /// SHA-256 (hex) of the certificate's DER bytes — what the headset pins.
    private nonisolated static func certificateFingerprint(at directory: URL) throws -> String? {
        let pem = try String(contentsOf: directory.appendingPathComponent("server.crt"), encoding: .utf8)
        guard let body = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").last?
                .components(separatedBy: "-----END CERTIFICATE-----").first,
              let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func loadOrCreatePassword() -> String {
        if let existing = UserDefaults.standard.string(forKey: "broadcastPublishPassword"), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let password = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        UserDefaults.standard.set(password, forKey: "broadcastPublishPassword")
        return password
    }

    /// This Mac's Tailscale IPv4 (CGNAT range 100.64.0.0/10), if any.
    private nonisolated static func tailscaleIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
            let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
            // 100.64.0.0/10
            if (ip & 0xFFC0_0000) == 0x6440_0000 {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sinAddr = sin.sin_addr
                inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buffer)
            }
        }
        return nil
    }

    @discardableResult
    private nonisolated static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SetupError.commandFailed((launchPath as NSString).lastPathComponent, output.suffix(300).description)
        }
        return output
    }
}
