import AppKit
import Foundation
import Network
import RAVECompanion

/// Answers one headset's pairing request (RAVESDK's `RAVEPairingServer` since
/// 2026-11-01): a one-off listener advertised as `_longwave-pair._tcp` for that
/// headset only, or a connection the direct pairing port accepted. This keeps
/// Longwave's part: the dialog where the user compares the six-digit code and
/// ticks what the device may do, and what enrolling it means here.
@MainActor
final class PairingServer {
    struct Context {
        /// Nil when the headset dialled this Mac's direct pairing port (from
        /// an AirDropped address link): its commit says who it is.
        let headsetID: String?
        let headsetName: String
        let macID: String
        let macName: String
        /// Called once the user approves: enrolls the device with the grants
        /// they ticked and returns its fresh token (nil if that failed).
        let enroll: @MainActor (_ id: String, _ name: String, _ grants: Set<CompanionGrant>, _ sshPublicKey: String?) -> String?
    }

    typealias Outcome = RAVEPairingServer<CompanionGrant>.Outcome

    /// Fired once, when the exchange is over either way, with the name the
    /// headset gave.
    var onFinish: ((Outcome, String) -> Void)? {
        didSet { server.onFinish = onFinish }
    }

    private let server: RAVEPairingServer<CompanionGrant>

    init(context: Context) {
        server = RAVEPairingServer(context: .init(
            namespace: CompanionDiscovery.namespace,
            deviceID: context.headsetID, deviceName: context.headsetName,
            hostID: context.macID, hostName: context.macName,
            defaultGrants: CompanionGrant.defaults,
            addresses: { CompanionPresence.lanAddresses() },
            acceptsPublicKey: { AuthorizedKeysManager.parse($0) != nil },
            enroll: context.enroll
        ))
        server.approve = { request in Self.approve(request) }
        server.onApprovalCancelled = { NSApp.abortModal() }
    }

    /// Runs the exchange on a connection the direct pairing listener accepted.
    func start(accepting connection: NWConnection) {
        server.start(accepting: connection)
    }

    func start() throws {
        try server.start()
    }

    func cancel() {
        server.cancel()
    }

    /// Asks the user. The prompt closes itself (as abandoned) if the
    /// requesting device goes away while it's up, so nothing that merely
    /// started a pairing can leave a dialog behind.
    private static func approve(_ request: RAVEPairingServer<CompanionGrant>.ApprovalRequest)
        -> RAVEPairingServer<CompanionGrant>.Decision {
        let alert = NSAlert()
        alert.messageText = "Pair “\(request.deviceName)” with this Mac?"
        alert.informativeText = """
        Check that the device shows this code:

        \(PairingExchange.display(request.code))

        Choose what it may do. You won't be asked again when it connects; change this any time under Devices in Longwave Companion.\(request.sshPublicKey.flatMap(AuthorizedKeysManager.parse).map { "\n\nSSH adds its key (\($0.fingerprint)) to your ~/.ssh/authorized_keys." } ?? "")
        """
        // One checkbox per grant, ticked as the device asked. A device asks for
        // Screen, Audio and Input unless the user requested more on it, e.g.
        // Projects → Request Access, so Projects is never ticked by default.
        // SSH only when the device sent a key to authorize.
        let offered = CompanionGrant.allCases.filter { $0 != .sshKey || request.sshPublicKey != nil }
        let boxes = offered.map { grant in
            let box = NSButton(checkboxWithTitle: grant.title, target: nil, action: nil)
            box.state = request.requested.contains(grant) ? .on : .off
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(boxes.count) * 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Don't Pair")
        alert.addButton(withTitle: "Stop Asking for an Hour")
        NSApp.activate(ignoringOtherApps: true)
        // The modal loop runs only modal-panel run loop work, so this timer is
        // what notices a vanished peer or the overall timeout meanwhile.
        let isPeerLost = request.isPeerLost
        let deadline = request.deadline
        let watchdog = Timer(timeInterval: 0.25, repeats: true) { _ in
            if isPeerLost() || ContinuousClock.now > deadline {
                NSApp.abortModal()
            }
        }
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        defer { watchdog.invalidate() }
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if isPeerLost() { return .abandon }
            return .pair(Set(zip(offered, boxes).filter { $0.1.state == .on }.map(\.0)))
        case .alertSecondButtonReturn: return .decline
        case .alertThirdButtonReturn: return .silence
        default: return .abandon
        }
    }
}
