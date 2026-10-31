//  TrackerHubModel.swift
//
//  The headset's view of the PC's tracker hub (0x11) and its half of the conversation
//  (0x12): everything the Trackers panel shows and does, and what the immersive space draws.
//
//  The point of putting this here rather than on the PC is that the person aligning a device
//  is wearing the headset: they can see their own hand, the device in it and the drawing that
//  is supposed to sit on it, and they cannot see a Windows window. So the panel and the
//  wireframes live next to each other, fed by one model.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import Observation
import QuartzCore
import simd

// MARK: - Commands

/// One command in flight at a time, resent until the host acknowledges its sequence.
///
/// The host keeps only the latest command and executes it once per new `sequence`, so the
/// headset must not send the next one until the previous is acknowledged; and it resends
/// the current one every tick because the control link can drop and the host can restart.
/// The sequence starts at a random byte and never takes 0: a fresh host acknowledges 0, and a
/// restarted headset must not have its first command mistaken for the last one the host ran.
struct TrackerCommandQueue {
    /// How long one command may go unacknowledged before it is given up on. A host that
    /// understands the packet answers within a tick; one that never does would otherwise
    /// block everything queued behind the command.
    static let giveUpAfter: TimeInterval = 5
    /// Resend cadence while a command is waiting for its acknowledgement.
    static let resendEvery: TimeInterval = 0.2

    enum Outcome: Equatable {
        case acknowledged(ControllerBridgeTrackers.Result)
        case timedOut
    }

    private(set) var sequence: UInt8
    private(set) var inFlight: ControllerBridgeTrackerCommand?
    private(set) var lastOutcome: Outcome?
    private var queue: [ControllerBridgeTrackerCommand] = []
    private var firstSentAt: TimeInterval?
    private var lastSentAt: TimeInterval = 0

    init(startSequence: UInt8 = UInt8.random(in: 1...255)) {
        sequence = startSequence
    }

    var isIdle: Bool { inFlight == nil && queue.isEmpty }
    var pendingCount: Int { queue.count + (inFlight == nil ? 0 : 1) }

    mutating func enqueue(_ command: ControllerBridgeTrackerCommand) {
        queue.append(command)
    }

    /// The bytes to send now, or nil when there is nothing to send yet. Starting the next
    /// command takes a new sequence; a resend reuses the current one. Call `markSent` once
    /// the link actually took the bytes.
    mutating func packetToSend(now: TimeInterval) -> Data? {
        if let started = firstSentAt, now - started > Self.giveUpAfter {
            lastOutcome = .timedOut
            inFlight = nil
            firstSentAt = nil
        }
        if inFlight == nil, !queue.isEmpty {
            inFlight = queue.removeFirst()
            sequence = sequence == 255 ? 1 : sequence + 1
            firstSentAt = nil
            lastSentAt = 0
        }
        guard let command = inFlight else { return nil }
        guard firstSentAt == nil || now - lastSentAt >= Self.resendEvery else { return nil }
        return command.encoded(sequence: sequence)
    }

    mutating func markSent(now: TimeInterval) {
        if firstSentAt == nil { firstSentAt = now }
        lastSentAt = now
    }

    /// A 0x11 arrived. True when it acknowledged the command in flight.
    @discardableResult
    mutating func acknowledge(sequence ack: UInt8, result: ControllerBridgeTrackers.Result) -> Bool {
        // Only a command that has been sent can have been executed: an acknowledgement
        // that matches by coincidence before the first send is a previous run's.
        // And only with a real result: a host that has run nothing reports sequence 0 with
        // result NONE, which must never look like an answer to a command that happens to
        // carry sequence 0.
        guard inFlight != nil, firstSentAt != nil, ack == sequence, result != .none else { return false }
        lastOutcome = .acknowledged(result)
        inFlight = nil
        firstSentAt = nil
        return true
    }
}

// MARK: - Naming and status text

enum TrackerNaming {
    /// A name a person can tell apart: what it is, which side if it says, and the tail of its
    /// serial if there is nothing else to separate two wands.
    static func name(for device: ControllerBridgeTrackerDevice) -> String {
        name(key: device.key, kind: device.kind)
    }

    static func name(key: String, kind: ControllerBridgeTrackerDevice.Kind) -> String {
        let word: String
        switch kind {
        case .wand: word = "Wand"
        case .touch: word = "Touch controller"
        case .tracker: word = "Tracker"
        case .other: word = "Device"
        }
        let id = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
        let lower = id.lowercased()
        if lower.contains("left") { return "Left \(word.lowercased())".capitalizedFirst }
        if lower.contains("right") { return "Right \(word.lowercased())".capitalizedFirst }
        let tail = id.filter { $0.isLetter || $0.isNumber }.suffix(4)
        return tail.isEmpty ? word : "\(word) \(tail.uppercased())"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// What the alignment is doing, in words, and how the panel should colour it.
enum TrackerAlignStatus {
    enum Tone { case neutral, good, warning }

    static func describe(_ t: ControllerBridgeTrackers) -> (text: String, tone: Tone) {
        let tracked = t.devices.filter { $0.isTracked }
        switch t.alignPhase {
        case .collecting:
            let hand = t.alignHand.map { $0 == 0 ? "Left" : "Right" }
            let device = t.alignDevice.flatMap { t.devices.indices.contains($0) ? t.devices[$0] : nil }
            let who = device.map { TrackerNaming.name(for: $0) } ?? "a device"
            let spread = String(format: "%.2f of %.2f m", t.alignSpreadMeters, t.alignSpreadTargetMeters)
            guard let hand else { return ("Matching \(who) to a hand…", .neutral) }
            return ("\(hand) hand: \(who), \(t.alignSamples) pairs, \(spread). Keep sweeping your arm.", .neutral)
        case .waiting:
            return ("Waiting for a device to move with a hand. Pick one up and wave it.", .neutral)
        case .done:
            return (String(format: "Aligned, %.1f mm. Check the outline sits on your device.", t.alignResidualMm), .good)
        case .idle:
            if tracked.isEmpty { return ("No trackers in view.", .neutral) }
            if tracked.contains(where: { !$0.isAligned }) {
                return ("Not aligned yet. Press Align, then wave the device in your hand.", .warning)
            }
            return ("Everything in view is aligned.", .good)
        }
    }
}

// MARK: - The model

@MainActor
@Observable
final class TrackerHubModel {
    /// The 0x11 the views render, nil until the host has sent one (a host without the feature
    /// never does, and the panel stays out of the way). Republished at most every 100 ms
    /// unless something a person would notice changed: the host sends at 30 Hz, and a
    /// SwiftUI list that rebuilt at that rate would cost more than it shows.
    private(set) var trackers: ControllerBridgeTrackers?
    /// The newest 0x11 exactly as it arrived, for the immersive space, which reads it every
    /// frame and is not a SwiftUI observer. Not observed.
    @ObservationIgnored private(set) var latest: ControllerBridgeTrackers?
    @ObservationIgnored private(set) var receivedAt: CFTimeInterval = 0
    @ObservationIgnored private var publishedAt: CFTimeInterval = 0
    /// A result the person should hear about (a refused role), cleared by `dismissError`.
    private(set) var lastError: String?
    /// When a device last went from unaligned to aligned, for the overlay's auto-show.
    private(set) var lastAlignedAt: CFTimeInterval = 0

    /// What the person set; the host does not report its own (see the contract note in the
    /// tracker UI hand-off), so this is the only copy. Persisted, and only pushed when the
    /// person changes it.
    private(set) var autoAlign: Bool = (UserDefaults.standard.object(forKey: TrackerHubModel.autoAlignKey) as? Bool) ?? true
    /// Draw the devices even with the panel closed.
    var showAlways: Bool = UserDefaults.standard.bool(forKey: TrackerHubModel.showAlwaysKey) {
        didSet { UserDefaults.standard.set(showAlways, forKey: Self.showAlwaysKey) }
    }
    /// How many Trackers panels are on screen.
    private(set) var panelsVisible = 0

    /// Set by the debug server's demo feed (`TrackerDebugEndpoints`); nil otherwise.
    static var demo: TrackerHubModel?

    static let autoAlignKey = "pcvrTrackersAutoAlign"
    static let showAlwaysKey = "pcvrShowTrackedDevices"
    /// How long a drawing stays up after a device becomes aligned, so the person can look.
    static let verifyWindow: TimeInterval = 20
    /// A 0x11 older than this means the host has gone quiet.
    static let liveWithin: TimeInterval = 1.5

    private var queue = TrackerCommandQueue()

    var hasHost: Bool { trackers != nil }

    func isLive(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        latest != nil && now - receivedAt < Self.liveWithin
    }

    /// The overlay's gate: the panel is open, the person asked for it always, or an
    /// alignment just finished.
    func overlayWanted(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard isLive(now: now) else { return false }
        return showAlways || panelsVisible > 0 || now - lastAlignedAt < Self.verifyWindow
    }

    func panelAppeared() { panelsVisible += 1 }
    func panelDisappeared() { panelsVisible = max(0, panelsVisible - 1) }
    func dismissError() { lastError = nil }

    // MARK: Ingest

    func ingest(_ packet: ControllerBridgeTrackers, now: CFTimeInterval = CACurrentMediaTime()) {
        let before = latest
        latest = packet
        receivedAt = now
        if trackers == nil || now - publishedAt >= 0.1 || Self.differsVisibly(before, packet) {
            trackers = packet
            publishedAt = now
        }
        // A device that was not aligned and now is, or an alignment that just finished.
        let wasAligned = Set((before?.devices ?? []).filter { $0.isAligned }.map(\.key))
        let nowAligned = packet.devices.filter { $0.isAligned }.map(\.key)
        if nowAligned.contains(where: { !wasAligned.contains($0) }) && before != nil {
            lastAlignedAt = now
        } else if packet.alignPhase == .done && before?.alignPhase != .done {
            lastAlignedAt = now
        }
        if queue.acknowledge(sequence: packet.ackSequence, result: packet.ackResult) {
            switch packet.ackResult {
            case .refused: lastError = "The PC didn't accept that change."
            case .unknown: lastError = "The PC doesn't know that device any more."
            default: break
            }
        }
    }

    /// Whether a person looking at the panel would see a difference beyond a moving meter.
    static func differsVisibly(_ a: ControllerBridgeTrackers?, _ b: ControllerBridgeTrackers) -> Bool {
        guard let a else { return true }
        if a.alignPhase != b.alignPhase || a.ackSequence != b.ackSequence || a.flags != b.flags
            || a.alignHand != b.alignHand || a.alignDevice != b.alignDevice
            || a.devices.count != b.devices.count { return true }
        for (x, y) in zip(a.devices, b.devices)
        where x.key != y.key || x.flags != y.flags || x.role != y.role || x.ownsHand != y.ownsHand
            || x.battery != y.battery { return true }
        return false
    }

    // MARK: Commands

    func alignStart() { send(.init(op: .alignStart, arg: ControllerBridgeTrackerCommand.handAuto)) }
    func alignStop() { send(.init(op: .alignStop)) }
    /// Forget every alignment, then collect again.
    func realign() {
        send(.init(op: .reset))
        send(.init(op: .alignStart, arg: ControllerBridgeTrackerCommand.handAuto))
    }
    func reset() { send(.init(op: .reset)) }
    func assign(_ key: String, role: TrackerRole) {
        send(role == .none ? .init(op: .unassign, key: key) : .init(op: .assign, arg: role.rawValue, key: key))
    }
    func unassign(_ key: String) { send(.init(op: .unassign, key: key)) }
    func setAutoAlign(_ on: Bool) {
        autoAlign = on
        UserDefaults.standard.set(on, forKey: Self.autoAlignKey)
        send(.init(op: .setAutoAlign, arg: on ? 1 : 0))
    }

    /// Nothing is sent to a host that has not proven it speaks this: a 0x11 has to have
    /// arrived first.
    private func send(_ command: ControllerBridgeTrackerCommand) {
        guard hasHost else { return }
        queue.enqueue(command)
    }

    var pendingCommands: Int { queue.pendingCount }

    /// The sender's tick: the bytes to put on the control link, if any. Call `markSent`
    /// when the link took them.
    func packetToSend(now: CFTimeInterval = CACurrentMediaTime()) -> Data? {
        guard hasHost else { return nil }
        return queue.packetToSend(now: now)
    }

    func markSent(now: CFTimeInterval = CACurrentMediaTime()) {
        queue.markSent(now: now)
    }

    /// Test and demo access to the queue's current state.
    var commandInFlight: ControllerBridgeTrackerCommand? { queue.inFlight }
    var commandSequence: UInt8 { queue.sequence }

    // MARK: Convenience for the views

    var devices: [ControllerBridgeTrackerDevice] { trackers?.devices ?? [] }

    var alignment: (text: String, tone: TrackerAlignStatus.Tone)? {
        trackers.map(TrackerAlignStatus.describe)
    }

    var phase: ControllerBridgeTrackers.AlignPhase { trackers?.alignPhase ?? .idle }

    /// Whether the primary button should offer a realignment rather than a first one.
    var everythingAligned: Bool {
        let tracked = devices.filter { $0.isTracked }
        return !tracked.isEmpty && tracked.allSatisfy { $0.isAligned }
    }

    /// The headset's own controllers (Quest or Sense, tracked and forwarded by this
    /// headset) as pseudo-devices, so they get drawn beside the PC's.
    static func localDevices(from packet: ControllerBridgeTrackedControllers?) -> [ControllerBridgeTrackerDevice] {
        guard let packet else { return [] }
        var out: [ControllerBridgeTrackerDevice] = []
        for (index, side) in [packet.left, packet.right].enumerated() {
            guard side.flags.contains(.present), side.flags.contains(.tracked) else { continue }
            var d = ControllerBridgeTrackerDevice()
            d.key = index == 0 ? "headset:left" : "headset:right"
            d.position = side.position
            d.orientation = side.orientation
            d.kind = .touch
            d.flags = [.tracked, .placed, .aligned]
            if side.flags.contains(.inHand) { d.flags.insert(.held) }
            d.battery = side.battery
            d.ownsHand = Int8(index)
            out.append(d)
        }
        return out
    }
}
#endif
