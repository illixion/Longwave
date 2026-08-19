import AppKit

/// Works out how much of the now-playing label the menu bar can actually hold,
/// so a long title spends the slack that is there instead of a fixed guess.
///
/// macOS lays status items out right to left, so a label that grows shoves its
/// left-hand neighbours toward the app menus — and on a notched display under
/// the notch, where the system silently drops them. A full-length Safari video
/// title is wide enough to cost a neighbour (Stats.app, in the report that
/// prompted this) its slot on a MacBook Pro, while the same title fits with room
/// to spare on a 2560pt external display, so a character cap is either too tight
/// or too loose depending on where the menu bar happens to be.
///
/// Nothing in AppKit reports the remaining room, so it is reconstructed from
/// geometry:
///
/// - our own item's frame comes from its `NSStatusBarWindow`;
/// - every item on the same menu bar comes from the window list. macOS hosts all
///   of them in Control Center, so they can't be told apart by owning process —
///   only by geometry, which is all this needs;
/// - the leftmost point items may occupy is the right edge of the notch, or an
///   allowance for the frontmost app's menus on a display without one.
///
/// What's left after the other items take their share is ours. The measurement
/// deliberately doesn't depend on our own label's current width, so it can't
/// ratchet itself wider or narrower over successive tracks.
@Observable
final class MenuBarLabelFitter {
    /// Points available to our label, or nil until a measurement lands — the
    /// item has to exist on the menu bar before it can be measured. Zero is a
    /// real answer, meaning the menu bar is full.
    private(set) var availableWidth: CGFloat?

    private var pollTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.measure() }
        }
    }

    deinit {
        pollTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Whether to keep watching the menu bar. Worth doing only while the label
    /// is actually on it, and needed because the geometry changes with no
    /// notification to hang off: every display has its own menu bar and the item
    /// follows whichever one is active, so moving between the built-in display
    /// and an external one silently changes the answer. Other apps adding and
    /// removing items is just as quiet.
    func setPolling(_ polling: Bool) {
        guard polling != (pollTask != nil) else { return }
        guard polling else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.measure()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// `text` trimmed to fit the menu bar, with `trailing` kept whole so a
    /// truncated title doesn't lose the marker on the end of it. Nil means show
    /// something else entirely: there is no room left for even a stub, or the
    /// menu bar hasn't been measured yet. Waiting for that measurement — a frame
    /// or two, and only for the first track after launch — is better than
    /// guessing, because a guess that lands too wide displaces a neighbour and
    /// then gets measured as if the neighbour had never been there.
    func fit(_ text: String, trailing: String = "") -> String? {
        guard let availableWidth, availableWidth >= Self.minimumUsefulWidth else { return nil }
        return Self.truncating(text, trailing: trailing, toWidth: availableWidth)
    }

    /// Re-reads the menu bar. Cheap enough for the poll: one window-list call.
    func measure() {
        let measured = Self.measureAvailableWidth()
        // Only publish real changes: every write invalidates the label's view.
        if let measured, let availableWidth, abs(measured - availableWidth) < 1 { return }
        if measured == nil && availableWidth == nil { return }
        availableWidth = measured
    }

    // MARK: - Geometry

    private static func measureAvailableWidth() -> CGFloat? {
        guard let own = ownStatusItemWindow(),
              let screen = own.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(own.frame) })
        else { return nil }
        // Everything except our own item — matched by position, since the window
        // list can't say who owns what. Our own width deliberately plays no part
        // in the arithmetic below, so the answer doesn't drift as the label it
        // produces changes the thing being measured.
        let others = statusItemFrames(onMenuBarOf: screen)
            .filter { abs($0.minX - own.frame.minX) > 2 }
        guard let occupiedLeft = others.map(\.minX).min() else { return nil }
        let room = (occupiedLeft - leftBoundary(of: screen)) - safetyGap - labelPadding
        return min(max(0, room), maximumLabelWidth)
    }

    /// SwiftUI's `MenuBarExtra` keeps its `NSStatusItem` private, so the item is
    /// identified the other way round: our only visible window sitting at the
    /// status level and as short as the menu bar. The popover it opens is a
    /// panel, and far taller.
    private static func ownStatusItemWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible
                && $0.level.rawValue == Int(CGWindowLevelForKey(.statusWindow))
                && $0.frame.height <= menuBarWindowMaxHeight
        }
    }

    /// Frames of the status items on `screen`'s menu bar. In the window list's
    /// flipped coordinates, but only x is ever read from these.
    private static func statusItemFrames(onMenuBarOf screen: NSScreen) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        // The list is flipped against AppKit and anchored on the zero-origin
        // display, which puts `screen`'s menu bar here. Displays stacked
        // vertically share x ranges, hence matching on y rather than x alone.
        let zeroOrigin = NSScreen.screens.first { $0.frame.origin == .zero }
        let menuBarTop = (zeroOrigin?.frame.maxY ?? screen.frame.maxY) - screen.frame.maxY
        let candidates: [CGRect] = windows.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == statusLevel,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.height <= menuBarWindowMaxHeight,
                  abs(frame.minY - menuBarTop) < 5,
                  frame.midX >= screen.frame.minX, frame.midX <= screen.frame.maxX
            else { return nil }
            return frame
        }
        // Alongside the items themselves the list carries wider windows that
        // enclose a group of them, and those reach into empty menu bar that is
        // free for the taking — counting one as occupied costs ~300pt of label.
        return candidates.filter { frame in
            !candidates.contains { $0 != frame && frame.minX <= $0.minX && frame.maxX >= $0.maxX }
        }
    }

    /// Leftmost point our item may reach. Two things can stop it, so respect
    /// whichever is further right.
    private static func leftBoundary(of screen: NSScreen) -> CGFloat {
        // Status items never cross to the left of the notch, so that edge binds
        // on a built-in display; `auxiliaryTopRightArea` is the strip beside it.
        let notch = screen.safeAreaInsets.top > 0 ? screen.auxiliaryTopRightArea?.minX : nil
        return max(notch ?? screen.frame.minX, screen.frame.minX + appMenuAllowance)
    }

    // MARK: - Text

    private static func truncating(_ text: String, trailing: String, toWidth width: CGFloat) -> String? {
        let font = labelFont
        if measuredWidth(text + trailing, font: font) <= width { return text + trailing }
        var characters = Array(text)
        while !characters.isEmpty {
            characters.removeLast()
            while characters.last?.isWhitespace == true { characters.removeLast() }
            let candidate = String(characters) + "…" + trailing
            if measuredWidth(candidate, font: font) <= width { return candidate }
        }
        return nil
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    /// What SwiftUI renders a `MenuBarExtra` label in: the menu bar font one
    /// point down, which reproduced the item's rendered width to within a point
    /// at every length tried. Derived rather than hardcoded so it follows the
    /// system if that font changes size.
    private static var labelFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize - 1)
    }

    // MARK: - Tuning

    /// Room left for the frontmost app's menus, which win when the two regions
    /// collide. Their real width is the exact boundary and it moves with every
    /// app switch, but reading it needs Accessibility — too much to ask for a
    /// menu bar label, and denied to this app in practice — so it's a constant
    /// set above the widest menu bar measured while writing this: Finder's menus
    /// end at ≈380pt, VS Code's at ≈830pt. An app wider still can cost a
    /// neighbour its slot on a display without a notch; the notched case, which
    /// is the one that actually bit, is exact regardless.
    private static let appMenuAllowance: CGFloat = 850
    /// Ceiling regardless of how much room there is. A label that runs half the
    /// width of a 5K display is its own kind of broken, and stopping well short
    /// of the boundary leaves the estimate above room to be wrong.
    private static let maximumLabelWidth: CGFloat = 560
    /// Kept clear so a measurement that is a point or two optimistic doesn't
    /// cost anyone their item.
    private static let safetyGap: CGFloat = 16
    /// Padding AppKit puts around the label inside the item.
    private static let labelPadding: CGFloat = 10
    /// Under this there is no point showing text at all — a two-character stub
    /// says less than the icon it would replace.
    private static let minimumUsefulWidth: CGFloat = 56
    private static let menuBarWindowMaxHeight: CGFloat = 40
    private static let pollInterval = Duration.seconds(3)
}
