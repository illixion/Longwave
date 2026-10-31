//  TrackerDebugEndpoints.swift
//
//  A fake tracker hub, so the Trackers panel and the wireframes can be looked at without a PC:
//  `trackersDemo on` starts a feed that plays a wand sweeping, a Touch controller resting, a
//  puck that is not aligned until an alignment runs, and the whole align cycle (waiting,
//  collecting, done). It speaks the real wire format — each tick is encoded and decoded again
//  before it reaches the model — and it answers the panel's commands the way a host does, so
//  the buttons, the role menus and the acknowledgement path all work against it.
//
//  Registered only when the debug server runs (`DebugTraceServer.requestedAtLaunch`), like the
//  gamepad endpoints: a development build, never a shipped one. A compile-time `#if DEBUG`
//  would be the wrong gate, because device builds are Release.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import DebugTrace
import Foundation
import QuartzCore
import simd

@MainActor
final class TrackerDemoFeed {
    static let shared = TrackerDemoFeed()

    private(set) var model: TrackerHubModel?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        let model = TrackerHubModel()
        self.model = model
        TrackerHubModel.demo = model
        var script = Script()
        task = Task { @MainActor in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                let now = CACurrentMediaTime()
                script.step(now: now, model: model)
                if let wire = ControllerBridgeTrackers(script.packet(now: now).encoded()) {
                    model.ingest(wire, now: now)
                }
                deadline += .milliseconds(33)
                try? await clock.sleep(until: deadline)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        TrackerHubModel.demo = nil
        model = nil
    }

    /// The fake host's state. A value type with a `step`, so what it does is a function of
    /// the clock and the commands it was given.
    struct Script {
        var started: CFTimeInterval = 0
        var sequence: UInt8 = 0
        var ackSequence: UInt8 = 0
        var ackResult: ControllerBridgeTrackers.Result = .none
        var phase: ControllerBridgeTrackers.AlignPhase = .idle
        var phaseSince: CFTimeInterval = 0
        var auto = true
        var puckAligned = false
        var roles: [String: UInt8] = ["lighthouse:LHR-DEMO0001": TrackerRole.leftHand.rawValue]

        static let wand = "lighthouse:LHR-DEMO0001"
        static let touch = "quest:demo-left"
        static let puck = "lighthouse:LHR-DEMO0002"

        mutating func step(now: CFTimeInterval, model: TrackerHubModel) {
            if started == 0 { started = now; phaseSince = now }
            if let packet = model.packetToSend(now: now), let command = model.commandInFlight {
                _ = packet
                model.markSent(now: now)
                apply(command, now: now)
                ackSequence = model.commandSequence
                ackResult = .ok
            }
            let elapsed = now - phaseSince
            switch phase {
            case .idle: if auto && elapsed > 6 { enter(.waiting, now) }
            case .waiting: if elapsed > 2.5 { enter(.collecting, now) }
            case .collecting: if elapsed > 6 { puckAligned = true; enter(.done, now) }
            case .done: if elapsed > 5 { enter(.idle, now) }
            }
        }

        private mutating func enter(_ next: ControllerBridgeTrackers.AlignPhase, _ now: CFTimeInterval) {
            phase = next
            phaseSince = now
        }

        private mutating func apply(_ command: ControllerBridgeTrackerCommand, now: CFTimeInterval) {
            switch command.op {
            case .alignStart: enter(.waiting, now)
            case .alignStop: enter(.idle, now)
            case .reset: puckAligned = false; enter(.idle, now)
            case .assign: roles[command.key] = command.arg
            case .unassign: roles[command.key] = 0
            case .setAutoAlign: auto = command.arg != 0
            }
        }

        mutating func packet(now: CFTimeInterval) -> ControllerBridgeTrackers {
            sequence &+= 1
            let t = Float(now - started)
            var p = ControllerBridgeTrackers()
            p.sequence = sequence
            p.flags = [.hubActive, .headValid]
            if phase != .idle { p.flags.insert(.autoAlign) }
            p.ackSequence = ackSequence
            p.ackResult = ackResult
            p.alignPhase = phase
            let elapsed = Float(now - phaseSince)

            var wand = ControllerBridgeTrackerDevice()
            wand.key = Self.wand
            wand.kind = .wand
            wand.position = [0.35 * sin(t * 1.2), 1.15 + 0.1 * sin(t * 0.7), -0.5]
            wand.orientation = simd_quatf(angle: 0.6 * sin(t * 1.2), axis: [0, 1, 0])
                * simd_quatf(angle: 0.3 * sin(t * 0.9), axis: [1, 0, 0])
            wand.speed = 0.35 * 1.2 * abs(cos(t * 1.2))
            wand.flags = [.tracked, .placed, .aligned, .held, .moving]
            wand.role = roles[Self.wand] ?? 0
            wand.battery = 87
            wand.ownsHand = wand.role == TrackerRole.leftHand.rawValue ? 0
                : wand.role == TrackerRole.rightHand.rawValue ? 1 : -1

            var touch = ControllerBridgeTrackerDevice()
            touch.key = Self.touch
            touch.kind = .touch
            touch.position = [-0.3, 1.0 + 0.01 * sin(t), -0.45]
            touch.orientation = simd_quatf(angle: 0.4, axis: [0, 1, 0])
            touch.flags = [.tracked, .placed, .aligned]
            touch.role = roles[Self.touch] ?? 0
            touch.battery = 64

            var puck = ControllerBridgeTrackerDevice()
            puck.key = Self.puck
            puck.kind = .tracker
            puck.position = [0.0, 0.35, -0.6]
            puck.flags = puckAligned ? [.tracked, .placed, .aligned] : [.tracked]
            puck.role = roles[Self.puck] ?? 0
            puck.battery = 41

            p.devices = [wand, touch, puck]
            if phase == .collecting {
                p.alignDevice = 0
                p.alignHand = 0
                p.alignSamples = Int(elapsed / 6 * 24)
                p.alignSpreadMeters = min(0.25, elapsed / 6 * 0.25)
                p.alignSpreadTargetMeters = 0.25
            } else if phase == .done {
                p.alignResidualMm = 3.1
                p.alignDevice = 0
                p.alignHand = 0
            }
            return p
        }
    }
}

@MainActor
enum TrackerDebugEndpoints {
    struct Reply: Encodable {
        var running: Bool
    }

    static func register() {
        DebugSurface.shared.register([
            .command("trackersDemo",
                     "Start (on) or stop (off) a fake tracker hub: a wand sweeping, a Touch controller, a puck that is not aligned until an alignment runs, and the align cycle. Drives the Trackers panel in the PCVR control window and the wireframes in the immersive space with no PC; the panel's buttons work against it",
                     parameters: [
                        .boolean("on", "true to start the feed, false to stop it", required: true),
                     ]) { args in
                if try args.requireBool("on") { TrackerDemoFeed.shared.start() } else { TrackerDemoFeed.shared.stop() }
                return Reply(running: TrackerDemoFeed.shared.isRunning)
            },
        ])
    }
}
#endif
