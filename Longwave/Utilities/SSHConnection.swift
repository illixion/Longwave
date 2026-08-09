import Foundation
import Network
import NIOCore
import NIOTransportServices
import NIOSSH
import os

enum SSHConnectionError: Error, CustomStringConvertible {
    case invalidChannelType
    case authUnavailable

    var description: String {
        switch self {
        case .invalidChannelType: return "Unexpected SSH channel type"
        case .authUnavailable: return "Server did not offer public-key authentication"
        }
    }
}

/// An interactive SSH session over swift-nio-ssh, driving a single remote PTY.
///
/// Off-main worker (every member `nonisolated`) modeled on `AudioStreamReceiver`:
/// it runs on NIOTransportServices event loops (Network.framework) and surfaces
/// everything through `onEvent`, which the owning `SSHSession` marshals to the
/// main actor. One TCP connection → one SSH `.session` child channel that
/// requests a PTY then runs the launch command (or a login shell).
final class SSHConnection: @unchecked Sendable {

    struct Config: Sendable {
        var host: String
        var port: Int
        var username: String
        /// Command to exec under the PTY (e.g. a `tmux new -A …` line). When
        /// empty, a login shell is requested instead. Any environment the
        /// session needs is baked into this command by the caller (see
        /// `SSHTerminalManager.claudeCommand`) rather than sent as SSH `env`
        /// requests — that would require a server-side `AcceptEnv` edit.
        var command: String
        var cols: Int
        var rows: Int
    }

    enum Event: Sendable {
        case ready
        case output([UInt8])
        case closed(String?)
        case failed(String)
    }

    nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?

    private let config: Config
    private let privateKey: NIOSSHPrivateKey
    private let group: NIOTSEventLoopGroup
    private let log = Logger(subsystem: "pro.longwave", category: "SSH")

    private nonisolated(unsafe) var channel: Channel?
    private nonisolated(unsafe) var sessionChannel: Channel?
    private nonisolated(unsafe) var closed = false

    /// Latest size requested by the terminal view. SwiftTerm's first
    /// `sizeChanged` fires during the window's initial layout pass — before the
    /// SSH session channel exists — so the size must be remembered here and
    /// applied when the channel opens, or the PTY is stuck at the config size.
    private let sizeLock = NSLock()
    private nonisolated(unsafe) var desiredCols: Int
    private nonisolated(unsafe) var desiredRows: Int

    nonisolated init(config: Config, privateKey: NIOSSHPrivateKey, group: NIOTSEventLoopGroup) {
        self.config = config
        self.privateKey = privateKey
        self.group = group
        self.desiredCols = config.cols
        self.desiredRows = config.rows
    }

    private nonisolated func desiredSize() -> (cols: Int, rows: Int) {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return (desiredCols, desiredRows)
    }

    nonisolated func start() {
        let auth = SSHKeyAuthDelegate(username: config.username, privateKey: privateKey)
        // TCP keepalive is the dead-connection detector: after the app resumes
        // from suspension (visionOS tracking loss), a connection the system
        // silently killed fails within ~20 s, firing `closeFuture` → `.closed`
        // → the session's auto-reconnect. SSH-level keepalive pings aren't
        // possible — swift-nio-ssh exposes no API for arbitrary global requests.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .tcpOptions(tcp)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: auth,
                            serverAuthDelegate: AcceptAllHostKeysDelegate()
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        bootstrap.connect(host: config.host, port: config.port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.emit(.failed("Connection failed: \(error)"))
            case .success(let channel):
                self.channel = channel
                channel.closeFuture.whenComplete { [weak self] _ in
                    self?.emit(.closed(nil))
                }
                self.openSession(on: channel)
            }
        }
    }

    private nonisolated func openSession(on channel: Channel) {
        // Use the most recent size from the view, not the config default — the
        // first layout pass usually lands before the channel opens.
        let (cols, rows) = desiredSize()
        let command = config.command
        let onData: @Sendable ([UInt8]) -> Void = { [weak self] bytes in self?.emit(.output(bytes)) }
        let onReady: @Sendable () -> Void = { [weak self] in self?.emit(.ready) }

        channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise) { child, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
                }
                return child.eventLoop.makeCompletedFuture {
                    let handler = SSHShellChannelHandler(
                        term: "xterm-256color", cols: cols, rows: rows,
                        command: command, onData: onData, onReady: onReady
                    )
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
            return promise.futureResult
        }.whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.emit(.failed("Session open failed: \(error)"))
            case .success(let child):
                self.sessionChannel = child
                // A resize may have landed between building the PTY request and
                // the channel opening — replay the latest size if it differs.
                let (latestCols, latestRows) = self.desiredSize()
                if latestCols != cols || latestRows != rows {
                    self.resize(cols: latestCols, rows: latestRows)
                }
            }
        }
    }

    /// Send raw bytes as PTY stdin. Returns `false` when the session channel
    /// isn't up (input would be silently lost) so callers can keep the text.
    @discardableResult
    nonisolated func send(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, let child = sessionChannel else { return false }
        child.eventLoop.execute {
            var buffer = child.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            child.writeAndFlush(data, promise: nil)
        }
        return true
    }

    /// Notify the remote PTY of a new window size (SIGWINCH). Sizes arriving
    /// before the session channel opens are recorded and applied at open.
    nonisolated func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        sizeLock.lock()
        desiredCols = cols
        desiredRows = rows
        sizeLock.unlock()
        guard let child = sessionChannel else { return }
        child.eventLoop.execute {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: cols, terminalRowHeight: rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0
            )
            child.triggerUserOutboundEvent(event, promise: nil)
        }
    }

    nonisolated func close() {
        channel?.close(promise: nil)
    }

    private nonisolated func emit(_ event: Event) {
        if case .closed = event {
            if closed { return }
            closed = true
        }
        onEvent?(event)
    }
}

// MARK: - User authentication (public key)

/// Offers the device's private key for public-key auth, exactly once. A second
/// callback means the offer was rejected, so we give up (failing the handshake
/// cleanly) rather than looping.
nonisolated final class SSHKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private nonisolated(unsafe) var offered = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    nonisolated func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: privateKey))
        )
        nextChallengePromise.succeed(offer)
    }
}

// MARK: - Host key validation

/// Accepts any host key. TODO(M3): trust-on-first-use pinning — record the host
/// key per connection and reject mismatches; surface the Mac's fingerprint for
/// out-of-band verification.
nonisolated final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// MARK: - Session child-channel handler

/// Requests a PTY + (exec|shell) on channel activation, streams stdout/stderr
/// out via `onData`, and reports readiness once the shell/exec request succeeds.
nonisolated final class SSHShellChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let term: String
    private let cols: Int
    private let rows: Int
    private let command: String
    private let onData: @Sendable ([UInt8]) -> Void
    private let onReady: @Sendable () -> Void
    private nonisolated(unsafe) var didSignalReady = false

    init(term: String, cols: Int, rows: Int, command: String,
         onData: @escaping @Sendable ([UInt8]) -> Void,
         onReady: @escaping @Sendable () -> Void) {
        self.term = term
        self.cols = cols
        self.rows = rows
        self.command = command
        self.onData = onData
        self.onReady = onReady
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // SSH child channels misbehave without remote half-closure enabled.
        // Capture the Sendable Channel, not the non-Sendable context.
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: term,
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)

        if command.isEmpty {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        } else {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // A successful reply to our shell/exec request means the PTY is live.
        if event is ChannelSuccessEvent, !didSignalReady {
            didSignalReady = true
            onReady()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else { return }
        // Both stdout (.channel) and stderr (.stdErr) render in the terminal.
        onData(bytes)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - One-shot command runner (remote directory listing, etc.)

/// Runs a single non-interactive SSH command (no PTY) and captures its stdout.
/// Used by the Projects folder browser (`ls`, `pwd`). Retains itself via the
/// in-flight NIO closures until completion fires exactly once.
nonisolated final class SSHCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var finished = false
    private nonisolated(unsafe) var rootChannel: Channel?
    private let completion: @Sendable (Result<String, Error>) -> Void

    private init(completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        self.completion = completion
    }

    static func run(host: String, port: Int, username: String, command: String,
                    privateKey: NIOSSHPrivateKey, group: NIOTSEventLoopGroup,
                    completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        SSHCommandRunner(completion: completion)
            .start(host: host, port: port, username: username, command: command,
                   privateKey: privateKey, group: group)
    }

    private func start(host: String, port: Int, username: String, command: String,
                       privateKey: NIOSSHPrivateKey, group: NIOTSEventLoopGroup) {
        let auth = SSHKeyAuthDelegate(username: username, privateKey: privateKey)
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: auth,
                                            serverAuthDelegate: AcceptAllHostKeysDelegate())),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        // Strong self capture keeps the runner alive until the command finishes.
        bootstrap.connect(host: host, port: port).whenComplete { result in
            switch result {
            case .failure(let error):
                self.finish(.failure(error))
            case .success(let channel):
                self.rootChannel = channel
                self.openExec(on: channel, command: command)
            }
        }
    }

    private func openExec(on channel: Channel, command: String) {
        channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise) { child, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHConnectionError.invalidChannelType)
                }
                return child.eventLoop.makeCompletedFuture {
                    let handler = SSHExecCaptureHandler(command: command) { result in
                        self.finish(result)
                    }
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
            return promise.futureResult
        }.whenFailure { error in
            self.finish(.failure(error))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        completion(result)
        rootChannel?.close(promise: nil)
    }
}

/// Sends an `exec` request (no PTY), accumulates stdout, and reports it when
/// the channel closes.
nonisolated final class SSHExecCaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let onComplete: @Sendable (Result<String, Error>) -> Void
    private nonisolated(unsafe) var stdout = Data()
    private nonisolated(unsafe) var done = false

    init(command: String, onComplete: @escaping @Sendable (Result<String, Error>) -> Void) {
        self.command = command
        self.onComplete = onComplete
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in
            channel.close(promise: nil)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data,
              channelData.type == .channel,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        stdout.append(contentsOf: bytes)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.success(String(decoding: stdout, as: UTF8.self)))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    private func complete(_ result: Result<String, Error>) {
        guard !done else { return }
        done = true
        onComplete(result)
    }
}
