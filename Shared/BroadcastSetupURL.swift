import Foundation

/// Broadcast server pairing payload, AirDropped from the macOS companion to
/// the Vision Pro as an x-callback URL (same flow as `AudioTokenURL`):
///   longwave://x-callback-url/setBroadcastServer?host=…&port=…&path=…&viewPath=…&user=…&pass=…&fp=…
/// `fp` is the SHA-256 of the mediamtx TLS certificate (DER, hex) — when
/// present the publisher connects with RTSPS and pins that certificate, so
/// the stream is encrypted even off-VPN.
nonisolated struct BroadcastSetup: Sendable, Equatable {
    let host: String
    let port: UInt16
    let streamPath: String
    let viewStreamPath: String
    let username: String
    let password: String
    /// SHA-256 of the server certificate (DER), lowercase hex. nil = plain RTSP.
    let certFingerprintHex: String?
}

nonisolated enum BroadcastSetupURL {
    static let action = "setBroadcastServer"

    static func make(_ setup: BroadcastSetup) -> URL? {
        var components = URLComponents()
        components.scheme = AudioTokenURL.scheme
        components.host = AudioTokenURL.host
        components.path = "/" + action
        var items = [
            URLQueryItem(name: "host", value: setup.host),
            URLQueryItem(name: "port", value: String(setup.port)),
            URLQueryItem(name: "path", value: setup.streamPath),
            URLQueryItem(name: "viewPath", value: setup.viewStreamPath),
            URLQueryItem(name: "user", value: setup.username),
            URLQueryItem(name: "pass", value: setup.password),
        ]
        if let fingerprint = setup.certFingerprintHex, !fingerprint.isEmpty {
            items.append(URLQueryItem(name: "fp", value: fingerprint))
        }
        components.queryItems = items
        return components.url
    }

    static func parse(from url: URL) -> BroadcastSetup? {
        guard AudioTokenURL.accepts(scheme: url.scheme),
              url.host?.lowercased() == AudioTokenURL.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == "/" + action else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value }
        guard let host = values["host"], !host.isEmpty,
              let password = values["pass"], !password.isEmpty else { return nil }
        let fingerprint = values["fp"].flatMap { raw -> String? in
            let normalized = raw.lowercased()
            // 32 bytes of hex; reject anything malformed rather than pinning garbage.
            guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else { return nil }
            return normalized
        }
        return BroadcastSetup(
            host: host,
            port: values["port"].flatMap { UInt16($0) } ?? (fingerprint != nil ? 8322 : 8554),
            streamPath: values["path"].flatMap { $0.isEmpty ? nil : $0 } ?? "visionpro",
            viewStreamPath: values["viewPath"].flatMap { $0.isEmpty ? nil : $0 } ?? "visionpro-view",
            username: values["user"] ?? "",
            password: password,
            certFingerprintHex: fingerprint)
    }
}
