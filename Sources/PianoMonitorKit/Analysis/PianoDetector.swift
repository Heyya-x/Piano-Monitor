import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// Per-frame output of a piano activity detector.
///
/// Deliberately small and value-typed: it crosses from the audio analysis path into the session
/// recorder and (throttled) into the UI.
public struct DetectionResult: Sendable {
    public let isPlaying: Bool
    public let confidence: Float
    public let onset: Bool
    public let rms: Float
    public let rmsDB: Float
    public let peakDB: Float
    public let noiseFloorDB: Float
    /// Timestamp of the audio this result describes (seconds, monotonic).
    public let timestamp: Double
    public let features: DetectionFeatures

    public init(
        isPlaying: Bool,
        confidence: Float,
        onset: Bool,
        rms: Float,
        rmsDB: Float,
        peakDB: Float,
        noiseFloorDB: Float,
        timestamp: Double,
        features: DetectionFeatures
    ) {
        self.isPlaying = isPlaying
        self.confidence = confidence
        self.onset = onset
        self.rms = rms
        self.rmsDB = rmsDB
        self.peakDB = peakDB
        self.noiseFloorDB = noiseFloorDB
        self.timestamp = timestamp
        self.features = features
    }
}

/// Extra per-frame cues. Kept as a concrete struct so swapping in an ML detector later only means
/// producing this same shape.
public struct DetectionFeatures: Sendable {
    public let spectralCentroidHz: Float
    public let spectralFlux: Float
    /// Normalised autocorrelation peak (0…1). High = periodic/tonal (piano), low = noisy.
    public let periodicity: Float
    /// Fraction of the last 300 ms that was above the activity gate (0…1).
    public let sustain: Float
    /// Onsets counted inside the configured window.
    public let onsetCount: Int

    public init(
        spectralCentroidHz: Float = 0,
        spectralFlux: Float = 0,
        periodicity: Float = 0,
        sustain: Float = 0,
        onsetCount: Int = 0
    ) {
        self.spectralCentroidHz = spectralCentroidHz
        self.spectralFlux = spectralFlux
        self.periodicity = periodicity
        self.sustain = sustain
        self.onsetCount = onsetCount
    }
}

/// The swap point for detection strategies.
///
/// The MVP ships `BasicPianoDetector` (RMS + noise floor + attack + optional spectral cues).
/// A future `MLPianoDetector` or a MIDI-fused detector conforms to this same protocol, so the
/// session recorder and UI never need to change.
public protocol PianoActivityDetector: AnyObject {
    /// Processes one block of mono PCM. Implementations must not allocate unboundedly and must not
    /// touch the UI or block.
    func process(frame: ProcessedAudioFrame) -> DetectionResult

    /// Drops adaptive state. Called when the audio device changes, because the old noise floor and
    /// running averages describe hardware that is no longer connected.
    func reset()

    /// Human-readable description for the Settings/Diagnostics UI.
    var name: String { get }
}

/// Hermite smoothstep, clamped. Used to turn a raw feature into a 0…1 score without a hard cliff.
@inline(__always)
func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
    guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
    let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// MVP detector: cheap time-domain gating plus optional spectral confirmation.
///
/// Pipeline, in the order the spec requires:
/// ```
/// PCM -> rumble filter -> block RMS/peak -> noise floor
///                     -> hop envelope (2 ms) -> attack detection -> onset times
///                     -> sustain evidence
///                     -> spectral cues (only when the profile enables them)
///                     -> confidence -> playing
/// ```
///
/// **Why a hop envelope:** attack timing drives the session recorder's responsiveness, so onset
/// candidates are computed on ~2 ms hops rather than on the ~23 ms audio blocks. That keeps onset
/// jitter at a few milliseconds instead of ±20 ms, while still doing only one FFT per few blocks.
///
/// Everything is O(n) with `n` a few thousand samples. In `.eco` mode no FFT is ever constructed,
/// so the background cost is a handful of multiply-adds per sample.
public final class BasicPianoDetector: PianoActivityDetector {

    public let name = "Basic (RMS + noise floor + attack)"

    // Tuning
    private var configuration: DetectorConfiguration
    private var sampleRate: Double

    /// Envelope hop length: ~2 ms. Short enough for accurate onsets, long enough to stay cheap.
    private var hopFrames: Int { max(16, Int(sampleRate * 0.002)) }

    // Filters
    private var highPass: Biquad

    // Loudness / noise floor
    private var noiseFloorDB: Float = -70
    private var shortTermRMSDB: Float = -70
    private var shortTermInitialised = false

    // Hop envelope history (circular). 0.4 s at 2 ms hops is 200 entries; 256 gives headroom.
    private var envelopeDB: [Float]
    private var envelopeIndex = 0
    private var envelopeFilled = 0
    /// Monotonic hop clock, advanced by exactly `hopFrames / sampleRate` per hop so onset timing
    /// does not jitter with the audio block size.
    private var hopTime: Double = 0
    private var hopRemainder: [Float] = []

    // Onset bookkeeping
    private var lastOnsetTime: Double = -.greatestFiniteMagnitude
    private var onsetTimes: [Double] = []

    // Activity flags per hop, used for the sustain ratio.
    private var activeHops: [Bool]
    private var activeIndex = 0
    private var activeFilled = 0

    /// Window used for tonality. 2048 samples ≈ 46 ms, enough for two periods of a 55 Hz note.
    private var tonalAssembler: FrameAssembler
    private var blockCounter = 0
    /// True once at least one tonal evaluation has happened. Until then the detector has no basis
    /// for a confident verdict and confidence stays capped.
    private var hasTonalEvidence = false

    /// Blocks observed since `reset()`. The noise floor needs a short warm-up: if capture starts
    /// while the user is already playing, anchoring the floor to that first block would set it near
    /// the music's own level and make the detector insensitively loud for the rest of the session.
    private var warmupBlocks = 0
    private var warmupMinimumDB: Float = .greatestFiniteMagnitude
    private var hasWarmupMinimum = false
    private static let warmupBlockCount = 8

    public init(configuration: DetectorConfiguration, sampleRate: Double) {
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.highPass = Biquad.highPass(cutoffHz: 120, sampleRate: sampleRate, q: 0.707)
        self.envelopeDB = [Float](repeating: -120, count: 256)
        self.activeHops = [Bool](repeating: false, count: 256)
        self.tonalAssembler = FrameAssembler(size: 2_048)
    }

    public func update(configuration: DetectorConfiguration) {
        self.configuration = configuration
    }

    public func update(sampleRate: Double) {
        guard sampleRate > 0, sampleRate != self.sampleRate else { return }
        self.sampleRate = sampleRate
        self.highPass = Biquad.highPass(cutoffHz: 120, sampleRate: sampleRate, q: 0.707)
        reset()
    }

    public func reset() {
        noiseFloorDB = -70
        shortTermRMSDB = -70
        shortTermInitialised = false
        for index in 0..<envelopeDB.count { envelopeDB[index] = -120 }
        envelopeIndex = 0
        envelopeFilled = 0
        for index in 0..<activeHops.count { activeHops[index] = false }
        activeIndex = 0
        activeFilled = 0
        lastOnsetTime = -.greatestFiniteMagnitude
        onsetTimes.removeAll(keepingCapacity: true)
        hopTime = 0
        hopRemainder.removeAll(keepingCapacity: true)
        highPass.reset()
        blockCounter = 0
        hasTonalEvidence = false
        tonalAssembler = FrameAssembler(size: 2_048)
        capturedPeriodicities.removeAll(keepingCapacity: true)
        warmupBlocks = 0
        warmupMinimumDB = .greatestFiniteMagnitude
        hasWarmupMinimum = false
    }

    // MARK: - Processing

    public func process(frame: ProcessedAudioFrame) -> DetectionResult {
        let config = configuration

        // 1. Remove HVAC/floor rumble so the RMS gate and spectral centroid are not polluted.
        var samples = frame.samples
        if samples.count > 1 {
            highPass.process(&samples, count: samples.count)
        }

        let blockRMS = DSP.rms(samples)
        let blockPeak = DSP.peak(samples)
        let blockRMSDB = DSP.decibels(blockRMS)
        let blockPeakDB = DSP.decibels(blockPeak)

        updateNoiseFloor(blockRMSDB: blockRMSDB, config: config)
        updateShortTerm(blockRMSDB)

        // 2. Walk the block in ~2 ms hops, updating the envelope and looking for attacks.
        var sawOnset = false
        var sampleIndex = 0
        let hop = hopFrames
        while sampleIndex < samples.count {
            // Carry partial hops across block boundaries so hop timing is block-size independent.
            let take = min(hop - hopRemainder.count, samples.count - sampleIndex)
            if take > 0 {
                hopRemainder.append(contentsOf: samples[sampleIndex..<(sampleIndex + take)])
                sampleIndex += take
            } else {
                break
            }
            guard hopRemainder.count == hop else { break }

            let hopRMS = DSP.rms(hopRemainder)
            let hopDB = DSP.decibels(hopRMS)
            hopRemainder.removeAll(keepingCapacity: true)

            hopTime += Double(hop) / sampleRate
            let active = hopDB > config.absoluteRMSFloorDB && hopDB - noiseFloorDB > config.noiseFloorMarginDB
            pushHop(levelDB: hopDB, active: active)
            if detectOnset(levelDB: hopDB, timestamp: hopTime, active: active, config: config) {
                sawOnset = true
            }
        }

        // 3. Evidence aggregation.
        let sustain = sustainRatio()
        let energyGate = blockRMSDB > config.absoluteRMSFloorDB
            && blockPeakDB > config.absolutePeakFloorDB
            && blockRMSDB - noiseFloorDB > config.noiseFloorMarginDB

        // 4. Tonal confirmation.
        //
        // This is the cue that separates piano from everything that is merely *loud*: a metronome
        // click, a chair scrape, a door, a spoken syllable. It runs in the time domain by normalised
        // autocorrelation, so it also protects `.eco` mode, which never runs an FFT.
        var features = DetectionFeatures(sustain: sustain, onsetCount: onsetTimes.count)
        // `nil` means "this block has not been tonally evaluated yet".
        var tonalScore: Float?
        let evaluatesTonality = shouldEvaluateTonality()
        if evaluatesTonality, let periodicity = computePeriodicity(samples: samples) {
            features = DetectionFeatures(
                spectralCentroidHz: features.spectralCentroidHz,
                spectralFlux: features.spectralFlux,
                periodicity: periodicity,
                sustain: sustain,
                onsetCount: onsetTimes.count
            )
            tonalScore = smoothstep(
                config.tonalPeriodicityThreshold,
                max(config.tonalPeriodicityThreshold + 0.15, 0.85),
                periodicity
            )
            hasTonalEvidence = true
            capturedPeriodicities.append(periodicity)
        }

        // 5. Confidence.
        //
        // Time-domain evidence alone (loudness + sustain) is enough to *consider* piano but never to
        // be certain of it, so it is capped at `minimumTonalConfidence`. This is what stops a
        // sustained vowel or a noisy room from saturating the scale.
        let energyScore: Float = energyGate
            ? min(1, (blockRMSDB - noiseFloorDB - config.noiseFloorMarginDB) / 18 + 0.5)
            : 0
        let sustainScore: Float = min(1, max(0, (sustain - 0.06) / 0.30))
        let onsetBonus: Float = sawOnset ? 0.15 : 0
        let timeDomain = min(
            config.minimumTonalConfidence,
            energyScore * 0.5625 + sustainScore * 0.4375
        )

        var confidence: Float
        if let tonalScore {
            // Tonality is the arbiter: a frame that is loud and sustained but *not* periodic is held
            // down no matter how piano-like its envelope looks.
            confidence = min(timeDomain, tonalScore)
        } else if evaluatesTonality, !hasTonalEvidence {
            // Tonality is evaluated here but the window is not full yet (the opening ~25 ms of
            // capture). Report a low confidence rather than claiming certainty about an unexamined
            // frame; the state machine's confirmation window absorbs this transient.
            confidence = min(timeDomain, 0.45)
        } else {
            // Not an evaluated block (the cue runs on alternate blocks): report the time-domain
            // estimate, which is already capped below certainty.
            confidence = timeDomain
        }
        // The onset bonus sharpens responsiveness inside a phrase, but it must not be able to lift
        // a frame past the tonal ceiling — otherwise a periodic-but-not-piano sound (a sustained
        // vowel) could still score full marks.
        confidence = min(config.minimumTonalConfidence, max(0, confidence + onsetBonus))

        Log.verbose(Log.analyzer, "rmsDB=\(blockRMSDB) floor=\(self.noiseFloorDB) sustain=\(sustain) onset=\(sawOnset) conf=\(confidence)")

        return DetectionResult(
            isPlaying: confidence >= config.enterPlayingConfidence,
            confidence: confidence,
            onset: sawOnset,
            rms: blockRMS,
            rmsDB: blockRMSDB,
            peakDB: blockPeakDB,
            noiseFloorDB: noiseFloorDB,
            timestamp: frame.timestamp,
            features: features
        )
    }

    // MARK: - Envelope / onset

    private func pushHop(levelDB: Float, active: Bool) {
        envelopeDB[envelopeIndex] = levelDB
        activeHops[activeIndex] = active
        envelopeIndex = (envelopeIndex + 1) % envelopeDB.count
        activeIndex = (activeIndex + 1) % activeHops.count
        envelopeFilled = min(envelopeFilled + 1, envelopeDB.count)
        activeFilled = min(activeFilled + 1, activeHops.count)
    }

    /// Reference level = mean of hops older than 100 ms (so the attack cannot raise its own
    /// reference) but within the last 400 ms. Silence replays the noise floor.
    private func referenceLevelDB() -> Float {
        let hopsPerSecond = sampleRate / Double(hopFrames)
        let skip = Int(hopsPerSecond * 0.10)
        let window = Int(hopsPerSecond * 0.40)
        guard envelopeFilled > skip else { return noiseFloorDB }
        var sum: Float = 0
        var count = 0
        for offset in skip..<min(window, envelopeFilled) {
            let index = ((envelopeIndex - 1 - offset) % envelopeDB.count + envelopeDB.count) % envelopeDB.count
            sum += envelopeDB[index]
            count += 1
        }
        guard count > 0 else { return noiseFloorDB }
        let reference = sum / Float(count)
        // A silent reference must never be *quieter* than the noise floor, otherwise a quiet room
        // would make every tiny sound look like a 30 dB attack.
        return max(reference, noiseFloorDB)
    }

    private func detectOnset(levelDB: Float, timestamp: Double, active: Bool, config: DetectorConfiguration) -> Bool {
        guard active else { return false }
        guard timestamp - lastOnsetTime >= config.onsetDebounceSeconds else { return false }
        let reference = referenceLevelDB()
        guard levelDB - reference >= config.onsetThresholdDB else { return false }

        lastOnsetTime = timestamp
        onsetTimes.append(timestamp)
        let cutoff = timestamp - config.onsetWindowSeconds
        while let first = onsetTimes.first, first < cutoff { onsetTimes.removeFirst() }
        return true
    }

    /// Fraction of the last 300 ms in which the signal was above the activity gate.
    /// A piano note (even a short staccato one) scores high; a metronome click scores near zero.
    private func sustainRatio() -> Float {
        let hopsPerSecond = sampleRate / Double(hopFrames)
        let window = max(1, Int(hopsPerSecond * 0.30))
        guard activeFilled > 0 else { return 0 }
        let count = min(window, activeFilled)
        var active = 0
        for offset in 0..<count {
            let index = ((activeIndex - 1 - offset) % activeHops.count + activeHops.count) % activeHops.count
            if activeHops[index] { active += 1 }
        }
        return Float(active) / Float(count)
    }

    // MARK: - Noise floor / level

    /// Slow-tracking minimum-statistics style noise floor.
    private func updateNoiseFloor(blockRMSDB: Float, config: DetectorConfiguration) {
        guard shortTermInitialised else {
            // Warm-up: track the quietest block seen so far. Starting capture mid-performance then
            // yields a floor near the music instead of above it, so the detector stays conservative
            // until the room really does go quiet once.
            warmupBlocks += 1
            if blockRMSDB < warmupMinimumDB {
                warmupMinimumDB = blockRMSDB
                hasWarmupMinimum = true
            }
            shortTermRMSDB = blockRMSDB
            if warmupBlocks >= Self.warmupBlockCount {
                noiseFloorDB = hasWarmupMinimum ? warmupMinimumDB : blockRMSDB
                shortTermInitialised = true
            } else {
                noiseFloorDB = hasWarmupMinimum ? warmupMinimumDB : blockRMSDB
            }
            return
        }
        // Asymmetric tracker:
        //   signal below the floor  -> fall quickly (the room really is quieter),
        //   signal above the floor  -> rise very slowly, and only when the signal is not loud
        //                              enough to be music. A sustained chord can therefore never
        //                              drag the floor up far enough to mask the next phrase.
        let margin = blockRMSDB - noiseFloorDB
        let timeConstant: Double
        if margin <= 0 {
            timeConstant = config.noiseFloorAttackSeconds
        } else if margin < config.noiseFloorMarginDB {
            timeConstant = config.noiseFloorRiseSeconds
        } else {
            timeConstant = config.noiseFloorReleaseSeconds
        }
        let alpha = Float(min(1, 1 - exp(-1.0 / max(0.001, timeConstant * 20)))) // ~20 blocks/s nominal
        noiseFloorDB += margin * alpha
        noiseFloorDB = min(noiseFloorDB, config.noiseFloorMaxDB)
    }

    private func updateShortTerm(_ blockRMSDB: Float) {
        guard shortTermInitialised else {
            shortTermRMSDB = blockRMSDB
            return
        }
        shortTermRMSDB += (blockRMSDB - shortTermRMSDB) * 0.35
    }

    // MARK: - Spectral

    /// Tonality runs on every other block: the cue is stable enough that this keeps detection tight
    /// while halving its cost, and it is the single most expensive per-sample step in `.eco` mode.
    private func shouldEvaluateTonality() -> Bool {
        blockCounter += 1
        return blockCounter % 2 == 0
    }

    /// Normalised autocorrelation over a window long enough to contain two periods of the lowest
    /// note we care about (55 Hz ≈ 18 ms).
    private func computePeriodicity(samples: [Float]) -> Float? {
        tonalAssembler.append(samples)
        guard tonalAssembler.isFull else { return nil }
        return tonalAssembler.withFrame { pointer, available in
            DSP.periodicity(pointer, count: available, sampleRate: sampleRate)
        }
    }

    // MARK: - Diagnostics

    /// Number of onsets detected inside the configured window.
    public var onsetCountInWindow: Int { onsetTimes.count }
    /// Smoothed frame loudness in dBFS, for the level meter.
    public var currentLevelDB: Float { shortTermRMSDB }
    /// Current noise floor estimate in dBFS.
    public var currentNoiseFloorDB: Float { noiseFloorDB }

    /// Diagnostic capture of every periodicity measurement, used by the tonal regression test and
    /// by the hardware-validation tool.
    public internal(set) var capturedPeriodicities: [Float] = []
    /// Sample rate the detector is configured for, exposed for diagnostics.
    public var configuredSampleRate: Double { sampleRate }
}

#endif
