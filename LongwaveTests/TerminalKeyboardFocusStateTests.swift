import XCTest
@testable import Longwave

final class TerminalKeyboardFocusStateTests: XCTestCase {
    func testTransientFirstResponderLossKeepsDirectInputEnabled() {
        var state = TerminalKeyboardFocusState()
        state.request()
        state.firstResponderChanged(true)

        state.firstResponderChanged(false)

        XCTAssertTrue(state.isEnabled)
        XCTAssertFalse(state.hasFocus)
    }

    func testRequestAfterSystemDismissalCreatesNewFocusEdge() {
        var state = TerminalKeyboardFocusState()
        state.request()
        let firstRequest = state.requestID
        state.firstResponderChanged(false)

        state.request()

        XCTAssertTrue(state.isEnabled)
        XCTAssertGreaterThan(state.requestID, firstRequest)
    }

    func testAutomaticRequestsYieldWhileTheToggleTapDoesNot() {
        var state = TerminalKeyboardFocusState()

        // Window appeared / keyboard paired: must not cut off live dictation.
        state.request()
        XCTAssertFalse(state.requestIsDeliberate)

        // The user tapping the keyboard toggle asked for the handover.
        state.requestDeliberately()
        XCTAssertTrue(state.requestIsDeliberate)

        state.release()
        XCTAssertFalse(state.requestIsDeliberate)
    }

    func testComposerFocusReleasesTerminalButBlurDoesNotReclaimIt() {
        var state = TerminalKeyboardFocusState()
        state.request()
        state.firstResponderChanged(true)

        state.composerFocusChanged(true)
        state.composerFocusChanged(false)

        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.hasFocus)
    }
}
