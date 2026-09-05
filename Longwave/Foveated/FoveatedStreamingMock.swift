//  FoveatedStreamingMock.swift
//
//  The real `FoveatedStreaming` framework (visionOS 26.4+) is **device-only** —
//  it does not exist in the simulator. To keep the gated foveated code compiling
//  (and previewable) on the simulator, this file re-declares the slice of the
//  `FoveatedStreamingSession` API that `FoveatedConnectionManager` and the
//  foveated views use, as an in-module mock.
//
//  Selection is by target: on a device build the manager `import`s the real
//  framework; on the simulator there is no import and these mock types resolve
//  instead (same names, same shapes). The mock drives `status` through a
//  believable connect/pause/resume/disconnect flow so the control UI can be
//  exercised without hardware — there is, of course, no actual video.
//
//  Unlike Apple's sample (which puts the mock in a separate framework target and
//  routes calls through a `StreamActions` indirection), we keep the mock in the
//  app module so the manager's call sites are identical on simulator and device,
//  with no extra pbxproj target to maintain.
//
//  Keep these signatures in sync with the real framework surface we depend on.

#if FOVEATED_ENABLED && targetEnvironment(simulator)
import SwiftUI
import Network

@MainActor
@Observable
final class FoveatedStreamingSession: Identifiable {

    enum Status: Sendable, Equatable, CustomStringConvertible {
        case initialized
        case connecting
        case connected
        case disconnected(FoveatedStreamingSession.DisconnectReason)
        case disconnecting
        case paused
        case pausing
        case resuming

        var description: String {
            switch self {
            case .initialized: "Initialized"
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .disconnected: "Disconnected"
            case .disconnecting: "Disconnecting"
            case .paused: "Paused"
            case .pausing: "Pausing"
            case .resuming: "Resuming"
            }
        }
    }

    struct DisconnectReason: LocalizedError, Equatable, Sendable {
        private enum Value { case appInitiated, endpointInitiated, unauthorized, unavailable, simulatorTest }
        private var value: Value
        private init(_ v: Value) { value = v }

        static var appInitiatedDisconnect: Self { .init(.appInitiated) }
        static var endpointInitiatedDisconnect: Self { .init(.endpointInitiated) }
        static var unauthorized: Self { .init(.unauthorized) }
        static var unavailable: Self { .init(.unavailable) }
        static var simulatorTestDisconnect: Self { .init(.simulatorTest) }

        var errorDescription: String? {
            switch value {
            case .appInitiated: nil
            case .endpointInitiated: "The host ended the session."
            case .unauthorized: "Pairing was not authorized."
            case .unavailable: "The streaming host is unavailable."
            case .simulatorTest: "Simulator disconnection test."
            }
        }
    }

    struct Endpoint {
        private enum Value {
            case systemDiscovered
            case local(ipAddress: IPAddress, port: NWEndpoint.Port)
            case remote(serverName: String, signalingHeaders: [String: String])
        }
        private var value: Value
        private init(_ v: Value) { value = v }

        static var systemDiscovered: Self { .init(.systemDiscovered) }
        static func local(ipAddress: IPAddress, port: NWEndpoint.Port) -> Self { .init(.local(ipAddress: ipAddress, port: port)) }
        static func remote(serverName: String, signalingHeaders: [String: String]) -> Self { .init(.remote(serverName: serverName, signalingHeaders: signalingHeaders)) }
    }

    /// Mirrors `FoveatedStreamingSession.ImmersivePresentationBehaviors`. The
    /// mock stores nothing — on the simulator the immersive space is opened with
    /// a plain `ImmersiveSpace`, not the framework's auto-presentation.
    struct ImmersivePresentationBehaviors {
        static func automatic(_ open: OpenImmersiveSpaceAction, _ dismiss: DismissImmersiveSpaceAction) -> ImmersivePresentationBehaviors { .init() }
    }

    /// Mirrors `FoveatedStreamingSession.MessageChannel` (the slice the
    /// controller bridge uses). The mock session exposes no channels — the
    /// bridge then stays on its UDP fallback, which is exactly what simulator
    /// testing against a real host wants anyway.
    @Observable
    final class MessageChannel: Identifiable {
        struct ID: Hashable, Equatable, Sendable {
            private let uuid: UUID
            init(_ uuid: UUID) { self.uuid = uuid }
        }

        enum ChannelStatus: Hashable, Equatable, Sendable {
            case ready
            case closed
        }

        struct SendError: LocalizedError {
            var errorDescription: String? { "Mock channel cannot send." }
        }

        let id: ID
        let receivedMessageStream: AsyncStream<Data> = AsyncStream { $0.finish() }
        var channelStatus: ChannelStatus = .closed

        init(id: ID) { self.id = id }
        func disconnect() { channelStatus = .closed }
        func sendMessage(_ data: Data) throws { throw SendError() }
    }

    var availableMessageChannels: Set<MessageChannel.ID> { [] }
    func messageChannel(for channelID: MessageChannel.ID) -> MessageChannel? { nil }

    var status: Status = .initialized
    var immersivePresentationBehaviors: ImmersivePresentationBehaviors?
    // No microphone property, matching the real framework: visionOS forwards the headset
    // mic for every session on its own and exposes no switch for it.

    init() {}

    func connect(endpoint: Endpoint) async throws {
        status = .connecting
        try await Task.sleep(for: .milliseconds(600))
        try Task.checkCancellation()
        status = .connected
    }

    func pause() async throws {
        status = .pausing
        try await Task.sleep(for: .milliseconds(200))
        status = .paused
    }

    func resume() async throws {
        status = .resuming
        try await Task.sleep(for: .milliseconds(200))
        status = .connected
    }

    func disconnect() async {
        status = .disconnecting
        try? await Task.sleep(for: .milliseconds(150))
        status = .disconnected(.appInitiatedDisconnect)
    }
}
#endif
