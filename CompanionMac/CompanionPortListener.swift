import DebugTrace
import Foundation
import Network

/// The listener behind one of the Companion's fixed stream ports, kept up for
/// as long as its server runs.
///
/// A listener holds its PSKs for life, so pairing or revoking a device
/// replaces it, and `NWListener.cancel()` releases the port asynchronously.
/// A replacement bound straight away fails with EADDRINUSE, and that failure
/// arrives in `stateUpdateHandler`, not as a throw from `init`. So until this
/// type existed, pairing a device closed the Native, audio and inject ports
/// until the Companion was relaunched, and the new device sat on
/// "Connecting…" (2026-10-17, an iPad and the MBP). A replacement therefore
/// waits for the old listener's `.cancelled`, and a bind that still fails
/// (the port held by a Companion that is still quitting, say) is retried
/// with backoff for as long as the server runs, never abandoned.
///
/// Every method must be called on `queue`, the queue the listener runs on.
final class CompanionPortListener: @unchecked Sendable {
    /// Builds a listener with the current keys and its connection handler.
    /// `stateUpdateHandler` is this type's; the factory leaves it alone.
    typealias Factory = @Sendable () throws -> NWListener

    /// The port has been unavailable for a few seconds and is still being
    /// retried; the message says why. Called on `queue`.
    nonisolated(unsafe) var onUnavailable: ((String) -> Void)?

    private let name: String
    private let queue: DispatchQueue
    private let log: DebugLogger
    private nonisolated(unsafe) var make: Factory?
    private nonisolated(unsafe) var listener: NWListener?
    /// Bumped by every start, replace and stop, so a retry or a retirement
    /// scheduled for an earlier one does nothing.
    private nonisolated(unsafe) var generation = 0
    private nonisolated(unsafe) var failures = 0

    /// Failed binds before `onUnavailable`: about three seconds of backoff,
    /// long enough that a replacement waiting out its predecessor never
    /// reports one.
    private static let reportAfterFailures = 6
    private static let maxRetryDelayMs = 2000
    /// How long a retired listener gets to report `.cancelled` before its
    /// successor binds anyway (and retries if the port is still held).
    private static let retireTimeout: DispatchTimeInterval = .milliseconds(500)

    nonisolated init(name: String, queue: DispatchQueue, log: DebugLogger) {
        self.name = name
        self.queue = queue
        self.log = log
    }

    nonisolated func start(_ make: @escaping Factory) {
        self.make = make
        generation += 1
        failures = 0
        bind(generation)
    }

    /// A new listener from the factory (new keys) in place of the current one.
    nonisolated func replace() {
        guard make != nil else { return }
        generation += 1
        failures = 0
        let current = generation
        guard let old = listener else {
            bind(current)
            return
        }
        listener = nil
        retire(old) { [self] in bind(current) }
    }

    /// Stops listening; `completion` runs once the port is released, or after
    /// a short timeout if the system never says so.
    nonisolated func stop(completion: (@Sendable () -> Void)? = nil) {
        make = nil
        generation += 1
        guard let old = listener else {
            completion?()
            return
        }
        listener = nil
        retire(old) { completion?() }
    }

    private nonisolated func retire(_ old: NWListener, then next: @escaping () -> Void) {
        let pending = Pending(next)
        old.newConnectionHandler = nil
        old.stateUpdateHandler = { state in
            if case .cancelled = state { pending.run() }
        }
        old.cancel()
        queue.asyncAfter(deadline: .now() + Self.retireTimeout) { pending.run() }
    }

    private nonisolated func bind(_ current: Int) {
        guard current == generation, listener == nil, let make else { return }
        let listener: NWListener
        do {
            listener = try make()
        } catch {
            failed(error, current)
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                if failures > 0 {
                    log.notice("\(self.name, privacy: .public) listener up after \(self.failures) failed binds")
                }
                failures = 0
            case .failed(let error):
                self.listener = nil
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
                failed(error, current)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private nonisolated func failed(_ error: Error, _ current: Int) {
        failures += 1
        let message = "\(name) listener failed: \(error.localizedDescription)"
        if failures == 1 {
            log.notice("\(message, privacy: .public); retrying")
        } else if failures == Self.reportAfterFailures {
            log.error("\(message, privacy: .public); still retrying")
            onUnavailable?(message)
        }
        let delay = min(100 << min(failures - 1, 5), Self.maxRetryDelayMs)
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            self?.bind(current)
        }
    }

    /// Runs its work once, whichever of `.cancelled` or the timeout comes first.
    private final class Pending: @unchecked Sendable {
        private var work: (() -> Void)?
        nonisolated init(_ work: @escaping () -> Void) { self.work = work }
        nonisolated func run() {
            let work = self.work
            self.work = nil
            work?()
        }
    }
}
