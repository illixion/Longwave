import Foundation
import RAVEInput

/// What a pad's readings have been doing: when its input and its motion last changed, how
/// often they did, and a short history of the gyro.
///
/// Fed one snapshot per frame by `GamepadVisualizerView`. "Changed" is the only liveness
/// signal a polled `GCController` offers: a pad visionOS is not routing to the app keeps
/// reporting its last values, indistinguishable from a pad nobody touches. So the ages are
/// read next to what the person holding it is doing, and motion is the sharper of the two:
/// a gyro that is actually streaming moves in its last digits even on a table.
struct GamepadActivity {
    /// Gyro samples kept for the trace (about four seconds at the visualizer's 30 fps).
    static let traceLength = 120

    private(set) var last: RAVEGamepadSnapshot?
    private(set) var inputChangedAt: TimeInterval?
    private(set) var motionChangedAt: TimeInterval?
    private(set) var inputChanges = 0
    private(set) var motionChanges = 0
    /// Oldest first.
    private(set) var gyroTrace: [SIMD3<Float>] = []

    mutating func record(_ snapshot: RAVEGamepadSnapshot, at now: TimeInterval) {
        if let last {
            if !Self.sameInput(last, snapshot) {
                inputChanges += 1
                inputChangedAt = now
            }
            if last.rotationRate != snapshot.rotationRate || last.acceleration != snapshot.acceleration {
                motionChanges += 1
                motionChangedAt = now
            }
        }
        last = snapshot
        if let gyro = snapshot.rotationRate {
            gyroTrace.append(gyro)
            if gyroTrace.count > Self.traceLength { gyroTrace.removeFirst(gyroTrace.count - Self.traceLength) }
        }
    }

    func secondsSinceInputChange(now: TimeInterval) -> TimeInterval? { inputChangedAt.map { now - $0 } }
    func secondsSinceMotionChange(now: TimeInterval) -> TimeInterval? { motionChangedAt.map { now - $0 } }

    private static func sameInput(_ a: RAVEGamepadSnapshot, _ b: RAVEGamepadSnapshot) -> Bool {
        a.buttons == b.buttons && a.leftStick == b.leftStick && a.rightStick == b.rightStick
            && a.leftTrigger == b.leftTrigger && a.rightTrigger == b.rightTrigger
    }
}
