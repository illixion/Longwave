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

    private struct Frame: PCVRPlayoutFrame, Equatable {
        var streamEpoch: UInt32 = 0
        let frameNumber: UInt32
        var spaceEpoch: UInt16 = 0
    }

    private func frame(_ number: UInt32, stream: UInt32 = 0, space: UInt16 = 0) -> Frame {
        Frame(streamEpoch: stream, frameNumber: number, spaceEpoch: space)
    }

    func testNothingToShowBeforeTheFirstFrame() {
        var slot = PCVRLatestFrameSlot<Frame>()
        XCTAssertNil(slot.takeForPresentation(spaceEpoch: 0).frame)
        XCTAssertEqual(slot.repeated, 0, "an empty slot is not a repeat")
    }

    func testHalfRateSourceRepeatsEveryOtherSlot() {
        // 45 fps into a 90 Hz display: new, repeat, new, repeat.
        var slot = PCVRLatestFrameSlot<Frame>()
        var shown: [(UInt32, Bool)] = []
        for number in UInt32(1)...4 {
            slot.deliver(frame(number))
            for _ in 0..<2 {
                let next = slot.takeForPresentation(spaceEpoch: 0)
                if let shownFrame = next.frame { shown.append((shownFrame.frameNumber, next.isNew)) }
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
        var slot = PCVRLatestFrameSlot<Frame>()
        XCTAssertNil(slot.deliver(frame(1)))
        XCTAssertEqual(slot.deliver(frame(2)), frame(1), "the displaced frame comes back")
        slot.deliver(frame(3))
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).frame, frame(3))
        XCTAssertEqual(slot.dropped, 2)
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).isNew, false)
    }

    func testPresentingANewFrameReleasesTheOldCurrent() {
        // The mailbox lets that frame go after unlocking, so its texture's
        // release never runs under the lock.
        var slot = PCVRLatestFrameSlot<Frame>()
        slot.deliver(frame(1))
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).released, [])
        slot.deliver(frame(2))
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).released, [frame(1)])
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).released, [], "a repeat releases nothing")
    }

    func testLateFramesAreDroppedAcrossTheWrap() {
        var slot = PCVRLatestFrameSlot<Frame>()
        slot.deliver(frame(.max - 1))
        _ = slot.takeForPresentation(spaceEpoch: 0)
        // Older than what is showing: never steps the picture backwards.
        XCTAssertEqual(slot.deliver(frame(.max - 3)), frame(.max - 3))
        XCTAssertEqual(slot.dropped, 1)
        // Wrapped past zero is newer, not older.
        XCTAssertNil(slot.deliver(frame(2)))
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).frame, frame(2))
        XCTAssertEqual(slot.dropped, 1)
    }

    func testStreamRestartAcceptsNumberingFromOneAgain() {
        // A host reconnecting inside one open space starts over at frame 1. With
        // no stream epoch every new frame would read as older than the last old
        // one, and the shell would reproject that one forever.
        var slot = PCVRLatestFrameSlot<Frame>()
        slot.deliver(frame(5_000))
        _ = slot.takeForPresentation(spaceEpoch: 0)
        XCTAssertEqual(slot.deliver(frame(1)), frame(1), "same run: frame 1 is late")
        XCTAssertNil(slot.deliver(frame(1, stream: 1)), "new run: accepted")
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).frame, frame(1, stream: 1))
        XCTAssertNil(slot.deliver(frame(2, stream: 1)))
        // A straggler from the replaced run is dropped, whatever its number.
        XCTAssertEqual(slot.deliver(frame(5_001, stream: 0)), frame(5_001, stream: 0))
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).frame, frame(2, stream: 1))
    }

    func testStreamRestartReplacesAPendingFrameOfTheOldRun() {
        var slot = PCVRLatestFrameSlot<Frame>()
        slot.deliver(frame(9))
        XCTAssertEqual(slot.deliver(frame(1, stream: 7)), frame(9))
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).frame, frame(1, stream: 7))
        // Stream epochs compare like frame numbers: half the range ahead reads
        // as a run already replaced.
        XCTAssertEqual(slot.deliver(frame(2, stream: 0x8000_0007)), frame(2, stream: 0x8000_0007))
    }

    func testRecentreShowsNothingUntilFramesFromTheNewEpochArrive() {
        var slot = PCVRLatestFrameSlot<Frame>()
        slot.deliver(frame(1, space: 0))
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 0).frame, frame(1, space: 0))

        // Recentre: the display pose is now in epoch 1. The last frame was
        // rendered for the old origin, so it is not repeated.
        XCTAssertNil(slot.takeForPresentation(spaceEpoch: 1).frame)
        // A frame still in flight from before the recentre is dropped, not shown.
        slot.deliver(frame(2, space: 0))
        let stale = slot.takeForPresentation(spaceEpoch: 1)
        XCTAssertNil(stale.frame)
        XCTAssertEqual(stale.released, [frame(2, space: 0)])
        XCTAssertEqual(slot.dropped, 1)
        // The first frame rendered in the new epoch is shown and then repeated.
        slot.deliver(frame(3, space: 1))
        let fresh = slot.takeForPresentation(spaceEpoch: 1)
        XCTAssertEqual(fresh.frame, frame(3, space: 1))
        XCTAssertEqual(fresh.released, [frame(1, space: 0)])
        XCTAssertEqual(slot.takeForPresentation(spaceEpoch: 1).frame, frame(3, space: 1))
    }

    /// The wraparound cases StreamWire tests (`InputAndStateTests.
    /// testLatestWinsWithWraparound`, `StreamFormatTableTests.
    /// testFirstFrameNumbersWrap`), so this copy cannot drift from
    /// `SerialNumber.isNewer` before the app links the package.
    func testSerialNumberMatchesStreamWire() {
        // Sequence 1 supersedes UInt32.max, not the reverse, and not itself.
        XCTAssertTrue(PCVRSerialNumber.isNewer(1, than: .max))
        XCTAssertFalse(PCVRSerialNumber.isNewer(.max, than: 1))
        XCTAssertFalse(PCVRSerialNumber.isNewer(1, than: 1))
        // A format starting at 3 follows one that started at max - 1; frame max
        // still belongs to the earlier one, frame 4 to the later.
        XCTAssertTrue(PCVRSerialNumber.isNewer(3, than: .max - 1))
        XCTAssertFalse(PCVRSerialNumber.isNewer(.max - 1, than: 3))
        XCTAssertTrue(PCVRSerialNumber.isNewer(.max, than: .max - 1))
        XCTAssertFalse(PCVRSerialNumber.isNewer(3, than: 4))
        // The half-range boundary.
        XCTAssertTrue(PCVRSerialNumber.isNewer(0x7FFF_FFFF, than: 0))
        XCTAssertFalse(PCVRSerialNumber.isNewer(0x8000_0000, than: 0))
    }

    // MARK: Head-pose producer

    private let eyes = PCVRStereo(
        left: PCVREyeGeometry(deviceFromEye: PCVRPose(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), position: SIMD3(-0.032, 0, 0)),
                              fieldOfView: PCVRFieldOfView(tangentLeft: -1, tangentRight: 0.9, tangentUp: 1, tangentDown: -1.1)),
        right: PCVREyeGeometry(deviceFromEye: PCVRPose(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), position: SIMD3(0.032, 0, 0)),
                               fieldOfView: PCVRFieldOfView(tangentLeft: -0.9, tangentRight: 1, tangentUp: 1, tangentDown: -1.1)))

    private func snapshot(_ producer: PCVRHeadPoseProducer, at time: TimeInterval,
                          eyes: PCVRStereo<PCVREyeGeometry>? = nil, horizon: TimeInterval = 0) -> PCVRHeadPoseSnapshot {
        producer.makeSnapshot(head: .identity, eyes: eyes ?? self.eyes, sampledAt: time,
                              baseDisplayTime: time + 0.02, displayTime: time + 0.02 + horizon)
    }

    func testEverySnapshotCarriesTheEyes() {
        // STATE frames can be lost: a host that missed every snapshot but one
        // must still be able to render from that one.
        let producer = PCVRHeadPoseProducer()
        let first = snapshot(producer, at: 10)
        let second = snapshot(producer, at: 10.011)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(first.eyes, eyes)
        XCTAssertEqual(second.eyes, eyes, "unchanged eyes are sent again")

        var wider = eyes
        wider.left.deviceFromEye.position.x -= 0.001
        wider.right.deviceFromEye.position.x += 0.001
        XCTAssertEqual(snapshot(producer, at: 10.022, eyes: wider).eyes, wider)
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
