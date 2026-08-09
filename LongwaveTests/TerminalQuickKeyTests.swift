import XCTest
@testable import Longwave

/// Quick-key catalog selection round-trips and the ⌃-latch control-byte
/// transform backing the terminal key row.
@MainActor
final class TerminalQuickKeyTests: XCTestCase {

    func testCatalogIDsAreUnique() {
        let ids = TerminalQuickKey.catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testDefaultSelectionResolvesAgainstCatalog() {
        let enabled = TerminalQuickKey.enabledIDs(from: TerminalQuickKey.defaultSelectionStored)
        XCTAssertEqual(enabled.count, TerminalQuickKey.defaultSelectionIDs.count)
        XCTAssertTrue(enabled.contains("esc"))
        XCTAssertTrue(enabled.contains("ctrl-c"))
    }

    func testEncodeDecodeRoundTripPreservesCatalogOrder() {
        let enabled: Set<String> = ["enter", "esc", "ctrl-c"]
        let stored = TerminalQuickKey.encodeSelection(enabled)
        // Stable catalog order, not set order.
        XCTAssertEqual(stored, "esc,ctrl-c,enter")
        XCTAssertEqual(TerminalQuickKey.enabledIDs(from: stored), enabled)
    }

    func testUnknownIDsAreDropped() {
        let enabled = TerminalQuickKey.enabledIDs(from: "esc,removed-key,enter")
        XCTAssertEqual(enabled, ["esc", "enter"])
    }

    func testEmptySelectionMeansNoKeys() {
        // Empty string = user disabled everything (the "never set" case is
        // handled by the @AppStorage initial value, not the decoder).
        XCTAssertTrue(TerminalQuickKey.enabledIDs(from: "").isEmpty)
    }

    // MARK: - Control byte (⌃ latch)

    func testControlByteForLetters() {
        XCTAssertEqual(TerminalKeyEncoder.controlByte(for: "c"), 0x03)  // ⌃C
        XCTAssertEqual(TerminalKeyEncoder.controlByte(for: "C"), 0x03)
        XCTAssertEqual(TerminalKeyEncoder.controlByte(for: "a"), 0x01)
        XCTAssertEqual(TerminalKeyEncoder.controlByte(for: "z"), 0x1A)
        XCTAssertEqual(TerminalKeyEncoder.controlByte(for: "b"), 0x02)  // tmux prefix
    }

    func testControlByteForSymbols() {
        XCTAssertEqual(TerminalKeyEncoder.controlByte(for: "["), 0x1B)  // ESC
        XCTAssertEqual(TerminalKeyEncoder.controlByte(for: "@"), 0x00)
        XCTAssertEqual(TerminalKeyEncoder.controlByte(for: "_"), 0x1F)
    }

    func testControlByteRejectsNonMappable() {
        XCTAssertNil(TerminalKeyEncoder.controlByte(for: ""))
        XCTAssertNil(TerminalKeyEncoder.controlByte(for: "ab"))
        XCTAssertNil(TerminalKeyEncoder.controlByte(for: "1"))
        XCTAssertNil(TerminalKeyEncoder.controlByte(for: "ö"))
    }
}
