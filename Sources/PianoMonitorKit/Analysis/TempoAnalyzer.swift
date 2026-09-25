import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// One detected beat relative to the fitted tempo grid.
public struct BeatEvent: Sendable, Equatable {
    /// Milliseconds since the first beat of the current analysis window.
    public let offsetMilliseconds: Double
    /// Deviation from the ideal grid position, in milliseconds. Positive = late.
    public let deviationMilliseconds: Double
    /// Click strength at the moment of detection (fast/slow envelope ratio).
    public let strength: Float
}

/// A complete tempo measurement. Immutable snapshot so it can be handed to the UI and the HTTP API
/// without locking.
public struct TempoSnapshot: Sendable, Equatable {
    /// Beats per minute, folded into the musically sensible 30…240 range.
    public let bpm: Double?
    /// BPM computed from the mean inter-beat interval (as opposed to the median).
    public let meanBPM: Double?
    public let minBPM: Double?
    public let maxBPM: Double?
    /// Standard deviation of the inter-beat intervals, in milliseconds.
    public let stabilityMilliseconds: Double?
    /// Standard deviation of the grid deviations, in milliseconds. This is the "±18 ms" figure.
    public let gridDeviationMilliseconds: Double?
    public let averageBeatIntervalMilliseconds: Double?
    /// Beats currently inside the analysis window.
    public let beatCount: Int
    /// Total beats measured since the analyzer was reset.
    public let totalBeatCount: Int
    /// Intervals discarded as octave errors (missed or doubled beats).
    public let outlierCount: Int
    /// The most recent beats, oldest first.
    public let beats: [BeatEvent]
    public let updatedAt: Date

    public static let empty = TempoSnapshot(
        bpm: nil, meanBPM: nil, minBPM: nil, maxBPM: nil,
        stabilityMilliseconds: nil, gridDeviationMilliseconds: nil,
        averageBeatIntervalMilliseconds: nil, beatCount: 0, totalBeatCount: 0,
        outlierCount: 0, beats: [], updatedAt: Date(timeIntervalSince1970: 0)
    )

    public var hasMeasurement: Bool { bpm != nil }
}

/// Measures the tempo of an external metronome by listening to it.
///
/// ```
/// Audio -> band-pass (click band) -> rectify -> fast/slow envelope
///       -> onset (fast/slow ratio) -> click gate (spectral, optional)
///       -> inter-onset intervals -> octave-error correction -> BPM + stability
/// ```
///
/// **Deliberately independent of `BasicPianoDetector`.** It shares no state and cannot influence
/// practice-time recording. The spec is explicit that a metronome must not become practice time
/// and that a failure here must not damage the session log, so both properties are structural
/// rather than best-effort.
///
/// **Click vs piano note.** A metronome click is a short broadband transient in the 2–6 kHz band
/// with no sustain; a piano note has a strong harmonic peak and rings for hundreds of
/// milliseconds. Two cues separate them:
/// 1. the band-pass keeps most piano fundamental energy out of the detector,
/// 2. the optional spectral gate rejects onsets whose spectrum is *tonal* (high peakiness) rather
///    than click-like.
/// If separation is imperfect, the analyzer reports what it heard and the session recorder keeps
/// running untouched.
public final class TempoAnalyzer {

    private var configuration: TempoConfiguration
    private var sampleRate: Double

    private var bandPass: Biquad
    /// Fast envelope: rises with the click and decays in a few milliseconds.
    private var fastEnvelope: Float = 0
    /// Fixed local noise reference. Using a *fixed* floor (rather than a second, slower envelope)
    /// is what makes onset detection unambiguous: a ratio against a rising baseline stays above the
    /// threshold for tens of hops after a single click, which would count one beat many times.
    private var floorEnvelope: Float = 0

    // Timing. Hops are fixed-length so timestamps stay exact regardless of block size.
    private var hopFrames: Int { max(16, Int(sampleRate * 0.001)) } // 1 ms
    private var hopCount = 0
    private var hopTime: Double = 0
    private var hopRemainder: [Float] = []
    private var leftover: [Float] = []

    private var beatTimes: [Double] = []
    private var beatStrengths: [Float] = []
    private var lastBeatTime: Double = -.greatestFiniteMagnitude
    private var intervals: [Double] = []
    /// 10^-60 in linear amplitude: below any real signal, above denormal noise.
    private static let floorMinimum: Float = 1e-3
    private var totalBeats = 0
    private var outlierCount = 0

    // Spectral click gate (optional, requires an FFT).
    private var fft: FFTProcessor?
    private var frameAssembler: FrameAssembler
    private var latestProminence: Float = 0
    private var latestCentroid: Float = 0
    private var blockCounter = 0

    /// Set by the UI when the user knows what tempo they dialled in, so the app can report error.
    public var targetBPM: Double?

    public init(configuration: TempoConfiguration, sampleRate: Double) {
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.bandPass = Biquad.bandPass(
            centerHz: configuration.bandpassCenterHz,
            bandwidthHz: configuration.bandpassBandwidthHz,
            sampleRate: sampleRate
        )
        self.frameAssembler = FrameAssembler(size: 1024)
    }

    public func update(configuration: TempoConfiguration, targetBPM: Double?) {
        self.targetBPM = targetBPM
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        self.bandPass = Biquad.bandPass(
            centerHz: configuration.bandpassCenterHz,
            bandwidthHz: configuration.bandpassBandwidthHz,
            sampleRate: sampleRate
        )
        reset()
    }

    public func update(sampleRate: Double) {
        guard sampleRate > 0, sampleRate != self.sampleRate else { return }
        self.sampleRate = sampleRate
        self.bandPass = Biquad.bandPass(
            centerHz: configuration.bandpassCenterHz,
            bandwidthHz: configuration.bandpassBandwidthHz,
            sampleRate: sampleRate
        )
        reset()
    }

    /// Clears measurements but keeps configuration. Used when capture restarts.
    public func reset() {
        fastEnvelope = 0
        floorEnvelope = 0
        hopCount = 0
        hopTime = 0
        hopRemainder.removeAll(keepingCapacity: true)
        leftover.removeAll(keepingCapacity: true)
        beatTimes.removeAll(keepingCapacity: true)
        beatStrengths.removeAll(keepingCapacity: true)
        intervals.removeAll(keepingCapacity: true)
        lastBeatTime = -.greatestFiniteMagnitude
        totalBeats = 0
        outlierCount = 0
        latestProminence = 0
        latestCentroid = 0
        blockCounter = 0
        bandPass.reset()
    }

    // MARK: - Processing

    /// Feeds one audio block. Returns `true` when a beat was detected in this block.
    @discardableResult
    public func process(frame: ProcessedAudioFrame) -> Bool {
        let config = configuration
        var samples = frame.samples
        guard !samples.isEmpty else { return false }

        bandPass.process(&samples, count: samples.count)
        updateSpectralGate(samples: frame.samples)

        // Envelope constants are expressed in seconds, converted per sample.
        let attack = Float(1 - exp(-1.0 / max(1, config.envelopeAttackSeconds * sampleRate)))
        let release = Float(1 - exp(-1.0 / max(1, config.envelopeReleaseSeconds * sampleRate)))
        // How quickly the local floor is allowed to creep up toward the recent peak. Slow enough
        // that a 12 ms click barely moves it, so the next click is still a clear rise above it.
        let floorAdapt = Float(1 - exp(-1.0 / max(1, config.floorAdaptSeconds * sampleRate)))

        let hop = hopFrames
        var detected = false
        var index = 0

        while index < samples.count {
            let take = min(hop - leftover.count, samples.count - index)
            if take > 0 {
                leftover.append(contentsOf: samples[index..<(index + take)])
                index += take
            } else {
                break
            }
            guard leftover.count == hop else { break }

            for sample in leftover {
                let rectified = abs(sample)
                fastEnvelope += (rectified - fastEnvelope) * (rectified > fastEnvelope ? attack : release)
                // The floor only follows the peak upward, and slowly.
                if fastEnvelope > floorEnvelope {
                    floorEnvelope += (fastEnvelope - floorEnvelope) * floorAdapt
                }
            }
            leftover.removeAll(keepingCapacity: true)
            hopCount += 1
            hopTime = Double(hopCount) * Double(hop) / sampleRate

            if detectBeat(at: hopTime, config: config) { detected = true }
        }
        return detected
    }

    private func detectBeat(at time: Double, config: TempoConfiguration) -> Bool {
        // A beat is a *sudden* rise above the local floor — the defining property of a click.
        // `floorMinimum` keeps the ratio meaningful in digital silence, where the floor would
        // otherwise sit at zero and any noise spike would look like a beat.
        let reference = max(floorEnvelope, Self.floorMinimum)
        let ratio = fastEnvelope / reference
        guard ratio >= config.onsetRatio else { return false }
        guard time - lastBeatTime >= config.minBeatIntervalSeconds else { return false }
        guard time - lastBeatTime <= config.maxBeatIntervalSeconds || lastBeatTime < 0 else {
            // A gap longer than the slowest supported tempo: treat it as a fresh start rather than
            // inventing a bogus interval.
            lastBeatTime = time
            beatTimes.append(time)
            beatStrengths.append(ratio)
            totalBeats += 1
            return true
        }

        // Optional spectral gate: reject onsets whose spectrum looks *tonal* (a piano note) rather
        // than click-like. A piano note fills the band-pass band with a strong harmonic peak, so a
        // very high prominence means we are probably hearing the instrument, not the metronome.
        // The piano's fundamental is largely removed by the band-pass, so this only fires on the
        // instrument's high harmonics, which is exactly the ambiguous case worth guarding.
        if config.useSpectralClickGate, fft != nil {
            let tonal = latestProminence > config.tonalProminenceCeiling
                && latestCentroid < Float(config.bandpassCenterHz)
            if tonal {
                Log.verbose(Log.analyzer, "tempo: rejected tonal onset (prominence=\(self.latestProminence) centroid=\(self.latestCentroid))")
                return false
            }
        }

        if lastBeatTime > 0 {
            let interval = time - lastBeatTime
            appendInterval(interval)
        }
        lastBeatTime = time
        beatTimes.append(time)
        beatStrengths.append(ratio)
        totalBeats += 1
        // Keep the window bounded: enough beats for stable statistics, not unbounded growth.
        let keep = max(config.historyCount * 4, 64)
        if beatTimes.count > keep {
            beatTimes.removeFirst(beatTimes.count - keep)
            beatStrengths.removeFirst(beatStrengths.count - keep)
        }
        return true
    }

    /// Stores an interval after octave-error correction: a missed click doubles the interval and a
    /// spurious one halves it, so both are folded back onto the median.
    private func appendInterval(_ interval: Double) {
        guard interval >= configuration.minBeatIntervalSeconds,
              interval <= configuration.maxBeatIntervalSeconds else {
            outlierCount += 1
            return
        }
        guard let median = medianInterval(), median > 0 else {
            intervals.append(interval)
            return
        }
        let ratios: [Double] = [1.0, 2.0, 0.5, 3.0, 1.0 / 3.0]
        var bestRatio = 1.0
        var bestError = Double.greatestFiniteMagnitude
        for ratio in ratios {
            let candidate = interval / ratio
            let error = abs(candidate - median) / median
            if error < bestError {
                bestError = error
                bestRatio = ratio
            }
        }
        if bestRatio != 1.0, bestError < configuration.outlierTolerance {
            outlierCount += 1
            intervals.append(interval / bestRatio)
            Log.verbose(Log.analyzer, "tempo: folded interval \(interval)s by \(bestRatio)x")
        } else {
            intervals.append(interval)
        }
        if intervals.count > configuration.historyCount {
            intervals.removeFirst(intervals.count - configuration.historyCount)
        }
    }

    private func medianInterval() -> Double? {
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private func updateSpectralGate(samples: [Float]) {
        let config = configuration
        guard config.useSpectralClickGate else { return }
        blockCounter += 1
        guard blockCounter % 4 == 0 else { return }
        if fft?.size != 1024 {
            fft = FFTProcessor(size: 1024, sampleRate: sampleRate)
            frameAssembler = FrameAssembler(size: 1024)
        }
        guard let fft else { return }
        frameAssembler.append(samples)
        guard frameAssembler.isFull else { return }
        frameAssembler.withFrame { pointer, available in
            let magnitudes = fft.magnitudes(of: pointer, count: available)
            latestProminence = DSP.spectralPeakProminence(magnitudes: magnitudes)
            latestCentroid = DSP.spectralCentroid(magnitudes: magnitudes, binWidth: fft.binWidth)
        }
    }

    // MARK: - Snapshot

    /// Current measurement. Cheap enough to call from the UI at its throttled refresh rate.
    public func snapshot() -> TempoSnapshot {
        guard intervals.count >= 2, let median = medianInterval(), median > 0 else {
            return TempoSnapshot(
                bpm: nil, meanBPM: nil, minBPM: nil, maxBPM: nil,
                stabilityMilliseconds: nil, gridDeviationMilliseconds: nil,
                averageBeatIntervalMilliseconds: nil,
                beatCount: beatTimes.count, totalBeatCount: totalBeats,
                outlierCount: outlierCount, beats: beatEvents(), updatedAt: Date()
            )
        }

        let mean = intervals.reduce(0, +) / Double(intervals.count)
        // Fold into a musically plausible range: a metronome set to 40 BPM can otherwise be read
        // as 80 if every other click is missed.
        let fold = foldFactor(for: mean)
        let bpm = 60.0 / (mean * fold)
        let minBPM = 60.0 / ((intervals.max() ?? mean) * fold)
        let maxBPM = 60.0 / ((intervals.min() ?? mean) * fold)

        let variance = intervals.reduce(0) { $0 + pow($1 - mean, 2) } / Double(intervals.count)
        let stabilityMs = variance.squareRoot() * 1000

        let events = beatEvents()
        let deviations = events.map(\.deviationMilliseconds)
        let gridDeviation: Double? = deviations.isEmpty ? nil : {
            let meanDeviation = deviations.reduce(0, +) / Double(deviations.count)
            let devVariance = deviations.reduce(0) { $0 + pow($1 - meanDeviation, 2) } / Double(deviations.count)
            return devVariance.squareRoot()
        }()

        return TempoSnapshot(
            bpm: bpm,
            meanBPM: bpm,
            minBPM: minBPM,
            maxBPM: maxBPM,
            stabilityMilliseconds: stabilityMs,
            gridDeviationMilliseconds: gridDeviation,
            averageBeatIntervalMilliseconds: mean * 1000,
            beatCount: beatTimes.count,
            totalBeatCount: totalBeats,
            outlierCount: outlierCount,
            beats: events,
            updatedAt: Date()
        )
    }

    /// Chooses the power-of-two-ish factor that brings the average interval into 30…240 BPM.
    private func foldFactor(for mean: Double) -> Double {
        var factor = 1.0
        var candidate = 60.0 / mean
        while candidate < 30, factor < 8 { factor *= 2; candidate = 60.0 / (mean * factor) }
        while candidate > 240, factor > 0.125 { factor /= 2; candidate = 60.0 / (mean * factor) }
        return factor
    }

    /// Maps beats onto the fitted grid so the UI can show `Beat #1 +0 ms, Beat #2 +12 ms, …`.
    private func beatEvents() -> [BeatEvent] {
        guard let median = medianInterval(), beatTimes.count >= 2 else { return [] }
        let fold = foldFactor(for: median)
        let gridInterval = median * fold
        let origin = beatTimes[0]
        var events: [BeatEvent] = []
        for (index, time) in beatTimes.enumerated() {
            let offset = time - origin
            let ideal = (offset / gridInterval).rounded() * gridInterval
            events.append(BeatEvent(
                offsetMilliseconds: offset * 1000,
                deviationMilliseconds: (offset - ideal) * 1000,
                strength: index < beatStrengths.count ? beatStrengths[index] : 0
            ))
        }
        return events
    }

    /// Difference between measured and dialled-in tempo, for the "Set: 100 / Actual: 99.2" readout.
    public func errorPercent(for snapshot: TempoSnapshot) -> Double? {
        guard let target = targetBPM, target > 0, let bpm = snapshot.bpm else { return nil }
        return (bpm - target) / target * 100
    }
}

#endif
