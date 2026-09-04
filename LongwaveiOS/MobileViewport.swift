import CoreGraphics

/// Zoom and pan for a remote surface drawn on a phone.
///
/// A phone is far smaller than the desktop it shows, so zoom and pan are
/// load-bearing, and rendering and hit-testing must agree to the pixel —
/// computing the two apart is how a remote pointer lands near, but not on, the
/// tap. This is the single source of truth for both, shared by the VNC and
/// Native desktop views; `content` is the remote surface's pixel size.
struct MobileViewport: Equatable {
    /// 1.0 == fit the whole surface on screen. Zoom is about a pinch anchor, so
    /// pan has to be tracked alongside it.
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    /// Zoom bounds. Below 1 there is empty space around a surface that already
    /// fits; past 6× a pixel is a thumb wide and the pointer stops being aimable.
    static let zoomRange: ClosedRange<CGFloat> = 1...6

    var isDefault: Bool { zoom == 1 && pan == .zero }

    /// Where the surface is drawn, for the current zoom and pan.
    struct Layout {
        let origin: CGPoint
        let drawn: CGSize
        /// Surface pixels → screen points.
        let scale: CGFloat
    }

    func layout(content: CGSize, in size: CGSize) -> Layout {
        guard content.width > 0, content.height > 0, size.width > 0, size.height > 0 else {
            return Layout(origin: .zero, drawn: size, scale: 1)
        }
        let fit = min(size.width / content.width, size.height / content.height)
        let scale = fit * zoom
        let drawn = CGSize(width: content.width * scale, height: content.height * scale)
        let clamped = Self.clampedPan(pan, drawn: drawn, in: size)
        return Layout(
            origin: CGPoint(
                x: (size.width - drawn.width) / 2 + clamped.width,
                y: (size.height - drawn.height) / 2 + clamped.height
            ),
            drawn: drawn,
            scale: scale
        )
    }

    /// Keeps the surface from being flung off screen: an axis larger than the
    /// screen may pan up to its overhang, an axis that already fits stays centred.
    static func clampedPan(_ proposed: CGSize, drawn: CGSize, in size: CGSize) -> CGSize {
        let slackX = max(0, (drawn.width - size.width) / 2)
        let slackY = max(0, (drawn.height - size.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -slackX), slackX),
            height: min(max(proposed.height, -slackY), slackY)
        )
    }

    /// View point → surface pixel, or nil for a touch outside the surface.
    func contentPoint(_ point: CGPoint, content: CGSize, in size: CGSize) -> (x: UInt16, y: UInt16)? {
        guard content.width > 0, content.height > 0 else { return nil }
        let layout = self.layout(content: content, in: size)
        guard layout.scale > 0 else { return nil }
        let x = (point.x - layout.origin.x) / layout.scale
        let y = (point.y - layout.origin.y) / layout.scale
        guard x >= 0, y >= 0, x < content.width, y < content.height else { return nil }
        return (UInt16(x.rounded(.down)), UInt16(y.rounded(.down)))
    }

    /// Surface pixel → view point, for drawing a local cursor.
    func viewPoint(x: UInt16, y: UInt16, content: CGSize, in size: CGSize) -> CGPoint {
        let layout = self.layout(content: content, in: size)
        return CGPoint(
            x: layout.origin.x + CGFloat(x) * layout.scale,
            y: layout.origin.y + CGFloat(y) * layout.scale
        )
    }

    mutating func magnify(by factor: CGFloat, about anchor: CGPoint, content: CGSize, in size: CGSize) {
        let old = zoom
        let new = min(max(old * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard new != old else { return }
        // Keep the pixel under the fingers under the fingers: shift the pan by how
        // far that point moves when the scale changes.
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let offsetFromCentre = CGSize(
            width: anchor.x - centre.x - pan.width,
            height: anchor.y - centre.y - pan.height
        )
        let ratio = new / old
        zoom = new
        pan = CGSize(
            width: pan.width - offsetFromCentre.width * (ratio - 1),
            height: pan.height - offsetFromCentre.height * (ratio - 1)
        )
        pan = Self.clampedPan(pan, drawn: layout(content: content, in: size).drawn, in: size)
    }

    mutating func pan(by delta: CGSize, content: CGSize, in size: CGSize) {
        let proposed = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
        pan = Self.clampedPan(proposed, drawn: layout(content: content, in: size).drawn, in: size)
    }

    /// Toggles between fitting the surface and showing it at true pixel size,
    /// which is the zoom that actually matters for reading text.
    mutating func toggleZoom(content: CGSize, in size: CGSize) {
        guard content.width > 0, content.height > 0, size.width > 0, size.height > 0 else { return }
        let fit = min(size.width / content.width, size.height / content.height)
        // 1:1 in surface pixels per screen point, expressed as a zoom factor.
        let oneToOne = min(max(1 / fit, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        if zoom > 1.01 {
            zoom = 1
        } else {
            zoom = oneToOne
        }
        pan = .zero
    }

    mutating func reset() {
        zoom = 1
        pan = .zero
    }
}
