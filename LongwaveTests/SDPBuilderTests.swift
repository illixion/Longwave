import XCTest
@testable import Longwave

final class SDPBuilderTests: XCTestCase {

    // Minimal plausible SPS: NAL header 0x67, profile 0x64 (High),
    // constraints 0x00, level 0x28 (4.0).
    private let sps = Data([0x67, 0x64, 0x00, 0x28, 0xAC, 0xB2])
    private let pps = Data([0x68, 0xEE, 0x38, 0x80])

    func testVideoOnlySDP() {
        let sdp = SDPBuilder.build(sessionName: "Test", sps: sps, pps: pps, audioChannels: nil)
        XCTAssertTrue(sdp.contains("m=video 0 RTP/AVP 96"))
        XCTAssertTrue(sdp.contains("a=rtpmap:96 H264/90000"))
        XCTAssertTrue(sdp.contains("packetization-mode=1"))
        XCTAssertTrue(sdp.contains("profile-level-id=640028"))
        XCTAssertTrue(sdp.contains("sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())"))
        XCTAssertTrue(sdp.contains("a=control:trackID=0"))
        XCTAssertFalse(sdp.contains("m=audio"))
        XCTAssertTrue(sdp.hasSuffix("\r\n"))
    }

    func testAudioTrackMono() {
        let sdp = SDPBuilder.build(sessionName: "Test", sps: sps, pps: pps, audioChannels: 1)
        XCTAssertTrue(sdp.contains("m=audio 0 RTP/AVP 97"))
        XCTAssertTrue(sdp.contains("a=rtpmap:97 opus/48000/2"), "rtpmap channel count is always 2 per RFC 7587")
        XCTAssertTrue(sdp.contains("sprop-stereo=0"))
        XCTAssertTrue(sdp.contains("a=control:trackID=1"))
    }

    func testAudioTrackStereo() {
        let sdp = SDPBuilder.build(sessionName: "Test", sps: sps, pps: pps, audioChannels: 2)
        XCTAssertTrue(sdp.contains("sprop-stereo=1"))
    }

    func testShortSPSFallsBackToDefaultProfile() {
        let sdp = SDPBuilder.build(sessionName: "Test", sps: Data([0x67]), pps: pps, audioChannels: nil)
        XCTAssertTrue(sdp.contains("profile-level-id=42C01F"))
    }

    func testCRLFLineEndings() {
        let sdp = SDPBuilder.build(sessionName: "Test", sps: sps, pps: pps, audioChannels: 1)
        XCTAssertFalse(sdp.contains("\n\n"))
        XCTAssertTrue(sdp.components(separatedBy: "\r\n").count > 10)
    }
}
