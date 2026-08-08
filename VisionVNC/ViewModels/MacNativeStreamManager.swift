#if os(visionOS)
import Foundation
import AVFoundation
import UIKit

@Observable
final class MacNativeStreamManager {
    enum State: Equatable {
        case disconnected(String?)
        case connecting
        case connected
        case streaming

        var statusText: String {
            switch self {
            case .disconnected(let message): message ?? "Disconnected"
            case .connecting: "Connecting to Mac…"
            case .connected: "Waiting for the first frame…"
            case .streaming: "Streaming"
            }
        }
    }

    /// Whether the companion will act on mouse/keyboard frames right now —
    /// mirrors `MacNativeStreamClient.Event.InputAvailability`, plus
    /// `.unknown` before the first status frame arrives (e.g. still
    /// connecting).
    enum InputAvailability: Equatable {
        case unknown
        case available
        case disabled
        case accessibilityDenied
    }

    private(set) var state: State = .disconnected(nil)
    private(set) var displayLayer: AVSampleBufferDisplayLayer?
    private(set) var streamSize: CGSize = .zero
    private(set) var title = "Native"
    private(set) var inputAvailability: InputAvailability = .unknown

    /// The Native connection this session targets — remembered independent
    /// of whether Screen is actually running, so the live Screen toggle in
    /// the Native window can start it later even if it was off when the
    /// window opened. Cleared only by `forget()` (the window's hard close),
    /// not by `disconnect()` (a live toggle-off).
    private(set) var connection: SavedConnection?

    /// True once toggled on, even mid-connect or after a drop — mirrors user
    /// intent rather than the transient handshake state, so the Screen
    /// toggle in the Native window doesn't flip itself off on a hiccup.
    var isEnabled: Bool {
        if case .disconnected = state { false } else { true }
    }

    /// The Native window's live Screen toggle, persisted separately from
    /// `state`: a transient drop or a deliberate toggle-off both leave
    /// `state` disconnected, but only this flag says whether Screen should
    /// resume after a scene reactivation or a full space-restoration
    /// relaunch (a fresh `MacNativeStreamManager` with no in-memory state).
    private static let liveEnabledKey = "nativeScreenLiveEnabled"
    var liveEnabled: Bool = UserDefaults.standard.bool(forKey: MacNativeStreamManager.liveEnabledKey) {
        didSet {
            guard liveEnabled != oldValue else { return }
            UserDefaults.standard.set(liveEnabled, forKey: Self.liveEnabledKey)
        }
    }

    private var client: MacNativeStreamClient?
    private var activeConnectionID: UUID?

    /// Remembers `connection` as this session's target without starting
    /// capture — used when opening the Native window with Screen initially
    /// off, so the live toggle has something to connect to.
    func prepare(for connection: SavedConnection) {
        self.connection = connection
    }

    func connect(to connection: SavedConnection) {
        self.connection = connection
        teardown()
        let connectionID = UUID()
        activeConnectionID = connectionID
        title = connection.displayName
        state = .connecting

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
        layer.isOpaque = false
        displayLayer = layer

        let renderer = MacNativeVideoRenderer(displayLayer: layer)
        let client = MacNativeStreamClient(
            config: .init(
                host: connection.hostname,
                port: MacNativeStreamProtocol.defaultPort,
                token: connection.companionToken,
                deviceName: UIDevice.current.name
            ),
            renderer: renderer
        )
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, connectionID: connectionID)
            }
        }
        self.client = client
        client.start()
    }

    /// Stops Screen but keeps `connection` remembered, so a live toggle
    /// back on (in the same Native window) can reconnect without needing
    /// the connection list again.
    func disconnect() {
        teardown()
    }

    /// Full teardown and forgets the target — called when the Native window
    /// is explicitly closed, so a stale target doesn't leak into the next
    /// session and Screen doesn't try to resume on a later relaunch.
    func forget() {
        teardown()
        connection = nil
        liveEnabled = false
    }

    private func teardown() {
        activeConnectionID = nil
        let oldClient = client
        client = nil
        oldClient?.close()
        displayLayer = nil
        streamSize = .zero
        inputAvailability = .unknown
        if case .disconnected = state {
            return
        }
        state = .disconnected(nil)
    }

    // MARK: - Remote control (mouse/keyboard)

    func sendMouseMove(x: UInt16, y: UInt16) {
        client?.sendMouseMove(x: x, y: y)
    }

    func sendMouseDown(button: MacNativeStreamProtocol.MouseButton, x: UInt16, y: UInt16) {
        client?.sendMouseDown(button: button, x: x, y: y)
    }

    func sendMouseUp(button: MacNativeStreamProtocol.MouseButton, x: UInt16, y: UInt16) {
        client?.sendMouseUp(button: button, x: x, y: y)
    }

    func sendScroll(x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16) {
        client?.sendScroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY)
    }

    func sendKeyDown(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        client?.sendKeyDown(keyCode: keyCode, modifiers: modifiers)
    }

    func sendKeyUp(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        client?.sendKeyUp(keyCode: keyCode, modifiers: modifiers)
    }

    private func handle(_ event: MacNativeStreamClient.Event, connectionID: UUID) {
        guard activeConnectionID == connectionID else { return }
        switch event {
        case .connected:
            state = .connected
        case .format(let size):
            streamSize = size
        case .firstFrame:
            state = .streaming
        case .inputAvailability(let availability):
            switch availability {
            case .available: inputAvailability = .available
            case .disabled: inputAvailability = .disabled
            case .accessibilityDenied: inputAvailability = .accessibilityDenied
            }
        case .replaced(let deviceName):
            state = .disconnected("Replaced by \(deviceName).")
            activeConnectionID = nil
            client = nil
        case .closed(let message):
            if case .disconnected(let existing) = state, existing != nil {
                return
            }
            state = .disconnected(message)
            activeConnectionID = nil
            client = nil
        }
    }
}
#endif
