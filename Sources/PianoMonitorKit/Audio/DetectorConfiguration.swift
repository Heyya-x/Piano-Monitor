import AVFoundation
import Foundation

#if os(macOS)

/// Every tunable in the detection/analysis pipeline lives here.
///
/// Nothing is hard-coded in multiple places: detectors read their thresholds from a
/// `DetectorConfiguration` value that is pushed in from persisted `AppSettings`.
public struct DetectorConfiguration: Codable, Equatable, Sendable {
    // MARK: Frame / buffering

    /// Frames per mono analysis frame handed to detectors. 1024 @ 44.1k ≈ 23 ms.
    public var analysisFrameSize: Int
    /// Analysis frames per second is derived, but we assert a sane relationship in `validate()`.
    public var expectedSampleRate: Double

    // MARK: Level gates

    /// Signal must exceed the estimated noise floor by this many dB to count as "something happened".
    public var noiseFloorMarginDB: Float
    /// Absolute RMS gate in dBFS. Below this, nothing is considered playing regardless of
    /// how quiet the room's noise floor estimate is.
    public var absoluteRMSFloorDB: Float
    /// Absolute peak gate in dBFS, protects against a single sample click.
    public var absolutePeakFloorDB: Float

    // MARK: Noise floor estimator

    /// Time constant (seconds) for the noise floor tracker while the room is **quieter** than the
    /// floor. Fast, because the room becoming quiet is unambiguous.
    public var noiseFloorAttackSeconds: Double
    /// Time constant (seconds) for noise floor adaptation while playing (must be much slower,
    /// otherwise sustained piano tone drags the floor up and detection collapses).
    public var noiseFloorReleaseSeconds: Double
    /// Time constant (seconds) for the noise floor rising toward a **louder** steady room.
    /// Slow enough that a sustained chord cannot lift it, quick enough that the detector recovers
    /// when a fan or a humidifier starts up. Without this the floor could only ever fall, and a
    /// detector started in a silent room would go deaf in a noisy one.
    public var noiseFloorRiseSeconds: Double
    /// Hard clamp so a very loud practice session does not permanently deafen the detector.
    public var noiseFloorMaxDB: Float

    // MARK: Onset / attack

    /// Positive RMS jump (dB over the short-term average) that qualifies as an attack.
    public var onsetThresholdDB: Float
    /// Minimum gap between two counted onsets; prevents one note registering twice.
    public var onsetDebounceSeconds: Double
    /// How many onsets inside `onsetWindowSeconds` are enough to call it "piano playing"
    /// rather than a chair creak or a single cough.
    public var onsetsForPlaying: Int
    public var onsetWindowSeconds: Double

    // MARK: Spectral cues (optional, skipped entirely in `.eco`)

    /// Normalised autocorrelation threshold above which a frame counts as *tonal*.
    ///
    /// Measured on synthetic signals: a harmonic piano note scores ≈0.9999; room noise, a metronome
    /// click and speech fricatives all sit near 0.20. Human speech is the hard case — a sustained
    /// vowel is genuinely periodic, reaching 0.9+ on the frames where it is voiced, which is why
    /// `minimumTonalConfidence` exists as a second line of defence.
    public var tonalPeriodicityThreshold: Float
    /// The highest confidence a frame may reach on time-domain evidence alone, even when it is
    /// clearly periodic. Voiced speech is periodic and sustained, so without this ceiling it could
    /// reach full confidence; with it, unambiguous piano remains the only way to score 1.0.
    public var minimumTonalConfidence: Float

    // MARK: Hysteresis / confirmation

    /// Piano likelihood (0…1) needed to enter `playing`.
    public var enterPlayingConfidence: Float
    /// Piano likelihood below which we leave `playing` (must be < enter threshold).
    public var exitPlayingConfidence: Float
    /// Continuous "piano-ish" time required before `idle -> playing`.
    public var confirmPlayingSeconds: Double
    /// Continuous silence required before `playing -> pause`. The user asked for 5–10 s so that
    /// thinking between phrases does not fragment a session.
    public var pauseAfterSilenceSeconds: Double
    /// Continuous silence required before `pause -> idle` (session is closed). 2–5 minutes.
    public var endSessionAfterSilenceSeconds: Double
    /// How much of the session must be active before it is worth persisting at all.
    public var minimumSessionActiveSeconds: Double

    // MARK: Tempo

    public var tempo: TempoConfiguration

    // MARK: Defaults

    public static let `default` = DetectorConfiguration(
        analysisFrameSize: 1024,
        expectedSampleRate: 44_100,
        noiseFloorMarginDB: 9,
        absoluteRMSFloorDB: -58,
        absolutePeakFloorDB: -42,
        noiseFloorAttackSeconds: 0.75,
        noiseFloorReleaseSeconds: 30,
        noiseFloorRiseSeconds: 12,
        noiseFloorMaxDB: -34,
        onsetThresholdDB: 5.5,
        onsetDebounceSeconds: 0.075,
        onsetsForPlaying: 3,
        onsetWindowSeconds: 1.2,
        tonalPeriodicityThreshold: 0.5,
        minimumTonalConfidence: 0.8,
        enterPlayingConfidence: 0.55,
        exitPlayingConfidence: 0.3,
        confirmPlayingSeconds: 0.8,
        pauseAfterSilenceSeconds: 8,
        endSessionAfterSilenceSeconds: 180,
        minimumSessionActiveSeconds: 20,
        tempo: .default
    )

    public init(
        analysisFrameSize: Int,
        expectedSampleRate: Double,
        noiseFloorMarginDB: Float,
        absoluteRMSFloorDB: Float,
        absolutePeakFloorDB: Float,
        noiseFloorAttackSeconds: Double,
        noiseFloorReleaseSeconds: Double,
        noiseFloorRiseSeconds: Double,
        noiseFloorMaxDB: Float,
        onsetThresholdDB: Float,
        onsetDebounceSeconds: Double,
        onsetsForPlaying: Int,
        onsetWindowSeconds: Double,
        tonalPeriodicityThreshold: Float,
        minimumTonalConfidence: Float,
        enterPlayingConfidence: Float,
        exitPlayingConfidence: Float,
        confirmPlayingSeconds: Double,
        pauseAfterSilenceSeconds: Double,
        endSessionAfterSilenceSeconds: Double,
        minimumSessionActiveSeconds: Double,
        tempo: TempoConfiguration
    ) {
        self.analysisFrameSize = analysisFrameSize
        self.expectedSampleRate = expectedSampleRate
        self.noiseFloorMarginDB = noiseFloorMarginDB
        self.absoluteRMSFloorDB = absoluteRMSFloorDB
        self.absolutePeakFloorDB = absolutePeakFloorDB
        self.noiseFloorAttackSeconds = noiseFloorAttackSeconds
        self.noiseFloorReleaseSeconds = noiseFloorReleaseSeconds
        self.noiseFloorRiseSeconds = noiseFloorRiseSeconds
        self.noiseFloorMaxDB = noiseFloorMaxDB
        self.onsetThresholdDB = onsetThresholdDB
        self.onsetDebounceSeconds = onsetDebounceSeconds
        self.onsetsForPlaying = onsetsForPlaying
        self.onsetWindowSeconds = onsetWindowSeconds
        self.tonalPeriodicityThreshold = tonalPeriodicityThreshold
        self.minimumTonalConfidence = minimumTonalConfidence
        self.enterPlayingConfidence = enterPlayingConfidence
        self.exitPlayingConfidence = exitPlayingConfidence
        self.confirmPlayingSeconds = confirmPlayingSeconds
        self.pauseAfterSilenceSeconds = pauseAfterSilenceSeconds
        self.endSessionAfterSilenceSeconds = endSessionAfterSilenceSeconds
        self.minimumSessionActiveSeconds = minimumSessionActiveSeconds
        self.tempo = tempo
    }

    /// Sensitivity is the one knob exposed prominently in the UI; it maps onto the gates.
    /// 0.0 = only very obvious playing is detected, 1.0 = very sensitive.
    public var sensitivity: Float {
        get {
            // Map absoluteRMSFloorDB (-70…-40) onto 0…1.
            let normalised = (absoluteRMSFloorDB + 70) / 30
            return min(max(normalised, 0), 1)
        }
        set {
            let clamped = min(max(newValue, 0), 1)
            absoluteRMSFloorDB = -70 + clamped * 30
            absolutePeakFloorDB = absoluteRMSFloorDB + 16
            // More sensitive also lowers the onset bar slightly.
            onsetThresholdDB = 7.5 - clamped * 4.0
        }
    }

    /// Returns human-readable problems, empty when consistent. Used by tests and Settings UI.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        if analysisFrameSize < 64 || analysisFrameSize > 8192 || analysisFrameSize & (analysisFrameSize - 1) != 0 {
            issues.append("analysisFrameSize must be a power of two between 64 and 8192")
        }
        if exitPlayingConfidence >= enterPlayingConfidence {
            issues.append("exitPlayingConfidence must be lower than enterPlayingConfidence (hysteresis)")
        }
        if pauseAfterSilenceSeconds >= endSessionAfterSilenceSeconds {
            issues.append("pauseAfterSilenceSeconds must be shorter than endSessionAfterSilenceSeconds")
        }
        if minimumSessionActiveSeconds <= 0 {
            issues.append("minimumSessionActiveSeconds must be positive")
        }
        if absoluteRMSFloorDB >= absolutePeakFloorDB {
            issues.append("absoluteRMSFloorDB must be below absolutePeakFloorDB")
        }
        return issues
    }
}

/// Tempo analyzer tunables. Deliberately separate from `DetectorConfiguration`'s piano gates —
/// the two analyzers must never share state or failure modes.
public struct TempoConfiguration: Codable, Equatable, Sendable {
    /// Band-pass centre frequency for click enhancement. A TOP1-style metronome click has most
    /// of its energy well above the fundamental of the low piano register.
    public var bandpassCenterHz: Double
    public var bandpassBandwidthHz: Double

    /// Envelope follower times (seconds).
    public var envelopeAttackSeconds: Double
    public var envelopeReleaseSeconds: Double
    /// Time constant for the local noise floor creeping up toward recent peaks. Must be much slower
    /// than a click (12 ms) so the next click is still a clear rise above the floor.
    public var floorAdaptSeconds: Double

    /// Onset must exceed the local envelope average by this ratio to count as a click.
    public var onsetRatio: Float
    /// Minimum interval between beats. 0.25 s caps reported tempo at 240 BPM.
    public var minBeatIntervalSeconds: Double
    /// Maximum interval between beats. 2.0 s floors reported tempo at 30 BPM.
    public var maxBeatIntervalSeconds: Double

    /// How many intervals feed the average/min/max/stability statistics.
    public var historyCount: Int
    /// Beats outside this fraction of the median interval are treated as missed/extra and dropped.
    public var outlierTolerance: Double

    /// When true the analyzer additionally requires the click's spectral signature, which
    /// suppresses piano note attacks. Requires FFT, therefore only in `.analysis` mode.
    public var useSpectralClickGate: Bool
    /// Onsets whose spectral peak prominence exceeds this are treated as tonal (a piano note)
    /// rather than as metronome clicks. A pure click is broadband, so its prominence stays low.
    public var tonalProminenceCeiling: Float

    public static let `default` = TempoConfiguration(
        bandpassCenterHz: 2_800,
        bandpassBandwidthHz: 2_000,
        envelopeAttackSeconds: 0.0005,
        envelopeReleaseSeconds: 0.030,
        floorAdaptSeconds: 0.4,
        onsetRatio: 1.9,
        minBeatIntervalSeconds: 0.25,
        maxBeatIntervalSeconds: 2.0,
        historyCount: 16,
        outlierTolerance: 0.25,
        useSpectralClickGate: true,
        tonalProminenceCeiling: 60
    )

    public init(
        bandpassCenterHz: Double,
        bandpassBandwidthHz: Double,
        envelopeAttackSeconds: Double,
        envelopeReleaseSeconds: Double,
        floorAdaptSeconds: Double,
        onsetRatio: Float,
        minBeatIntervalSeconds: Double,
        maxBeatIntervalSeconds: Double,
        historyCount: Int,
        outlierTolerance: Double,
        useSpectralClickGate: Bool,
        tonalProminenceCeiling: Float
    ) {
        self.bandpassCenterHz = bandpassCenterHz
        self.bandpassBandwidthHz = bandpassBandwidthHz
        self.envelopeAttackSeconds = envelopeAttackSeconds
        self.envelopeReleaseSeconds = envelopeReleaseSeconds
        self.floorAdaptSeconds = floorAdaptSeconds
        self.onsetRatio = onsetRatio
        self.minBeatIntervalSeconds = minBeatIntervalSeconds
        self.maxBeatIntervalSeconds = maxBeatIntervalSeconds
        self.historyCount = historyCount
        self.outlierTolerance = outlierTolerance
        self.useSpectralClickGate = useSpectralClickGate
        self.tonalProminenceCeiling = tonalProminenceCeiling
    }
}

/// Measured latency of the capture/monitor path.
///
/// Reported honestly rather than assumed: the requested buffer size is not always the achieved one
/// (devices clamp it), and the buffer is only part of the story — the driver latency and the HAL
/// safety offset each contribute, and on this machine the output safety offset alone was 48 frames.
public struct LatencyReport: Sendable, Equatable {
    public var profile: LatencyProfile = .minimal
    public var inputDeviceName: String?
    public var outputDeviceName: String?
    public var inputBufferFrames: Int?
    public var outputBufferFrames: Int?
    public var inputBufferMilliseconds: Double?
    public var outputBufferMilliseconds: Double?
    /// Device-reported latency plus safety offset, in milliseconds, for each direction.
    public var inputDeviceMilliseconds: Double?
    public var outputDeviceMilliseconds: Double?
    /// What the engine itself reports for its IO nodes, when available. This is the most trustworthy
    /// figure because it comes from the running audio unit rather than from a calculation.
    public var inputPresentationMilliseconds: Double?
    public var outputPresentationMilliseconds: Double?
    /// Adjusted for any buffer change that needed an engine restart.
    public var notes: [String] = []

    /// Sum of the measurable parts of the round trip: what the player actually hears.
    public var estimatedRoundTripMilliseconds: Double? {
        if let inputPresentationMilliseconds, let outputPresentationMilliseconds {
            return (inputPresentationMilliseconds + outputPresentationMilliseconds) * 1_000
        }
        guard let input = inputBufferMilliseconds, let output = outputBufferMilliseconds else { return nil }
        return input + output + (inputDeviceMilliseconds ?? 0) + (outputDeviceMilliseconds ?? 0)
    }

    public var summary: String {
        guard let roundTrip = estimatedRoundTripMilliseconds else { return "not measured" }
        let input = inputBufferFrames.map(String.init) ?? "?"
        let output = outputBufferFrames.map(String.init) ?? "?"
        return String(format: "≈%.1f ms round trip (buffers %@/%@ frames)", roundTrip, input, output)
    }
}


#endif
