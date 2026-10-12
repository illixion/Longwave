import XCTest
import simd
@testable import Longwave

/// Latest-wins playout and the head-pose uplink: the bookkeeping that turns
/// "frames arrive whenever" into "one frame per display slot" and measures
/// what the stream's latency actually was. Pure values, so the timelines here
/// are written out rather than waited for.
///
/// Gated with the feature, like the rest of PCVR.
#if FOVEATED_ENABLED
final class PCVRPlayoutTests: XCTestCase {

    // MARK: Latest-frame slot

    func testNothingToShowBeforeTheFirstFrame() {
        var slot = PCVRLatestFrameSlot<Int>()
        XCTAssertNil(slot.takeForPresentation())
        XCTAssertEqual(slot.repeated, 0, "an empty slot is not a repeat")
    }

    func testHalfRateSourceRepeatsEveryOtherSlot() {
        // 45 fps into a 90 Hz display: new, repeat, new, repeat.
        var slot = PCVRLatestFrameSlot<Int>()
        var shown: [(Int, Bool)] = []
        for frame in 1...4 {
            slot.deliver(frame)
            for _ in 0..<2 {
                if let next = slot.takeForPresentation() { shown.append((next.frame, next.isNew)) }
            }
        }
        XCTAssertEqual(shown.map(\.0), [1, 1, 2, 2, 3, 3, 4, 4])
        XCTAssertEqual(shown.map(\.1), [true, false, true, false, true, false, true, false])
        XCTAssertEqual(slot.presentedNew, 4)
        XCTAssertEqual(slot.repeated, 4)
        XCTAssertEqual(slot.dropped, 0)
    }

    func testFramesArrivingTogetherDropAllButTheNewest() {
        // A network burst: three frames land inside one display slot. VR shows
        // the newest; queueing the others would only add latency.
        var slot = PCVRLatestFrameSlot<Int>()
        slot.deliver(1)
        slot.deliver(2)
        slot.deliver(3)
        XCTAssertEqual(slot.takeForPresentation()?.frame, 3)
        XCTAssertEqual(slot.dropped, 2)
        XCTAssertEqual(slot.takeForPresentation()?.isNew, false)
    }

    func testResetForgetsFramesButKeepsCounts() {
        var slot = PCVRLatestFrameSlot<Int>()
        slot.deliver(1)
        slot.deliver(2)
        _ = slot.takeForPresentation()
        slot.reset()
        XCTAssertNil(slot.takeForPresentation())
        XCTAssertEqual(slot.dropped, 1)
        XCTAssertEqual(slot.presentedNew, 1)
    }

    // MARK: Head-pose producer

    private let eyes = PCVRStereo(
        left: PCVREyeGeometry(deviceFromEye: PCVRPose(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), position: SIMD3(-0.032, 0, 0)),
                              fieldOfView: PCVRFieldOfView(left: 1, right: 0.9, up: 1, down: 1.1)),
        right: PCVREyeGeometry(deviceFromEye: PCVRPose(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), position: SIMD3(0.032, 0, 0)),
                               fieldOfView: PCVRFieldOfView(left: 0.9, right: 1, up: 1, down: 1.1)))

    private func snapshot(_ producer: PCVRHeadPoseProducer, at time: TimeInterval,
                          eyes: PCVRStereo<PCVREyeGeometry>? = nil, horizon: TimeInterval = 0) -> PCVRHeadPoseSnapshot {
        producer.makeSnapshot(head: .identity, eyes: eyes ?? self.eyes, sampledAt: time,
                              baseDisplayTime: time + 0.02, displayTime: time + 0.02 + horizon)
    }

    func testSnapshotsAreSequencedAndCarryEyeOffsetsOnlyWhenChanged() {
        let producer = PCVRHeadPoseProducer()
        let first = snapshot(producer, at: 10)
        let second = snapshot(producer, at: 10.011)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(first.eyes, eyes, "the first snapshot introduces the eyes")
        XCTAssertNil(second.eyes, "unchanged eyes are not resent")

        // Sub-tenth-of-a-millimetre jitter is noise, not an IPD change.
        var jittered = eyes
        jittered.left.deviceFromEye.position.x += 0.00002
        XCTAssertNil(snapshot(producer, at: 10.022, eyes: jittered).eyes)

        var wider = eyes
        wider.left.deviceFromEye.position.x -= 0.001
        wider.right.deviceFromEye.position.x += 0.001
        XCTAssertEqual(snapshot(producer, at: 10.033, eyes: wider).eyes, wider)
        XCTAssertFalse(second.gaze.isValid, "gaze stays invalid without the entitlement")
    }

    func testRecentreBumpsTheEpoch() {
        let producer = PCVRHeadPoseProducer()
        XCTAssertEqual(snapshot(producer, at: 1).spaceEpoch, 0)
        producer.bumpSpaceEpoch()
        XCTAssertEqual(snapshot(producer, at: 1.011).spaceEpoch, 1)
    }

    func testPresentationReportsMotionToPhotonAndLastFrame() {
        let producer = PCVRHeadPoseProducer()
        let pose = snapshot(producer, at: 5)
        let poseToPresent = producer.recordPresentation(frameNumber: 42, poseSequence: pose.sequence, presentTime: 5.065)
        XCTAssertEqual(try XCTUnwrap(poseToPresent), 0.065, accuracy: 1e-9)
        let next = snapshot(producer, at: 5.066)
        XCTAssertEqual(next.lastPresentedFrame, 42)
        XCTAssertEqual(try XCTUnwrap(next.lastPresentTime), 5.065, accuracy: 1e-9)
        XCTAssertNil(producer.recordPresentation(frameNumber: 43, poseSequence: 999, presentTime: 5.08),
                     "a pose the producer never made has no latency")
    }

    func testPredictionHorizonLearnsThePipelineLatencyAndIsClamped() {
        let producer = PCVRHeadPoseProducer()
        XCTAssertEqual(producer.predictionHorizon, 0)
        // Every frame is shown 40 ms after the display time its pose was taken for.
        var time: TimeInterval = 100
        for _ in 0..<100 {
            let pose = snapshot(producer, at: time, horizon: producer.predictionHorizon)
            producer.recordPresentation(frameNumber: pose.sequence, poseSequence: pose.sequence,
                                        presentTime: time + 0.02 + 0.04)
            time += 1.0 / 90
        }
        // Measured against the base display time, so predicting further ahead
        // does not feed back into what is measured.
        XCTAssertEqual(producer.predictionHorizon, 0.04, accuracy: 1e-3)

        let slow = PCVRHeadPoseProducer()
        let pose = snapshot(slow, at: 0)
        slow.recordPresentation(frameNumber: 1, poseSequence: pose.sequence, presentTime: 0.5)
        XCTAssertEqual(slow.predictionHorizon, PCVRHeadPoseProducer.maximumPredictionHorizon)
    }
}
#endif
