import Foundation
import Observation
import UIKit

/// The Mac's desktop as long-polled JPEG stills over `WatchLinkProtocol` —
/// plain `URLSession`, so it works on whatever route watchOS picks, including
/// the paired iPhone's Bluetooth link. One request is in flight at a time, and
/// that is the pacing: the Mac answers as soon as the screen changes (or at
/// once, for a new viewport) and the next request goes out on arrival.
@Observable
final class WatchDesktop {
    enum State: Equatable {
        case idle
        case connecting
        case live
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var image: UIImage?
    /// The region `image` shows — lags the viewport while a sharper picture of
    /// a new one is on its way, so the view can transform the old one.
    private(set) var imageRegion = WatchLinkProtocol.Viewport()
    /// Width ÷ height of the Mac's display, from the first picture on.
    private(set) var displayAspect: Double = 16.0 / 10.0
    /// Seconds the last still took to arrive after it was requested.
    private(set) var lastRoundTrip: Double?

    @ObservationIgnored private var host: WatchHostStore.Host?
    @ObservationIgnored private var key = WatchLinkProtocol.key(token: "")
    @ObservationIgnored private var wanted = WatchLinkProtocol.Viewport()
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<Void, Error>?
    @ObservationIgnored private var viewportChanged = true
    @ObservationIgnored private var pendingViewport: Task<Void, Never>?

    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = WatchLinkProtocol.longPollSeconds + 10
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func start(host: WatchHostStore.Host) {
        stop()
        self.host = host
        key = WatchLinkProtocol.key(token: host.token)
        state = .connecting
        viewportChanged = true
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        inFlight?.cancel()
        pendingViewport?.cancel()
        loop = nil
        inFlight = nil
        state = .idle
    }

    /// Asks for a new region. Coalesced, so a drag doesn't send a request per
    /// touch event; the waiting long-poll is dropped for the new one.
    func request(_ viewport: WatchLinkProtocol.Viewport) {
        guard viewport != wanted else { return }
        wanted = viewport
        pendingViewport?.cancel()
        pendingViewport = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            self.viewportChanged = true
            self.inFlight?.cancel()
        }
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            let viewport = wanted
            let after = viewportChanged ? 0 : sequence
            viewportChanged = false
            let attempt = Task { try await self.fetch(viewport: viewport, after: after) }
            inFlight = attempt
            do {
                try await attempt.value
                failures = 0
            } catch where Self.isCancellation(error) {
                continue
            } catch {
                failures += 1
                if case .failed = state {} else if failures >= 2 || image == nil {
                    state = .failed(Self.describe(error))
                }
                try? await Task.sleep(for: .seconds(min(8, failures * 2)))
            }
        }
    }

    private func fetch(viewport: WatchLinkProtocol.Viewport, after: UInt64) async throws {
        guard let host else { return }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.address
        components.port = Int(WatchLinkProtocol.defaultPort)
        components.path = WatchLinkProtocol.stillPath
        components.queryItems = viewport.queryItems + [URLQueryItem(name: "after", value: String(after))]
        guard let url = components.url, let target = components.percentEncodedPathAndQuery else {
            throw WatchLinkError.badAddress
        }
        let authorization = WatchLinkProtocol.authorize(method: "GET", target: target, key: key)
        var request = URLRequest(url: url)
        request.setValue(authorization.headerValue, forHTTPHeaderField: "Authorization")

        let started = Date()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            guard let plain = WatchLinkProtocol.open(data, nonce: authorization.nonce, key: key),
                  let still = WatchLinkProtocol.Still(decoding: plain),
                  let picture = UIImage(data: still.jpeg) else { throw WatchLinkError.badResponse }
            sequence = still.sequence
            image = picture
            imageRegion = viewport
            if still.sourceHeight > 0 {
                displayAspect = Double(still.sourceWidth) / Double(still.sourceHeight)
            }
            lastRoundTrip = Date().timeIntervalSince(started)
            state = .live
        case 204:
            if image != nil { state = .live }
        case 401:
            throw WatchLinkError.unauthorized
        default:
            throw WatchLinkError.badResponse
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case WatchLinkError.unauthorized:
            return "The Mac rejected this watch's token. Pair again from Longwave on iPhone."
        case WatchLinkError.badAddress:
            return "The Mac's address isn't valid."
        case WatchLinkError.badResponse:
            return "The Mac sent something unexpected. Update Longwave Companion."
        case let error as URLError where error.code == .cannotConnectToHost:
            return "Longwave Companion isn't streaming on the Mac."
        default:
            return "Can't reach the Mac: \(error.localizedDescription)"
        }
    }
}

enum WatchLinkError: Error {
    case unauthorized
    case badAddress
    case badResponse
}

private extension URLComponents {
    /// The request target exactly as it goes on the wire — what the MAC covers.
    var percentEncodedPathAndQuery: String? {
        guard let query = percentEncodedQuery else { return percentEncodedPath }
        return percentEncodedPath + "?" + query
    }
}
