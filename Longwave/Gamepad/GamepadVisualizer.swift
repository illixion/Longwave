import DebugTraceServer
import Foundation
import GameController
import Observation
import RAVEInput
import simd
import SwiftUI

/// A live drawing of what the app is reading from each pad, for settling "is the input
/// reaching us" by looking rather than by reading numbers back over the debug server.
///
/// It draws the roster's own snapshot, the one every reader sends, so what it shows is
/// what Moonlight and the PCVR bridge get. It never subscribes, claims a pad or asks for
/// motion: a pad shows up only while a real reader holds it, and the IMU runs only if a
/// reader asked. A diagnostic that switched sensors on would hide the very bug it was
/// brought in for.
///
/// Shown only on request from the debug server (`gamepadVisualizer`), which a shipping
/// build never registers: in the Moonlight stream window's corner and on a panel in the
/// PCVR immersive space. The choice outlives a relaunch (a reboot shouldn't hide it
/// mid-investigation), but is honoured only in a build whose debug server runs: dev
/// builds share the App Store bundle id, so a TestFlight install over one inherits its
/// defaults. Same shape as RAVEFilm's `FilmObjectMap`; it can move into RAVE
/// once a second app wants it.
@MainActor @Observable
final class GamepadVisualizer {

    static let shared = GamepadVisualizer()

    var isShown: Bool {
        didSet { UserDefaults.standard.set(isShown, forKey: Self.shownKey) }
    }

    private static let shownKey = "gamepadVisualizerShown"

    /// One pad as last drawn.
    struct Reading {
        var slot: Int
        var productCategory: String
        var gyro: Bool
        var accelerometer: Bool
        var sensorsActive: Bool?
        var motionRequests: Int
        var snapshot: RAVEGamepadSnapshot
        var activity: GamepadActivity
        /// When this controller object was first drawn in its slot. A reconnect is a new
        /// object, so its history starts over rather than blending into the old one's.
        var trackedSince: TimeInterval
    }

    private struct Track {
        var controller: ObjectIdentifier
        var activity = GamepadActivity()
        var since: TimeInterval
    }

    // Written while drawing, so it must not invalidate the view that draws it.
    @ObservationIgnored private var tracks: [Int: Track] = [:]
    @ObservationIgnored private(set) var drawnAt: [String: TimeInterval] = [:]

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private init() {
        isShown = DebugTraceServer.requestedAtLaunch && UserDefaults.standard.bool(forKey: Self.shownKey)
        GamepadRoster.shared.recordsDeliveries = isShown
    }

    /// Reads every held pad, records it and returns what to draw.
    func sample(drawnIn place: String) -> [Reading] {
        let roster = GamepadRoster.shared
        let now = Self.now
        drawnAt[place] = now
        var readings: [Reading] = []
        for slot in roster.controllers.keys.sorted() {
            guard let controller = roster.controllers[slot], let snapshot = roster.snapshot(slot: slot) else { continue }
            let id = ObjectIdentifier(controller)
            var track = tracks[slot].flatMap { $0.controller == id ? $0 : nil } ?? Track(controller: id, since: now)
            track.activity.record(snapshot, at: now)
            tracks[slot] = track
            let sensors = roster.motionSensors(slot: slot)
            readings.append(Reading(
                slot: slot, productCategory: controller.productCategory,
                gyro: sensors.gyro, accelerometer: sensors.accelerometer,
                sensorsActive: controller.motion?.sensorsActive,
                motionRequests: roster.motionRequests(slot: slot),
                snapshot: snapshot, activity: track.activity, trackedSince: track.since))
        }
        for slot in tracks.keys where roster.controllers[slot] == nil { tracks[slot] = nil }
        return readings
    }

    /// What the drawing measured, for the debug server: the same ages the panel shows.
    func activity(slot: Int) -> (activity: GamepadActivity, trackedSince: TimeInterval)? {
        tracks[slot].map { ($0.activity, $0.since) }
    }
}

/// The visualizer itself. `place` names where it is drawn ("moonlight", "pcvr"), shown in
/// its header and reported by the debug server, so a reading is never mistaken for
/// another context's.
struct GamepadVisualizerView: View {
    let place: String

    static let size = CGSize(width: 440, height: 300)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            Canvas { context, size in
                let readings = GamepadVisualizer.shared.sample(drawnIn: place)
                let scale = min(size.width / Self.size.width, size.height / Self.size.height)
                context.scaleBy(x: scale, y: scale)
                GamepadDrawing(place: place, now: GamepadVisualizer.now).draw(readings, in: &context)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The Canvas drawing, in the view's 440 × 300 pt design space.
private struct GamepadDrawing {
    let place: String
    let now: TimeInterval

    private static let axisColours: [Color] = [.red, .green, .blue]
    /// Full scale of the gyro bars and trace: a brisk wrist turn.
    private static let gyroFullScale: Float = 360
    private static let accelFullScale: Float = 2

    func draw(_ readings: [GamepadVisualizer.Reading], in context: inout GraphicsContext) {
        let card = CGRect(origin: .zero, size: GamepadVisualizerView.size)
        context.fill(Path(roundedRect: card, cornerRadius: 16), with: .color(.black.opacity(0.6)))
        context.stroke(Path(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 16),
                       with: .color(.white.opacity(0.25)), lineWidth: 1)

        guard let reading = readings.first else {
            text("Gamepad · \(place)", at: CGPoint(x: 16, y: 20), in: &context, size: 15, weight: .semibold)
            text("No pad held: nothing is reading gamepads here.", at: CGPoint(x: 16, y: 150), in: &context,
                 colour: .orange)
            return
        }
        let s = reading.snapshot
        let more = readings.count > 1 ? "  +\(readings.count - 1) more" : ""
        text("Pad \(reading.slot) · \(reading.productCategory) · \(place)\(more)",
             at: CGPoint(x: 16, y: 20), in: &context, size: 15, weight: .semibold)

        // Shoulders and triggers.
        shoulder(s.buttons.contains(.leftShoulder), trigger: s.leftTrigger,
                 at: CGPoint(x: 20, y: 40), label: "L", in: &context)
        shoulder(s.buttons.contains(.rightShoulder), trigger: s.rightTrigger,
                 at: CGPoint(x: 350, y: 40), label: "R", in: &context)

        // Sticks, d-pad, the three small buttons and the face buttons.
        stick(s.leftStick, pressed: s.buttons.contains(.leftStick), at: CGPoint(x: 55, y: 108), in: &context)
        stick(s.rightStick, pressed: s.buttons.contains(.rightStick), at: CGPoint(x: 385, y: 108), in: &context)
        let dpad = CGPoint(x: 128, y: 108)
        square(s.buttons.contains(.dpadUp), at: CGPoint(x: dpad.x, y: dpad.y - 15), in: &context)
        square(s.buttons.contains(.dpadDown), at: CGPoint(x: dpad.x, y: dpad.y + 15), in: &context)
        square(s.buttons.contains(.dpadLeft), at: CGPoint(x: dpad.x - 15, y: dpad.y), in: &context)
        square(s.buttons.contains(.dpadRight), at: CGPoint(x: dpad.x + 15, y: dpad.y), in: &context)
        dot(s.buttons.contains(.options), at: CGPoint(x: 190, y: 84), radius: 7, label: "−", in: &context)
        dot(s.buttons.contains(.home), at: CGPoint(x: 220, y: 84), radius: 7, label: "⌂", in: &context)
        dot(s.buttons.contains(.menu), at: CGPoint(x: 250, y: 84), radius: 7, label: "+", in: &context)
        // GameController's names, in Xbox positions (a at the bottom).
        let face = CGPoint(x: 312, y: 108)
        dot(s.buttons.contains(.y), at: CGPoint(x: face.x, y: face.y - 17), radius: 9, label: "y", in: &context)
        dot(s.buttons.contains(.b), at: CGPoint(x: face.x + 17, y: face.y), radius: 9, label: "b", in: &context)
        dot(s.buttons.contains(.a), at: CGPoint(x: face.x, y: face.y + 17), radius: 9, label: "a", in: &context)
        dot(s.buttons.contains(.x), at: CGPoint(x: face.x - 17, y: face.y), radius: 9, label: "x", in: &context)

        // Gyro: bars, values and a trace.
        text("gyro °/s", at: CGPoint(x: 16, y: 160), in: &context, size: 11, colour: .secondary)
        if let gyro = s.rotationRate {
            let degrees = gyro * (180 / .pi)
            for axis in 0..<3 {
                bar(degrees[axis], fullScale: Self.gyroFullScale, y: 160 + CGFloat(axis) * 14, axis: axis, in: &context)
            }
            trace(reading.activity.gyroTrace, in: CGRect(x: 300, y: 152, width: 124, height: 44), into: &context)
        } else {
            text(reading.gyro ? "—" : "no gyro", at: CGPoint(x: 80, y: 174), in: &context, colour: .secondary)
        }

        // Accelerometer: bars and the magnitude, which reads about 1 g at rest.
        text("accel g", at: CGPoint(x: 16, y: 212), in: &context, size: 11, colour: .secondary)
        if let accel = s.acceleration {
            for axis in 0..<3 {
                bar(accel[axis], fullScale: Self.accelFullScale, y: 212 + CGFloat(axis) * 14, axis: axis,
                    format: "%+.2f", in: &context)
            }
            text(String(format: "|a| %.2f g", simd_length(accel)), at: CGPoint(x: 300, y: 226), in: &context,
                 size: 12, colour: .secondary)
        } else {
            text("—", at: CGPoint(x: 80, y: 226), in: &context, colour: .secondary)
        }

        // Liveness: what changed, and when.
        let activity = reading.activity
        let input = activity.secondsSinceInputChange(now: now)
            .map { String(format: "input changed %.1f s ago · %d changes", $0, activity.inputChanges) }
            ?? "input unchanged since drawn"
        text(input, at: CGPoint(x: 16, y: 262), in: &context, size: 12)
        let (motion, motionColour) = motionLine(reading)
        text(motion, at: CGPoint(x: 16, y: 278), in: &context, size: 12, colour: motionColour)
        let sensors = switch reading.sensorsActive {
        case true?: "IMU on"
        case false?: "IMU off"
        case nil: "no GCMotion"
        }
        text(String(format: "%@ · %d asking · tracked %.0f s", sensors, reading.motionRequests, now - reading.trackedSince),
             at: CGPoint(x: 16, y: 293), in: &context, size: 11, colour: .secondary)
    }

    private func motionLine(_ reading: GamepadVisualizer.Reading) -> (String, Color) {
        guard reading.gyro || reading.accelerometer else { return ("no motion sensors", .secondary) }
        guard reading.sensorsActive != false else { return ("motion off: no reader asked for it", .secondary) }
        let changes = reading.activity.motionChanges
        guard let age = reading.activity.secondsSinceMotionChange(now: now) else {
            return (String(format: "motion never changed (%.0f s)", now - reading.trackedSince), .red)
        }
        if age > 1 { return (String(format: "motion still for %.1f s · %d changes", age, changes), .red) }
        return (String(format: "motion live · %d changes", changes), .green)
    }

    // MARK: Pieces

    private func text(_ string: String, at point: CGPoint, in context: inout GraphicsContext,
                      size: CGFloat = 13, weight: Font.Weight = .regular, colour: Color = .white) {
        context.draw(Text(string).font(.system(size: size, weight: weight, design: .monospaced))
                        .foregroundStyle(colour),
                     at: point, anchor: .leading)
    }

    private func lit(_ on: Bool) -> GraphicsContext.Shading { .color(on ? .yellow : .white.opacity(0.15)) }

    private func dot(_ on: Bool, at centre: CGPoint, radius: CGFloat, label: String, in context: inout GraphicsContext) {
        let rect = CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
        context.fill(Path(ellipseIn: rect), with: lit(on))
        context.draw(Text(label).font(.system(size: radius * 1.2, weight: .bold))
                        .foregroundStyle(on ? Color.black : .white),
                     at: centre)
    }

    private func square(_ on: Bool, at centre: CGPoint, in context: inout GraphicsContext) {
        context.fill(Path(roundedRect: CGRect(x: centre.x - 7, y: centre.y - 7, width: 14, height: 14), cornerRadius: 3),
                     with: lit(on))
    }

    private func shoulder(_ pressed: Bool, trigger: Float, at origin: CGPoint, label: String,
                          in context: inout GraphicsContext) {
        context.fill(Path(roundedRect: CGRect(x: origin.x, y: origin.y, width: 70, height: 12), cornerRadius: 4),
                     with: lit(pressed))
        context.draw(Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(pressed ? Color.black : .white),
                     at: CGPoint(x: origin.x + 35, y: origin.y + 6))
        let track = CGRect(x: origin.x, y: origin.y + 16, width: 70, height: 8)
        context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(.white.opacity(0.15)))
        var fill = track
        fill.size.width *= CGFloat(max(0, min(trigger, 1)))
        context.fill(Path(roundedRect: fill, cornerRadius: 3), with: .color(.yellow))
    }

    private func stick(_ value: SIMD2<Float>, pressed: Bool, at centre: CGPoint, in context: inout GraphicsContext) {
        let radius: CGFloat = 30
        let ring = CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
        context.fill(Path(ellipseIn: ring), with: .color(pressed ? .yellow.opacity(0.35) : .white.opacity(0.08)))
        context.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(0.5)), lineWidth: 1.5)
        // +y is up on the stick, down on the screen.
        let knob = CGPoint(x: centre.x + CGFloat(value.x) * radius, y: centre.y - CGFloat(value.y) * radius)
        var line = Path()
        line.move(to: centre)
        line.addLine(to: knob)
        context.stroke(line, with: .color(.white.opacity(0.6)), lineWidth: 2)
        context.fill(Path(ellipseIn: CGRect(x: knob.x - 7, y: knob.y - 7, width: 14, height: 14)),
                     with: .color(value == .zero ? .white : .yellow))
    }

    private func bar(_ value: Float, fullScale: Float, y: CGFloat, axis: Int, format: String = "%+5.0f",
                     in context: inout GraphicsContext) {
        let centreX: CGFloat = 160
        let halfWidth: CGFloat = 70
        let track = CGRect(x: centreX - halfWidth, y: y - 4, width: 2 * halfWidth, height: 8)
        context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(.white.opacity(0.12)))
        let length = CGFloat(max(-1, min(value / fullScale, 1))) * halfWidth
        let fill = CGRect(x: min(centreX, centreX + length), y: y - 4, width: abs(length), height: 8)
        context.fill(Path(fill), with: .color(Self.axisColours[axis]))
        text("xyz".map(String.init)[axis], at: CGPoint(x: 76, y: y), in: &context, size: 11, colour: Self.axisColours[axis])
        text(String(format: format, value), at: CGPoint(x: 238, y: y), in: &context, size: 11)
    }

    private func trace(_ samples: [SIMD3<Float>], in rect: CGRect, into context: inout GraphicsContext) {
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.white.opacity(0.06)))
        guard samples.count > 1 else { return }
        let step = rect.width / CGFloat(GamepadActivity.traceLength - 1)
        let startX = rect.maxX - CGFloat(samples.count - 1) * step
        for axis in 0..<3 {
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let degrees = sample[axis] * (180 / .pi)
                let normalised = CGFloat(max(-1, min(degrees / Self.gyroFullScale, 1)))
                let point = CGPoint(x: startX + CGFloat(index) * step, y: rect.midY - normalised * rect.height / 2)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Self.axisColours[axis]), lineWidth: 1.5)
        }
    }
}
