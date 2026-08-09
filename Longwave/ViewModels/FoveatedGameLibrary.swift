//  FoveatedGameLibrary.swift
//
//  The headset's view of the PC's game library: the titles the user curated in
//  the Windows companion app, their cover art, and the ability to start one.
//
//  Transport is the bridge's TCP control link (`BridgeControlLink`, owned by the
//  sender). The CloudXR message channel only carries the rendezvous — the host's
//  addresses and a session token — because a channel connection lasts about twelve
//  seconds on that host and cannot carry anything continuous. The host relays each
//  request to the companion backend and chunks the JSON back. See
//  GameLibraryProtocol.swift for the framing.
//
//  This ran over UDP until 2026-07-28, which cover art in particular could not
//  afford: a cover is ~24 chunks and a gap fails the whole response, so one lost
//  datagram lost the picture. Request/response traffic wants ordered delivery.
//
//  Everything here is a *cache* of host state. There is no local persistence and
//  no local mutation: curation happens on the PC, and this reloads whenever the
//  link comes up.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import OSLog
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@Observable
final class FoveatedGameLibrary {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var titles: [GameLibraryTitle] = []
    private(set) var state: LoadState = .idle
    /// Decoded cover art by title id. Only titles the gallery has actually shown
    /// are fetched — a full library is around a megabyte of jpeg, and the covers
    /// share the network with an 83 Hz input stream.
    private(set) var art: [String: Image] = [:]
    /// Titles whose art came back missing or unreadable. Tracked so the gallery
    /// stops re-asking for a cover that does not exist.
    private(set) var artUnavailable: Set<String> = []
    /// Set while a launch is in flight, so the gallery can show which tile is starting.
    private(set) var launching: String?
    private(set) var lastLaunchError: String?
    /// Changes only after the host confirms a launch, allowing the presenting sheet to
    /// close without hiding failures the user still needs to read.
    private(set) var lastSuccessfulLaunchID: String?

    private let log = Logger(subsystem: "pro.longwave", category: "GameLibrary")

    private weak var bridge: ControllerBridgeSender?
    /// The sender's control link. Nil-safe via `bridge`, which owns it.
    private var link: BridgeControlLink? { bridge?.control }
    /// Request ids start at 1: 0 is reserved.
    private var nextRequestId: UInt32 = 1
    private var artInFlight: Set<String> = []
    /// Title ids waiting their turn. One art response at a time — see `loadArt`.
    private var artQueue: [String] = []
    private var artTimeoutTask: Task<Void, Never>?
    /// request id → title id, so an art response can be filed without the body
    /// having to be trusted for routing.
    private var artRequests: [UInt32: String] = [:]
    /// Titles whose art request already timed out once. A timeout is a transport
    /// fact (a host restart, a rekey window), not a statement about the art — so
    /// the first one earns a retry, and only the second marks the cover
    /// unavailable for the session.
    private var artTimedOut: Set<String> = []
    private var pendingLaunches: Set<UInt32> = []
    private var listRequest: UInt32?
    private var loadTask: Task<Void, Never>?

    // MARK: Wiring

    /// Attach to the bridge that owns the channel. Called by the connection
    /// manager for each session; re-attaching resets everything in flight.
    func attach(to bridge: ControllerBridgeSender) {
        self.bridge = bridge
        artInFlight.removeAll()
        artQueue.removeAll()
        artTimeoutTask?.cancel()
        artRequests.removeAll()
        artTimedOut.removeAll()
        pendingLaunches.removeAll()
        listRequest = nil
        loadTask?.cancel()

        bridge.control.onResponse = { [weak self] done in self?.receive(done) }
        // A connected control link is the first moment a request can succeed, and a
        // reconnect means the host may have restarted — so re-ask on both. The sender
        // adopts the rendezvous and owns the link; the library is a client of it.
        bridge.onControlReady = { [weak self] _ in self?.refresh() }
        bridge.onChannelAttached = nil
    }

    func detach() {
        loadTask?.cancel()
        loadTask = nil
        artTimeoutTask?.cancel()
        artTimeoutTask = nil
        artQueue.removeAll()
        artTimedOut.removeAll()
        bridge?.control.onResponse = nil
        bridge?.onControlReady = nil
        bridge?.onChannelAttached = nil
        bridge = nil
        state = .idle
        titles = []
        art = [:]
        artUnavailable = []
        launching = nil
        lastSuccessfulLaunchID = nil
    }

    // MARK: Requests

    /// Ask the host for the list, waiting for the link if it is not up yet.
    ///
    /// The waiting is the point, and it is not a short wait. Nothing exists until
    /// the session broker is running on the host, the broker's channel has
    /// connected once, its rendezvous has arrived, and one of the announced
    /// addresses has answered a probe. Any of those can be seconds out, so a single
    /// attempt loses the race routinely.
    func refresh() {
        guard bridge != nil else { return }
        state = .loading
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.channelWaitSeconds)
            while !Task.isCancelled {
                guard self.bridge != nil else { return }
                if self.link?.isReady == true {
                    let id = self.takeRequestId()
                    self.listRequest = id
                    if self.link?.send(op: .listRequest, requestId: id) == true {
                        // Time it out: UDP can lose the request or the answer, and a
                        // lost one has to read as unreachable rather than as a
                        // spinner that never resolves.
                        try? await Task.sleep(for: .seconds(Self.responseTimeoutSeconds))
                        if !Task.isCancelled, self.listRequest == id, self.state == .loading {
                            self.state = .failed(Self.noAnswerMessage)
                        }
                        return
                    }
                    self.state = .failed(Self.noAnswerMessage)
                    return
                }
                if Date() >= deadline {
                    self.state = .failed(Self.noHostMessage)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static let channelWaitSeconds: TimeInterval = 25
    private static let responseTimeoutSeconds: TimeInterval = 15
    private static let noHostMessage =
        "The PC has not announced itself. The Longwave session broker has to be running on the "
        + "host — start it from the Windows companion, then try again."
    private static let noAnswerMessage =
        "The PC did not answer. Check that the Longwave Companion is running."

    /// Queue a title's box art. Safe to call from `onAppear` on every tile.
    ///
    /// Queued, not sent: **one art request is in flight at a time**, and the host
    /// paces the chunks within a response. Covers arrive as ~24 datagrams each, so
    /// overlapping two of them is how a receive buffer starts dropping the tail of
    /// both — and a dropped chunk costs a whole re-request.
    func loadArt(for title: GameLibraryTitle) {
        guard title.hasPortraitArt,
              art[title.id] == nil,
              !artUnavailable.contains(title.id),
              !artInFlight.contains(title.id),
              !artQueue.contains(title.id) else { return }
        artQueue.append(title.id)
        pumpArtQueue()
    }

    /// Send the next queued art request if nothing is outstanding.
    private func pumpArtQueue() {
        guard artInFlight.isEmpty, !artQueue.isEmpty, link?.isReady == true else { return }
        let titleId = artQueue.removeFirst()
        // It may have been served or dropped while queued.
        guard art[titleId] == nil, !artUnavailable.contains(titleId) else {
            pumpArtQueue()
            return
        }

        let id = takeRequestId()
        let body = Data(#"{"id":"\#(escaped(titleId))","orientation":"portrait"}"#.utf8)
        guard link?.send(op: .artRequest, requestId: id, body: body) == true else {
            // Link gone: leave the rest queued for the next rendezvous rather than
            // burning through the whole library against nothing.
            artQueue.insert(titleId, at: 0)
            return
        }
        artInFlight.insert(titleId)
        artRequests[id] = titleId
        artTimeoutTask?.cancel()
        artTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.responseTimeoutSeconds))
            guard let self, !Task.isCancelled, self.artInFlight.contains(titleId) else { return }
            // A lost art response must not wedge the queue for the rest of the session —
            // but one timeout is a transport hiccup, not "this title has no cover".
            self.artInFlight.remove(titleId)
            self.artRequests = self.artRequests.filter { $0.value != titleId }
            if self.artTimedOut.insert(titleId).inserted {
                self.artQueue.append(titleId)   // one retry, at the back of the line
            } else {
                self.artUnavailable.insert(titleId)
            }
            self.pumpArtQueue()
        }
    }

    func launch(_ title: GameLibraryTitle) {
        guard link?.isReady == true else {
            lastLaunchError = "The PCVR host is not connected."
            return
        }
        lastLaunchError = nil
        lastSuccessfulLaunchID = nil
        launching = title.id
        let id = takeRequestId()
        let body = Data(#"{"id":"\#(escaped(title.id))"}"#.utf8)
        if link?.send(op: .launch, requestId: id, body: body) == true {
            pendingLaunches.insert(id)
        } else {
            launching = nil
            lastLaunchError = "Could not reach the Windows companion."
        }
    }

    // MARK: Responses

    private func receive(_ done: GameLibraryProtocol.Reassembler.Completed) {
        if done.isError {
            let message = (try? JSONDecoder().decode(GameLibraryError.self, from: done.body))?.error
                ?? "The PC reported an error."
            handleFailure(message, for: done)
            return
        }

        switch done.op {
        case .listResponse:
            guard let decoded = try? JSONDecoder().decode([GameLibraryTitle].self, from: done.body) else {
                state = .failed("Could not read the library the PC sent.")
                return
            }
            titles = decoded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            listRequest = nil
            state = .loaded
            pumpArtQueue()
            // A title that vanished from the host takes its cached art with it.
            let live = Set(titles.map(\.id))
            art = art.filter { live.contains($0.key) }
            artUnavailable.formIntersection(live)
            log.notice("Game library: \(self.titles.count, privacy: .public) exposed title(s).")

        case .artResponse:
            guard let titleId = artRequests.removeValue(forKey: done.requestId) else { return }
            artInFlight.remove(titleId)
            artTimeoutTask?.cancel()
            defer { pumpArtQueue() }
            guard let decoded = try? JSONDecoder().decode(GameLibraryArt.self, from: done.body),
                  let base64 = decoded.data,
                  let bytes = Data(base64Encoded: base64),
                  let image = Self.image(from: bytes) else {
                artUnavailable.insert(titleId)
                return
            }
            art[titleId] = image

        case .launchResult:
            pendingLaunches.remove(done.requestId)
            let launchedTitleID = launching
            launching = nil
            // The host answers with the bare `true`/`false` of GameLibrary.LaunchAsync.
            let ok = (try? JSONDecoder().decode(Bool.self, from: done.body)) ?? false
            if ok {
                lastSuccessfulLaunchID = launchedTitleID
            } else {
                lastLaunchError = "The PC could not start that title."
            }

        case .listRequest, .launch, .artRequest:
            break   // request ops never arrive from the host
        }
    }

    private func handleFailure(_ message: String, for done: GameLibraryProtocol.Reassembler.Completed) {
        switch done.op {
        case .listResponse:
            listRequest = nil
            state = .failed(message)
        case .artResponse:
            if let titleId = artRequests.removeValue(forKey: done.requestId) {
                artInFlight.remove(titleId)
                artTimeoutTask?.cancel()
                artUnavailable.insert(titleId)
                pumpArtQueue()
            }
        case .launchResult:
            pendingLaunches.remove(done.requestId)
            launching = nil
            lastLaunchError = message
        default:
            break
        }
        log.error("Game library op \(done.op.rawValue, privacy: .public) failed: \(message, privacy: .public)")
    }

    // MARK: Helpers

    private func takeRequestId() -> UInt32 {
        let id = nextRequestId
        nextRequestId &+= 1
        // 0 is reserved as "not a request of ours" in the routing dictionaries.
        if nextRequestId == 0 { nextRequestId = 1 }
        return id
    }

    /// Ids are `steam:<appid>` or a hash for custom titles, so this only has to
    /// survive the theoretical case — but the body is JSON we hand-build.
    private func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let ui = UIImage(data: data) else { return nil }
        return Image(uiImage: ui)
        #else
        return nil
        #endif
    }
}
#endif
