import Foundation

/// Makes a double-click land when the clicks come from a headset rather than a mouse.
///
/// Hosts decide a double-click happened from timing *and* proximity: the macOS
/// companion requires the second click within 4 points of the first, and Windows
/// applies `SM_CXDOUBLECLK`. A pinch-tap drifts further than that between taps —
/// gaze alone moves the point, and one view point can be several framebuffer
/// pixels on a 4K stream — so two deliberate taps arrive as two unrelated single
/// clicks and nothing opens.
///
/// Snapping a quick second click back onto the first one's coordinates is what
/// turns them into a double-click, without asking anyone to aim to within 4 px.
/// The anchor is kept rather than advanced, so a third quick tap triple-clicks.
struct DoubleClickCadence {
    /// Under the 500 ms both hosts default to, so we only ever snap when the
    /// host is also going to read the pair as a double-click.
    private let interval: TimeInterval = 0.4
    /// Framebuffer pixels of aim slop to forgive. This is deliberately much
    /// larger than the host's own threshold — it's headset aim, not mouse aim.
    private let slop = 48

    private var lastTime: Date?
    private var anchor: (x: UInt16, y: UInt16)?

    /// The coordinates to actually click at: the caller's point, or the previous
    /// click's point when this one reads as the second tap of a double-click.
    mutating func resolve(_ point: (x: UInt16, y: UInt16), now: Date = Date()) -> (x: UInt16, y: UInt16) {
        let previousTime = lastTime
        let previousAnchor = anchor
        lastTime = now

        guard let previousTime, let previousAnchor,
              now.timeIntervalSince(previousTime) < interval,
              abs(Int(point.x) - Int(previousAnchor.x)) <= slop,
              abs(Int(point.y) - Int(previousAnchor.y)) <= slop
        else {
            anchor = point
            return point
        }
        return previousAnchor
    }

    /// Forget the anchor — on disconnect, or when the pointer is driven by
    /// something that already has real double-click semantics.
    mutating func reset() {
        lastTime = nil
        anchor = nil
    }
}
