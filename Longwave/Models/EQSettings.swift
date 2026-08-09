import Foundation

/// Filter shape of a single EQ band. Maps 1:1 onto
/// `AVAudioUnitEQFilterType` (parametric / lowShelf / highShelf) at the
/// DSP boundary in AudioStreamReceiver.
nonisolated enum EQBandType: String, Codable, Sendable {
    case parametric, lowShelf, highShelf
}

/// One user-editable EQ band. Frequency/gain/Q are stored in the units
/// the user thinks in (Hz / dB / Q); the conversion to
/// `AVAudioUnitEQBand.bandwidth` (octaves) happens at the DSP boundary.
nonisolated struct EQBandSetting: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var type: EQBandType = .parametric
    /// Center (parametric) or corner (shelf) frequency, Hz.
    var frequency: Double
    /// Boost/cut, dB.
    var gain: Double
    /// Resonance. Shelves ignore this in the editor (fixed gentle slope).
    var q: Double = 1.41

    /// Clamps all parameters into their legal ranges (drag handlers write
    /// raw values; the model never persists or renders out-of-range ones).
    func clamped() -> EQBandSetting {
        var band = self
        band.frequency = min(max(band.frequency, EQSettings.minFrequency), EQSettings.maxFrequency)
        band.gain = min(max(band.gain, -EQSettings.gainRange), EQSettings.gainRange)
        band.q = min(max(band.q, 0.1), 10)
        return band
    }
}

/// Global receiver-side EQ configuration: an enabled flag, a cut-only
/// preamp (headroom trim so big boosts don't clip the output stage), and
/// up to `maxBands` parametric/shelf bands. Persisted app-wide to
/// UserDefaults like the other audio prefs (`audioVolume`, `audioMode`).
///
/// Also hosts the analytic frequency-response math (RBJ Audio-EQ-Cookbook
/// biquads — the same filters AVAudioUnitEQ implements) so the editor can
/// draw the exact curve the audio path applies, and the free-form
/// draw-to-bands fit. Pure model + math: no UI, no AVFoundation.
nonisolated struct EQSettings: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// Headroom trim, dB. Cut-only (−12…0) by design: boosts happen in
    /// bands, the preamp only makes room for them.
    var preampDB: Double = 0
    /// When true (default) the preamp re-trims on every band change so
    /// the EQ never plays louder than flat. Off = manual slider; boosts
    /// can then clip on purpose.
    var autoPreamp: Bool = true
    var bands: [EQBandSetting] = []

    init() {}

    // Tolerant decoding so settings saved by older builds (or with future
    // fields removed) fall back to defaults instead of resetting the EQ.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        preampDB = try container.decodeIfPresent(Double.self, forKey: .preampDB) ?? 0
        autoPreamp = try container.decodeIfPresent(Bool.self, forKey: .autoPreamp) ?? true
        bands = try container.decodeIfPresent([EQBandSetting].self, forKey: .bands) ?? []
    }

    /// Matches the AVAudioUnitEQ band count allocated at node init
    /// (immutable after creation) — unused bands are bypassed.
    static let maxBands = 16
    static let minFrequency: Double = 20
    static let maxFrequency: Double = 20_000
    /// Editor y-axis half-range and per-band gain clamp, dB.
    static let gainRange: Double = 24

    // MARK: - Persistence

    static let defaultsKey = "audioEQSettings"

    static func load(from defaults: UserDefaults = .standard) -> EQSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(EQSettings.self, from: data)
        else { return EQSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Q ↔ bandwidth

    /// Converts a parametric band's Q to `AVAudioUnitEQBand.bandwidth`
    /// (octaves): `bw = (2 / ln 2) · asinh(1 / (2Q))`.
    static func bandwidthOctaves(q: Double) -> Double {
        (2 / log(2)) * asinh(1 / (2 * q))
    }

    // MARK: - Frequency response (for the editor curve)

    /// Sample rate used for *display* math only. The audible path runs at
    /// the wire rate (44.1/48 kHz); the visual difference below 20 kHz is
    /// negligible.
    static let displaySampleRate: Double = 48_000

    /// Combined response of the preamp + all bands at `hz`, in dB.
    /// Cascaded biquads multiply, so their dB responses sum.
    func responseDB(atHz hz: Double) -> Double {
        bands.reduce(preampDB) { $0 + Self.bandResponseDB(band: $1, hz: hz) }
    }

    /// Peak of the bands-only response (preamp excluded), in dB. Adjacent
    /// boosts sum, so this can exceed any single band's gain.
    func peakBandBoostDB() -> Double {
        guard !bands.isEmpty else { return 0 }
        let peak = responseCurve().map(\.db).max() ?? 0
        return peak - preampDB
    }

    /// Sets the preamp to exactly offset the peak band boost (clamped to
    /// the −12 dB trim floor), so an EQ curve never plays louder than
    /// flat. Called on band changes while `autoPreamp` is on.
    mutating func autoTrimPreamp() {
        preampDB = -min(12, max(0, peakBandBoostDB()))
    }

    /// Samples the combined response at `count` log-spaced frequencies
    /// across the editor's 20 Hz–20 kHz axis. Returns (hz, dB) pairs.
    func responseCurve(samples count: Int = 200) -> [(hz: Double, db: Double)] {
        let logMin = log10(Self.minFrequency)
        let logMax = log10(Self.maxFrequency)
        return (0..<count).map { i in
            let hz = pow(10, logMin + (logMax - logMin) * Double(i) / Double(count - 1))
            return (hz, responseDB(atHz: hz))
        }
    }

    /// Magnitude response of a single band at `hz`, in dB, from the RBJ
    /// Audio-EQ-Cookbook biquad coefficients evaluated at z = e^{jω}.
    static func bandResponseDB(band: EQBandSetting, hz: Double) -> Double {
        let (b0, b1, b2, a0, a1, a2) = coefficients(for: band)
        let w = 2 * Double.pi * hz / displaySampleRate
        // |H(e^{jw})|² = |b0 + b1·e^{-jw} + b2·e^{-2jw}|² / |a0 + a1·e^{-jw} + a2·e^{-2jw}|²
        func mag2(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let im = -(c1 * sin(w) + c2 * sin(2 * w))
            return re * re + im * im
        }
        let h2 = mag2(b0, b1, b2) / mag2(a0, a1, a2)
        return 10 * log10(max(h2, 1e-12))
    }

    /// RBJ cookbook coefficients (unnormalized — a0 included) for the
    /// band's filter type.
    private static func coefficients(for band: EQBandSetting)
        -> (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        let band = band.clamped()
        let A = pow(10, band.gain / 40)
        let w0 = 2 * Double.pi * band.frequency / displaySampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        // Shelves use a fixed gentle slope (Q ≈ 0.71) regardless of the
        // stored q — the editor hides the Q control for them, and this
        // matches AVAudioUnitEQ's shelf behavior closely.
        let q = band.type == .parametric ? band.q : 0.71
        let alpha = sinw / (2 * q)
        let sqA = sqrt(A)

        switch band.type {
        case .parametric:
            return (b0: 1 + alpha * A,
                    b1: -2 * cosw,
                    b2: 1 - alpha * A,
                    a0: 1 + alpha / A,
                    a1: -2 * cosw,
                    a2: 1 - alpha / A)
        case .lowShelf:
            return (b0: A * ((A + 1) - (A - 1) * cosw + 2 * sqA * alpha),
                    b1: 2 * A * ((A - 1) - (A + 1) * cosw),
                    b2: A * ((A + 1) - (A - 1) * cosw - 2 * sqA * alpha),
                    a0: (A + 1) + (A - 1) * cosw + 2 * sqA * alpha,
                    a1: -2 * ((A - 1) + (A + 1) * cosw),
                    a2: (A + 1) + (A - 1) * cosw - 2 * sqA * alpha)
        case .highShelf:
            return (b0: A * ((A + 1) + (A - 1) * cosw + 2 * sqA * alpha),
                    b1: -2 * A * ((A - 1) + (A + 1) * cosw),
                    b2: A * ((A + 1) + (A - 1) * cosw - 2 * sqA * alpha),
                    a0: (A + 1) - (A - 1) * cosw + 2 * sqA * alpha,
                    a1: 2 * ((A - 1) - (A + 1) * cosw),
                    a2: (A + 1) - (A - 1) * cosw - 2 * sqA * alpha)
        }
    }

    // MARK: - Free-form draw → bands fit

    /// Graphic-EQ-style band centers the drawn stroke is fitted to. Edges
    /// become shelves so the curve holds flat past them instead of
    /// returning to 0 dB.
    static let fitCenters: [Double] = [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 12_000, 16_000]
    /// Broad enough that adjacent fitted bands sum smoothly (≈ octave
    /// spacing) without turning the curve to mush.
    static let fitQ: Double = 1.1

    /// Fits a freehand stroke — (hz, dB) points in draw order, possibly
    /// noisy/backtracking — to parametric/shelf bands at `fitCenters`.
    /// Points are averaged into log-frequency bins first (so wiggles and
    /// re-draws over the same region blend), then each center samples the
    /// binned polyline by log-linear interpolation. Near-zero bands are
    /// dropped to keep the result hand-editable.
    static func fit(drawnCurve: [(hz: Double, db: Double)]) -> [EQBandSetting] {
        let points = drawnCurve.filter { $0.hz > 0 && $0.db.isFinite }
        guard !points.isEmpty else { return [] }

        // Bin by log-frequency, averaging dB per bin.
        let binCount = 48
        let logMin = log10(minFrequency)
        let logMax = log10(maxFrequency)
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        for point in points {
            let t = (log10(min(max(point.hz, minFrequency), maxFrequency)) - logMin) / (logMax - logMin)
            let bin = min(binCount - 1, max(0, Int(t * Double(binCount))))
            sums[bin] += min(max(point.db, -gainRange), gainRange)
            counts[bin] += 1
        }
        let binned: [(logHz: Double, db: Double)] = (0..<binCount).compactMap { i in
            guard counts[i] > 0 else { return nil }
            let logHz = logMin + (Double(i) + 0.5) / Double(binCount) * (logMax - logMin)
            return (logHz, sums[i] / Double(counts[i]))
        }
        guard let first = binned.first, let last = binned.last else { return [] }

        // Sample the binned polyline at each fit center (log-linear
        // interpolation; clamp to the endpoints outside the drawn range).
        func sample(atLogHz x: Double) -> Double {
            if x <= first.logHz { return first.db }
            if x >= last.logHz { return last.db }
            for i in 1..<binned.count where binned[i].logHz >= x {
                let (x0, y0) = binned[i - 1]
                let (x1, y1) = binned[i]
                let t = x1 > x0 ? (x - x0) / (x1 - x0) : 0
                return y0 + (y1 - y0) * t
            }
            return last.db
        }

        return fitCenters.enumerated().compactMap { i, hz in
            let gain = sample(atLogHz: log10(hz))
            guard abs(gain) >= 0.25 else { return nil } // skip ~flat bands
            let type: EQBandType = i == 0 ? .lowShelf
                : i == fitCenters.count - 1 ? .highShelf
                : .parametric
            return EQBandSetting(type: type, frequency: hz, gain: gain, q: fitQ)
        }
    }
}

/// A named band curve the user can apply and then tweak. Built-ins are
/// fixed starting points; custom presets are saved snapshots of the
/// current bands, persisted app-wide next to `EQSettings`. Only bands are
/// stored — enabled state stays with the session and the preamp is
/// recomputed automatically on apply.
nonisolated struct EQPreset: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var bands: [EQBandSetting]

    static let customDefaultsKey = "audioEQCustomPresets"

    static let builtIns: [EQPreset] = [
        EQPreset(name: "Flat", bands: []),
        EQPreset(name: "Bass Boost", bands: [
            EQBandSetting(type: .lowShelf, frequency: 120, gain: 5.5),
        ]),
        EQPreset(name: "Bass Reducer", bands: [
            EQBandSetting(type: .lowShelf, frequency: 120, gain: -5.5),
        ]),
        EQPreset(name: "Treble Boost", bands: [
            EQBandSetting(type: .highShelf, frequency: 6_000, gain: 4.5),
        ]),
        EQPreset(name: "Vocal", bands: [
            EQBandSetting(type: .lowShelf, frequency: 150, gain: -2.5),
            EQBandSetting(frequency: 2_500, gain: 4, q: 0.9),
            EQBandSetting(type: .highShelf, frequency: 10_000, gain: -1.5),
        ]),
        EQPreset(name: "Loudness", bands: [
            EQBandSetting(type: .lowShelf, frequency: 100, gain: 4.5),
            EQBandSetting(frequency: 1_800, gain: -2, q: 0.8),
            EQBandSetting(type: .highShelf, frequency: 8_000, gain: 4),
        ]),
    ]

    static func loadCustom(from defaults: UserDefaults = .standard) -> [EQPreset] {
        guard let data = defaults.data(forKey: customDefaultsKey),
              let presets = try? JSONDecoder().decode([EQPreset].self, from: data)
        else { return [] }
        return presets
    }

    static func saveCustom(_ presets: [EQPreset], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: customDefaultsKey)
    }
}
