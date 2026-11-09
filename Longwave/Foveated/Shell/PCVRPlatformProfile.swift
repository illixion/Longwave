#if FOVEATED_ENABLED && os(visionOS)
import StreamWire

/// What this headset can do, and the presets built on it. The PC is told plain
/// numbers (`PCVRPreferences`); everything that depends on the display lives
/// here, per platform, because only the client knows its display.
enum PCVRPlatformProfile {
    /// The Vision Pro's render eye at native density: its centre's ~1860 pixels
    /// per unit tangent over the whole display frustum, plus 2% overscan.
    static let nativeEye = PixelSize(width: 5184, height: 4160)
    /// The slowest stream worth showing; the PC's own step-down stops here too.
    static let minimumStreamHertz = 45.0
    /// Wire eye sizes are rounded to this so both eyes and the codec's blocks line up.
    static let eyeAlignment = 16

    /// The render eye at `scale` of native density, aligned and within the wire's range.
    static func renderEye(scale: Double) -> PixelSize {
        func aligned(_ v: UInt16) -> UInt16 {
            let a = Double(eyeAlignment)
            return UInt16(min(max((Double(v) * scale / a).rounded() * a, 256), 8192))
        }
        return PixelSize(width: aligned(nativeEye.width), height: aligned(nativeEye.height))
    }

    static func preferences(quality: PCVRQualityPreset, frameRate: PCVRFrameRatePreset,
                            displayHertz: Double?) -> PCVRPreferences {
        PCVRPreferences(renderEye: renderEye(scale: quality.scale),
                        maxStreamMillihertz: frameRate.capMillihertz(displayHertz: displayHertz),
                        minStreamMillihertz: UInt32(minimumStreamHertz * 1000))
    }
}

/// How much picture a game renders, as a share of native density.
enum PCVRQualityPreset: Int, CaseIterable {
    case performance = 1
    case balanced = 2
    case quality = 3
    case maximum = 4

    var scale: Double {
        switch self {
        case .performance: 0.70
        case .balanced: 0.85
        case .quality: 1.00
        case .maximum: 1.15
        }
    }

    var label: String {
        switch self {
        case .performance: "Performance — 70%, the lightest"
        case .balanced: "Balanced — 85%"
        case .quality: "Quality — native density"
        case .maximum: "Maximum — 115%, supersampled"
        }
    }
}

/// What the stream's frame rate follows. Only rates that meet the display's
/// refreshes evenly: a fixed cap that doesn't divide the display rate (90 on
/// a 120 Hz display) repeats every third frame.
enum PCVRFrameRatePreset: Int, CaseIterable {
    /// One frame per refresh, stepping down when the PC can't keep up.
    case matchDisplay = 0
    /// Each frame for two refreshes: 60 fps at 120 Hz, 48 at 96, 45 at 90.
    case halfDisplay = 5

    /// The cap for a display at `displayHertz` (nil: unknown), millihertz; 0 follows the display.
    func capMillihertz(displayHertz: Double?) -> UInt32 {
        switch self {
        case .matchDisplay: return 0
        case .halfDisplay:
            guard let displayHertz, displayHertz > 0 else { return 0 }
            return UInt32((max(displayHertz / 2, PCVRPlatformProfile.minimumStreamHertz) * 1000).rounded())
        }
    }

    var label: String {
        switch self {
        case .matchDisplay: "Match display"
        case .halfDisplay: "Half display rate"
        }
    }
}
#endif
