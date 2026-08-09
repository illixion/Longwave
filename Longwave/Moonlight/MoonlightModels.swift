#if MOONLIGHT_ENABLED
import Foundation

// MARK: - Errors

enum MoonlightError: LocalizedError {
    case serverError(String)
    case pairingFailed(String)
    case notPaired
    case alreadyPairing
    case pinRejected
    case cryptoError(String)
    case networkError(Error)
    case invalidResponse
    case noServerCert

    var errorDescription: String? {
        switch self {
        case .serverError(let msg): return "Server error: \(msg)"
        case .pairingFailed(let msg): return "Pairing failed: \(msg)"
        case .notPaired: return "Not paired with server"
        case .alreadyPairing: return "Server is already in a pairing session"
        case .pinRejected: return "PIN was incorrect"
        case .cryptoError(let msg): return "Crypto error: \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .invalidResponse: return "Invalid server response"
        case .noServerCert: return "No server certificate available"
        }
    }
}

// MARK: - Server Info

struct ServerInfo: Sendable {
    var hostname: String = ""
    var uuid: String = ""
    var mac: String = ""
    var localAddress: String = ""
    var remoteAddress: String = ""
    var pairStatus: Bool = false
    var currentGameId: Int = 0
    var appVersion: String = ""
    var gfeVersion: String = ""
    var gpuModel: String = ""
    var serverCodecModeSupport: Int = 1 // default SCM_H264
    var maxLumaPixelsHEVC: Int = 0
    var httpsPort: UInt16 = 47984
    var externalPort: UInt16 = 47989
    var isNvidiaServerSoftware: Bool = false
    var displayModes: [DisplayMode] = []

    /// Server generation from appVersion (first component of dotted version string)
    nonisolated var serverGeneration: Int {
        guard let first = appVersion.split(separator: ".").first,
              let gen = Int(first) else { return 7 }
        return gen
    }

    /// Whether to use SHA-256 (gen >= 7) or SHA-1 (gen < 7) for pairing
    nonisolated var usesSHA256: Bool {
        serverGeneration >= 7
    }
}

struct DisplayMode: Sendable {
    var width: Int
    var height: Int
    var refreshRate: Int
}

// MARK: - App

struct MoonlightApp: Sendable, Identifiable {
    var id: Int
    var name: String
    var hdrSupported: Bool = false
    var isAppCollectorGame: Bool = false
}

// MARK: - Codec Mode Support Bitmask (matches SCM_* in Limelight.h)

enum ServerCodecMode {
    static let h264:       Int = 0x00000001  // SCM_H264
    static let hevc:       Int = 0x00000100  // SCM_HEVC
    static let hevcMain10: Int = 0x00000200  // SCM_HEVC_MAIN10

    static let av1Main8:   Int = 0x00010000  // SCM_AV1_MAIN8
    static let av1Main10:  Int = 0x00020000  // SCM_AV1_MAIN10
}

// MARK: - Hex Data Extension

extension Data {
    nonisolated var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    nonisolated init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
#endif
