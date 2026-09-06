import CoreGraphics

/// Turns continuous scroll travel — a mouse wheel's or a trackpad's, measured
/// in view points — into whole scroll-wheel "lines", which is the unit both
/// the Native host (`CGEvent` line units) and VNC take.
///
/// Travel that doesn't add up to a whole line is carried to the next event, so
/// a slow wheel still scrolls instead of rounding away to nothing.
struct ScrollStepAccumulator {
    /// View points of travel per line. A wheel detent arrives as roughly this
    /// much translation, so one notch reads as one line.
    var pointsPerStep: CGFloat = 10

    /// Ceiling per event. The MX Master's free-spinning wheel can deliver
    /// hundreds of points in a single callback; without a cap the host jumps
    /// several pages per frame and the stream looks like it teleported.
    var maxStepsPerEvent: Int = 10

    private var remainderX: CGFloat = 0
    private var remainderY: CGFloat = 0

    // Spelled out because the private remainders would otherwise make the
    // memberwise initializer private too.
    init(pointsPerStep: CGFloat = 10, maxStepsPerEvent: Int = 10) {
        self.pointsPerStep = pointsPerStep
        self.maxStepsPerEvent = maxStepsPerEvent
    }

    /// Whole line steps earned by this delta. Sign follows the host's wheel
    /// convention: positive = content moves down / right, i.e. scrolling
    /// towards the beginning.
    mutating func steps(for delta: CGSize) -> (dx: Int16, dy: Int16) {
        guard pointsPerStep > 0 else { return (0, 0) }

        remainderX += delta.width
        remainderY += delta.height

        let stepsX = Int((remainderX / pointsPerStep).rounded(.towardZero))
        let stepsY = Int((remainderY / pointsPerStep).rounded(.towardZero))

        remainderX -= CGFloat(stepsX) * pointsPerStep
        remainderY -= CGFloat(stepsY) * pointsPerStep

        return (clamp(stepsX), clamp(stepsY))
    }

    /// Drop the partial travel — at the end of a gesture, or when the pointer
    /// moves somewhere else, so leftovers can't leak into the next scroll.
    mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    private func clamp(_ steps: Int) -> Int16 {
        Int16(max(-maxStepsPerEvent, min(maxStepsPerEvent, steps)))
    }
}
