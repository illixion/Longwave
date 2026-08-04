import XCTest
@testable import VisionVNC

/// Pacing policy for streaming producers (SSH terminal feed, VNC framebuffer)
/// while the user is entering text. The point is that an idle app is never
/// throttled, and that a dictation session — the fragile one — gets the widest
/// spacing.
final class TextEntryPacingTests: XCTestCase {
    func testIdleIsNotPacedAtAll() {
        XCTAssertEqual(TextEntryPacing.minimumUpdateInterval(for: .idle), .zero)
    }

    func testEditingAndDictationAreBothPaced() {
        XCTAssertGreaterThan(TextEntryPacing.minimumUpdateInterval(for: .editing), .zero)
        XCTAssertGreaterThan(TextEntryPacing.minimumUpdateInterval(for: .dictating), .zero)
    }

    /// Dictation is the case that breaks, so it must never be paced *less* than
    /// plain typing — including if the intervals are ever retuned.
    func testDictationIsPacedNoTighterThanTyping() {
        XCTAssertGreaterThanOrEqual(
            TextEntryPacing.minimumUpdateInterval(for: .dictating),
            TextEntryPacing.minimumUpdateInterval(for: .editing)
        )
    }

    /// Paced intervals stay short enough that a streamed terminal still reads as
    /// live (several updates a second) rather than frozen.
    func testPacedIntervalsStayVisiblyLive() {
        XCTAssertLessThanOrEqual(
            TextEntryPacing.minimumUpdateInterval(for: .dictating), .seconds(1)
        )
    }
}
