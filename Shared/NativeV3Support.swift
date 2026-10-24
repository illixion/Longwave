import Foundation
import Network
import StreamCrypto
import StreamWire

/// What the v3 host and client drivers share (NATIVE_V3_PROTOCOL.md §7.1:
/// the package is sans-I/O, the Network.framework half lives in the apps).
///
/// The first v3 cut carries the desktop stream and remote input over UDP 4857,
/// beside v2's TCP 4857. Window streams, stills and audio stay on v2 for now.
nonisolated enum NativeV3 {
    /// UDP, on the same number as v2's TCP port.
    static let port = MacNativeStreamProtocol.defaultPort
    /// v2's desktop stream ID, kept so pointer events mean the same thing.
    static let desktopStreamID = MacNativeStreamProtocol.desktopStreamID

    /// Host monotonic ns: the same clock as ScreenCaptureKit's timestamps.
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// The device's v3 key. Only per-device credentials get one: the shared
    /// token from before enrollment has no device ID for the host to look
    /// up, so those devices stay on v2.
    static func psk(for credential: CompanionCredential) -> StreamPSK? {
        guard let deviceID = credential.deviceID, !credential.token.isEmpty else { return nil }
        return StreamPSK(token: credential.token, identity: deviceID)
    }

    static var softwareVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return String("Longwave \(version)".utf8.prefix(HelloLimits.maxSoftwareBytes)) ?? "Longwave"
    }

    /// Trims a display name to the hello's limit on a character boundary.
    static func helloName(_ name: String) -> String {
        var trimmed = ""
        for character in name {
            guard trimmed.utf8.count + String(character).utf8.count <= HelloLimits.maxNameBytes else { break }
            trimmed.append(character)
        }
        return trimmed.isEmpty ? "Longwave" : trimmed
    }

    static func parameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    /// Sends datagrams in one batch (§6.4: one system call per burst where the
    /// stack can).
    static func send(_ datagrams: [[UInt8]], on connection: NWConnection) {
        guard !datagrams.isEmpty else { return }
        connection.batch {
            for datagram in datagrams {
                connection.send(content: Data(datagram), completion: .idempotent)
            }
        }
    }
}

/// A one-shot timer re-armed for an absolute `NativeV3.now()` time: the sans-I/O
/// session says when it next has work, and this wakes the owner then.
nonisolated final class NativeV3Timer: @unchecked Sendable {
    private let source: DispatchSourceTimer
    private var armedFor: UInt64?

    init(queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.setEventHandler(handler: handler)
        source.activate()
    }

    /// Arms for `time` (nil disarms). Pacing needs sub-millisecond wakes, so
    /// the leeway is small.
    func arm(at time: UInt64?) {
        guard time != armedFor else { return }
        armedFor = time
        guard let time else {
            source.schedule(deadline: .distantFuture)
            return
        }
        source.schedule(deadline: DispatchTime(uptimeNanoseconds: max(time, 1)), leeway: .microseconds(100))
    }

    /// The handler ran: the next `arm` must schedule even for the same time.
    func fired() { armedFor = nil }

    func cancel() { source.cancel() }
}
