import CryptoKit
import Foundation

/// The Apple Watch's any-route lane: plain HTTP to the Companion, carried by
/// `URLSession` over whatever route watchOS picks (often the paired iPhone's
/// Bluetooth link). See `WATCH_STREAMING_PLAN.md` for why it is not the TLS-PSK
/// Native stream: watchOS blocks Network framework outside an audio session.
///
/// HTTP has no pre-shared-key TLS and there is no CA to pin against, so the
/// pairing token secures it at the application layer instead:
/// - every request carries `Authorization: LW1 <unix-ms>.<nonce>.<mac>`, an
///   HMAC over the method, path + query, time and nonce; the Companion
///   rejects stale times and replayed nonces;
/// - every response body is an AES-GCM sealed box whose additional data is the
///   request's nonce, so a response cannot be replayed onto another request.
nonisolated enum WatchLinkProtocol {
    static let defaultPort: UInt16 = 4858
    static let scheme = "LW1"
    /// How far a request's clock may be from the Mac's.
    static let maxClockSkewMilliseconds: Int64 = 30_000
    /// How long the Mac holds a still request open waiting for a change.
    static let longPollSeconds: Double = 10
    static let stillPath = "/v1/still"

    static func key(token: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
            salt: Data("Longwave-Watch-v1".utf8),
            info: Data("http".utf8),
            outputByteCount: 32
        )
    }

    struct Authorization: Equatable, Sendable {
        let milliseconds: Int64
        let nonce: String
        let mac: Data

        var headerValue: String {
            "\(WatchLinkProtocol.scheme) \(milliseconds).\(nonce).\(mac.watchLinkBase64)"
        }

        init(milliseconds: Int64, nonce: String, mac: Data) {
            self.milliseconds = milliseconds
            self.nonce = nonce
            self.mac = mac
        }

        init?(headerValue: String) {
            let parts = headerValue.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == WatchLinkProtocol.scheme else { return nil }
            let fields = parts[1].split(separator: ".")
            guard fields.count == 3,
                  let milliseconds = Int64(fields[0]),
                  !fields[1].isEmpty, fields[1].count <= 64,
                  let mac = Data(watchLinkBase64: String(fields[2])) else { return nil }
            self.init(milliseconds: milliseconds, nonce: String(fields[1]), mac: mac)
        }
    }

    private static func macInput(method: String, target: String, milliseconds: Int64, nonce: String) -> Data {
        Data("\(method)\n\(target)\n\(milliseconds)\n\(nonce)".utf8)
    }

    /// `target` is the request's path and query exactly as sent.
    static func authorize(
        method: String,
        target: String,
        key: SymmetricKey,
        now: Date = Date()
    ) -> Authorization {
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        let nonce = Data(AES.GCM.Nonce().withUnsafeBytes { Data($0) }).watchLinkBase64
        let mac = HMAC<SHA256>.authenticationCode(
            for: macInput(method: method, target: target, milliseconds: milliseconds, nonce: nonce),
            using: key
        )
        return Authorization(milliseconds: milliseconds, nonce: nonce, mac: Data(mac))
    }

    /// Checks the MAC and the clock. Replay of a nonce is the caller's to track.
    static func verify(
        _ authorization: Authorization,
        method: String,
        target: String,
        key: SymmetricKey,
        now: Date = Date()
    ) -> Bool {
        let skew = Int64(now.timeIntervalSince1970 * 1000) - authorization.milliseconds
        guard abs(skew) <= maxClockSkewMilliseconds else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            authorization.mac,
            authenticating: macInput(
                method: method,
                target: target,
                milliseconds: authorization.milliseconds,
                nonce: authorization.nonce
            ),
            using: key
        )
    }

    static func seal(_ body: Data, nonce: String, key: SymmetricKey) -> Data? {
        try? AES.GCM.seal(body, using: key, authenticating: Data(nonce.utf8)).combined
    }

    static func open(_ sealed: Data, nonce: String, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Data(nonce.utf8))
    }

    // MARK: - Stills

    /// The part of the desktop the watch shows, in 0…1 fractions of the
    /// display, and the pixel size it wants the picture at.
    struct Viewport: Equatable, Sendable {
        var x: Double = 0
        var y: Double = 0
        var width: Double = 1
        var height: Double = 1
        var pixelWidth: Int = 396
        var pixelHeight: Int = 484
        var quality: Int = 60

        var queryItems: [URLQueryItem] {
            func fraction(_ value: Double) -> String { String(format: "%.4f", min(1, max(0, value))) }
            return [
                URLQueryItem(name: "x", value: fraction(x)),
                URLQueryItem(name: "y", value: fraction(y)),
                URLQueryItem(name: "w", value: fraction(width)),
                URLQueryItem(name: "h", value: fraction(height)),
                URLQueryItem(name: "pw", value: String(pixelWidth)),
                URLQueryItem(name: "ph", value: String(pixelHeight)),
                URLQueryItem(name: "q", value: String(quality)),
            ]
        }

        init(
            x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1,
            pixelWidth: Int = 396, pixelHeight: Int = 484, quality: Int = 60
        ) {
            self.x = x; self.y = y; self.width = width; self.height = height
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.quality = quality
        }

        init?(query: [String: String]) {
            guard let x = query["x"].flatMap(Double.init), let y = query["y"].flatMap(Double.init),
                  let width = query["w"].flatMap(Double.init), let height = query["h"].flatMap(Double.init),
                  let pixelWidth = query["pw"].flatMap(Int.init), let pixelHeight = query["ph"].flatMap(Int.init),
                  (0...1).contains(x), (0...1).contains(y),
                  width > 0, width <= 1, height > 0, height <= 1,
                  (16...1024).contains(pixelWidth), (16...1024).contains(pixelHeight) else { return nil }
            self.init(
                x: x, y: y, width: width, height: height,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                quality: min(100, max(1, query["q"].flatMap(Int.init) ?? 60))
            )
        }

        /// The Native stream's encoding of the same region, for the shared
        /// still encoder.
        var stillViewport: MacNativeStreamProtocol.StillViewport {
            func word(_ value: Double) -> UInt16 { UInt16(clamping: Int((min(1, max(0, value)) * 65535).rounded())) }
            return MacNativeStreamProtocol.StillViewport(
                x: word(x), y: word(y), width: max(1, word(width)), height: max(1, word(height)),
                outputWidth: UInt16(clamping: pixelWidth), outputHeight: UInt16(clamping: pixelHeight),
                quality: UInt8(clamping: quality)
            )
        }
    }

    /// The still response's plaintext: sequence, the display's pixel size,
    /// then the JPEG.
    struct Still: Equatable, Sendable {
        var sequence: UInt64
        var sourceWidth: Int
        var sourceHeight: Int
        var jpeg: Data

        static let headerSize = 12

        func encoded() -> Data {
            var data = Data(capacity: Self.headerSize + jpeg.count)
            withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(clamping: sourceWidth).littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(clamping: sourceHeight).littleEndian) { data.append(contentsOf: $0) }
            data.append(jpeg)
            return data
        }

        init(sequence: UInt64, sourceWidth: Int, sourceHeight: Int, jpeg: Data) {
            self.sequence = sequence
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            self.jpeg = jpeg
        }

        init?(decoding data: Data) {
            guard data.count > Self.headerSize else { return nil }
            let bytes = [UInt8](data.prefix(Self.headerSize))
            var sequence: UInt64 = 0
            for index in 0..<8 { sequence |= UInt64(bytes[index]) << (8 * index) }
            self.sequence = sequence
            self.sourceWidth = Int(UInt16(bytes[8]) | UInt16(bytes[9]) << 8)
            self.sourceHeight = Int(UInt16(bytes[10]) | UInt16(bytes[11]) << 8)
            self.jpeg = Data(data.dropFirst(Self.headerSize))
        }
    }
}

private nonisolated extension Data {
    var watchLinkBase64: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(watchLinkBase64 string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
