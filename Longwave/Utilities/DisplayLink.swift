import QuartzCore

#if os(macOS)
import AppKit
#endif

/// Creates a `CADisplayLink` in a platform-appropriate way.
///
/// On visionOS/iOS a display link is constructed directly. On macOS (14+) a
/// `CADisplayLink` can only be vended by a screen/view/window, so we ask the
/// main screen. The returned link is configured and scheduled by the caller
/// exactly as before (`preferredFrameRateRange`, `add(to:forMode:)`,
/// `invalidate()` are all available on both platforms).
enum DisplayLinkFactory {
    static func make(target: Any, selector: Selector) -> CADisplayLink? {
        #if os(macOS)
        // Prefer the screen the app is on; fall back to any screen.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return screen.displayLink(target: target, selector: selector)
        #else
        return CADisplayLink(target: target, selector: selector)
        #endif
    }
}
