import XCTest
import RoyalVNCKit
@testable import Longwave

/// The on-screen keyboard we own: its three-state modifier latches, the US
/// layout's shape, and the VNC keysym sequence a modified key produces.
@MainActor
final class VirtualKeyboardTests: XCTestCase {

    // MARK: - Latches

    func testTapArmsThenLocksThenClears() {
        var latch = VirtualModifierLatch()

        // Arming is local — nothing goes to the remote until it's locked.
        XCTAssertEqual(latch.tap(.control), .none)
        XCTAssertEqual(latch.state(of: .control), .oneShot)
        XCTAssertEqual(latch.active, .control)

        XCTAssertEqual(latch.tap(.control), .hold(.control))
        XCTAssertEqual(latch.state(of: .control), .locked)

        XCTAssertEqual(latch.tap(.control), .release(.control))
        XCTAssertEqual(latch.state(of: .control), .off)
        XCTAssertTrue(latch.active.isEmpty)
    }

    func testOneShotClearsAfterAKeyButLockedSurvives() {
        var latch = VirtualModifierLatch()
        _ = latch.tap(.shift)                 // one-shot
        _ = latch.tap(.control)               // one-shot
        _ = latch.tap(.control)               // locked

        XCTAssertEqual(latch.consumeOneShot(), .shift)
        XCTAssertTrue(latch.oneShot.isEmpty)
        XCTAssertEqual(latch.locked, .control)
        XCTAssertEqual(latch.active, .control)

        // A second key still gets the locked modifier, and nothing to wrap.
        XCTAssertTrue(latch.consumeOneShot().isEmpty)
        XCTAssertEqual(latch.active, .control)
    }

    func testResetReportsOnlyWhatIsHeldOnTheRemote() {
        var latch = VirtualModifierLatch()
        _ = latch.tap(.option)                // one-shot, never sent
        _ = latch.tap(.command)
        _ = latch.tap(.command)               // locked, held down remotely

        XCTAssertEqual(latch.reset(), .command)
        XCTAssertTrue(latch.active.isEmpty)
    }

    // MARK: - Layout

    func testEveryMainRowIsTheSameWidth() {
        for (index, row) in VirtualKeyboardLayout.mainRows.enumerated() {
            let units = row.reduce(0) { $0 + $1.width }
            XCTAssertEqual(units, VirtualKeyboardLayout.mainRowUnits, accuracy: 0.001,
                           "row \(index) is \(units) units wide")
        }
    }

    func testNavRowsAreThreeWideAndMatchTheMainBlock() {
        XCTAssertEqual(VirtualKeyboardLayout.navRows.count, VirtualKeyboardLayout.mainRows.count)
        for row in VirtualKeyboardLayout.navRows {
            XCTAssertEqual(Double(row.count), VirtualKeyboardLayout.navRowUnits)
        }
    }

    func testKeyCapIDsAreUnique() {
        let ids = (VirtualKeyboardLayout.mainRows.flatMap { $0 }.map(\.id))
            + VirtualKeyboardLayout.navRows.flatMap { $0 }.compactMap { $0?.id }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testStrokeIndexResolvesShiftedGlyphsToTheirPhysicalKey() {
        // Moonlight speaks physical keys plus a shift bit, so "!" must resolve to
        // the 1 key, not to a key of its own.
        let bang = VirtualKeyboardLayout.stroke(typing: "!")
        XCTAssertEqual(bang, VirtualKeyStroke(key: .character(base: "1", shifted: "!"), shift: true))

        let upper = VirtualKeyboardLayout.stroke(typing: "G")
        XCTAssertEqual(upper, VirtualKeyStroke(key: .character(base: "g", shifted: "G"), shift: true))

        let lower = VirtualKeyboardLayout.stroke(typing: "g")
        XCTAssertEqual(lower?.shift, false)

        XCTAssertNil(VirtualKeyboardLayout.stroke(typing: "é"))
    }

    // MARK: - VNC events

    /// The regression this whole keyboard exists for: a latched Ctrl plus "g"
    /// used to reach the remote as a bare "g", because text was the only thing
    /// the mirrored text field could carry.
    func testControlGSendsRealKeysymsAndNeverText() {
        let events = VNCKeyboardSink.events(
            for: .character(base: "g", shifted: "G"), modifiers: .control, held: [])

        XCTAssertEqual(events, [
            .down(.control),
            .down(VNCKeyCode(asciiCharacter: UInt8(ascii: "g"))),
            .up(VNCKeyCode(asciiCharacter: UInt8(ascii: "g"))),
            .up(.control),
        ])
    }

    func testUnmodifiedTypingKeepsTheTextRoute() {
        // Plain characters still go out as text so the Mac companion's Unicode
        // injection can handle layouts and accents.
        XCTAssertEqual(
            VNCKeyboardSink.events(for: .character(base: "g", shifted: "G"), modifiers: [], held: []),
            [.text("g")])
        XCTAssertEqual(
            VNCKeyboardSink.events(for: .backspace, modifiers: [], held: []),
            [.backspace(1)])
    }

    func testShiftPicksTheShiftedKeysymAndStillPressesShift() {
        let events = VNCKeyboardSink.events(
            for: .character(base: "1", shifted: "!"), modifiers: .shift, held: [])

        XCTAssertEqual(events, [
            .down(.shift),
            .down(VNCKeyCode(asciiCharacter: UInt8(ascii: "!"))),
            .up(VNCKeyCode(asciiCharacter: UInt8(ascii: "!"))),
            .up(.shift),
        ])
    }

    func testHeldModifiersAreNotPressedAgain() {
        // A locked Ctrl is already down on the remote; re-pressing it around
        // every key would look like auto-repeat.
        let events = VNCKeyboardSink.events(
            for: .character(base: "c", shifted: "C"), modifiers: [.control, .shift], held: .control)

        XCTAssertEqual(events, [
            .down(.shift),
            .down(VNCKeyCode(asciiCharacter: UInt8(ascii: "C"))),
            .up(VNCKeyCode(asciiCharacter: UInt8(ascii: "C"))),
            .up(.shift),
        ])
    }

    func testModifiersUnwindInReverseOrder() {
        let events = VNCKeyboardSink.events(
            for: .escape, modifiers: [.control, .option, .command], held: [])

        // Pressed control → option → command, released command → option → control.
        XCTAssertEqual(events, [
            .down(.control), .down(.option), .down(.command),
            .down(.escape), .up(.escape),
            .up(.command), .up(.option), .up(.control),
        ])
    }

    func testSpecialKeysMapToTheirKeysyms() {
        // The RoyalVNCKit naming trap: `.delete` is backspace.
        XCTAssertEqual(VNCKeyboardSink.keyCodes(for: .backspace, shifted: false), [.delete])
        XCTAssertEqual(VNCKeyboardSink.keyCodes(for: .forwardDelete, shifted: false), [.forwardDelete])
        XCTAssertEqual(VNCKeyboardSink.keyCodes(for: .function(1), shifted: false), [.f1])
        XCTAssertEqual(VNCKeyboardSink.keyCodes(for: .function(12), shifted: false), [.f12])
        XCTAssertEqual(VNCKeyboardSink.keyCodes(for: .function(13), shifted: false), [])
        XCTAssertEqual(VNCKeyboardSink.keyCodes(for: .capsLock, shifted: false), [VNCKeyCode(0xFFE5)])
    }
}
