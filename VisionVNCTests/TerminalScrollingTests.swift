import XCTest
import SwiftTerm
@testable import VisionVNC

/// Where a scroll goes depends on what the remote program asked for, and getting
/// it wrong is invisible until you're staring at a TUI that won't move. These
/// drive a real `VisionTerminalView`, feeding it the escape sequences a program
/// would, and assert on the bytes that come back out toward the pty.
@MainActor
final class TerminalScrollingTests: XCTestCase {
    /// Captures everything the terminal sends toward the remote.
    private final class Recorder: NSObject, TerminalViewDelegate {
        var sent: [UInt8] = []
        var text: String { String(decoding: sent, as: UTF8.self) }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func makeTerminal() -> (VisionTerminalView, Recorder) {
        let terminal = VisionTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let recorder = Recorder()
        terminal.terminalDelegate = recorder
        return (terminal, recorder)
    }

    private func feed(_ terminal: VisionTerminalView, _ sequence: String) {
        terminal.feed(byteArray: Array(sequence.utf8)[...])
    }

    /// The default agent CLI: a plain terminal, no mouse tracking. Scrolling is
    /// local scrollback movement, so nothing goes to the remote.
    func testPlainTerminalScrollsLocallyAndSendsNothing() {
        let (terminal, recorder) = makeTerminal()
        feed(terminal, "hello\r\n")

        XCTAssertFalse(terminal.remoteTracksMouse)
        XCTAssertTrue(terminal.scrollByLines(3))
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    /// A full-screen TUI that enabled mouse tracking (1000) with SGR reporting
    /// (1006) gets real wheel events: button 64 is wheel-up, one per line, at the
    /// reported cell — coordinates are 1-based on the wire.
    func testMouseTrackingProgramGetsWheelEvents() {
        let (terminal, recorder) = makeTerminal()
        feed(terminal, "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        recorder.sent.removeAll()

        XCTAssertTrue(terminal.remoteTracksMouse)
        XCTAssertTrue(terminal.scrollByLines(2, reportingAt: (col: 4, row: 2)))
        XCTAssertEqual(recorder.text, "\u{1b}[<64;5;3M\u{1b}[<64;5;3M")
    }

    func testScrollingDownReportsTheOtherWheelButton() {
        let (terminal, recorder) = makeTerminal()
        feed(terminal, "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        recorder.sent.removeAll()

        XCTAssertTrue(terminal.scrollByLines(-1, reportingAt: (col: 0, row: 0)))
        XCTAssertEqual(recorder.text, "\u{1b}[<65;1;1M")
    }

    /// A flick can resolve to a lot of lines at once; the burst is capped so a
    /// single gesture update can't flood the pty.
    func testWheelBurstIsCapped() {
        let (terminal, recorder) = makeTerminal()
        feed(terminal, "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        recorder.sent.removeAll()

        terminal.scrollByLines(500, reportingAt: (col: 0, row: 0))

        let events = recorder.text.components(separatedBy: "\u{1b}").filter { !$0.isEmpty }
        XCTAssertGreaterThan(events.count, 0)
        XCTAssertLessThanOrEqual(events.count, 8)
    }

    /// An alternate-screen program that never asked for mouse events has a
    /// viewport nothing here can move: reporting that lets the paging buttons fall
    /// back to PageUp/PageDown keys instead of scrolling an empty scrollback.
    func testAlternateScreenWithoutMouseTrackingDefersToTheCaller() {
        let (terminal, recorder) = makeTerminal()
        feed(terminal, "\u{1b}[?1049h")
        recorder.sent.removeAll()

        XCTAssertFalse(terminal.scrollByLines(3))
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    /// …and `scrollPage` is the caller that does exactly that.
    func testPageScrollFallsBackToKeysInAnAlternateScreen() {
        let (terminal, recorder) = makeTerminal()
        feed(terminal, "\u{1b}[?1049h")
        recorder.sent.removeAll()

        terminal.scrollPage(up: true)

        XCTAssertFalse(recorder.sent.isEmpty, "expected a PageUp key sequence")
    }
}
