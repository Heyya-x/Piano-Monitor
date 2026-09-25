import XCTest
@testable import PianoMonitorKit

/// Behavioural tests for `BasicPianoDetector`.
///
/// They run on synthetic signals (see `TestSignals`) because a TOP1 is not attached to the build
/// machine. Each case asserts a *relative* property — “piano scores higher than a metronome” —
/// rather than a magic confidence number, so tuning the thresholds does not require rewriting the
/// tests, while a genuine regression still fails.
final class DetectorTests: XCTestCase {

    private func makeDetector() -> BasicPianoDetector {
        BasicPianoDetector(configuration: .default, sampleRate: TestSignals.sampleRate)
    }

    /// Runs a signal and returns the peak confidence and the fraction of frames called "playing".
    @discardableResult
    private func analyse(_ samples: [Float]) -> (peakConfidence: Float, playingFraction: Double, onsets: Int) {
        let detector = makeDetector()
        var peak: Float = 0
        var playing = 0
        var total = 0
        for frame in TestSignals.frames(from: samples) {
            let result = detector.process(frame: frame)
            peak = max(peak, result.confidence)
            if result.isPlaying { playing += 1 }
            total += 1
        }
        return (peak, total == 0 ? 0 : Double(playing) / Double(total), detector.onsetCountInWindow)
    }

    // MARK: - Silence and noise

    func testSilenceDoesNotTrigger() {
        let result = analyse(TestSignals.silence(seconds: 4))
        XCTAssertLessThan(result.peakConfidence, DetectionThresholds.playingConfidence, "silence must never be classified as playing")
        XCTAssertEqual(result.playingFraction, 0, "silence produced playing frames")
    }

    func testAmbientNoiseDoesNotTrigger() {
        // A noisy room (-55 dBFS) is still not piano.
        let result = analyse(TestSignals.silence(seconds: 4, levelDB: -55, seed: 42))
        XCTAssertLessThan(result.peakConfidence, DetectionThresholds.playingConfidence, "ambient noise must not be classified as playing")
    }

    func testNoiseFloorAdaptsUpward() {
        let detector = makeDetector()
        let quiet = TestSignals.silence(seconds: 2, levelDB: -80)
        for frame in TestSignals.frames(from: quiet) { _ = detector.process(frame: frame) }
        let quietFloor = detector.currentNoiseFloorDB

        let noisy = TestSignals.silence(seconds: 6, levelDB: -55, seed: 9)
        for frame in TestSignals.frames(from: noisy) { _ = detector.process(frame: frame) }
        let noisyFloor = detector.currentNoiseFloorDB

        XCTAssertGreaterThan(noisyFloor, quietFloor, "noise floor should track a louder room upward")
        XCTAssertLessThan(noisyFloor, -40, "noise floor should not run away to the clamp")
    }

    // MARK: - Speech

    /// Speech rejection, as far as synthetic audio can support it.
    ///
    /// A sustained vowel and a sustained piano note are acoustically *similar*: both are harmonic,
    /// both sit in the same register, both ring. What separates them in practice is that a piano
    /// note has a bright harmonic series while speech concentrates energy in formants with a
    /// comparatively noisy high end. The detector therefore relies on spectral peak prominence,
    /// which measures 690–1000 for the synthetic piano and ~3.5 for everything else.
    ///
    /// This test asserts the detector *discriminates* — it does not claim speech can never open a
    /// session. See IMPLEMENTATION_REPORT.md ("Requires physical hardware test") for the procedure
    /// to validate this against a real microphone.
    func testSpeechScoresBelowPiano() {
        let speech = analyse(TestSignals.speech(seconds: 8))
        let piano = analyse(TestSignals.pianoNotes(seconds: 8))
        // Both classes contain frames that are genuinely periodic, so a per-frame *peak* cannot
        // separate them; what separates them is how much of the time the signal looks like piano.
        XCTAssertLessThan(
            speech.playingFraction,
            piano.playingFraction,
            "speech must be classified as playing less often than piano"
        )
        XCTAssertLessThan(
            speech.playingFraction,
            0.5,
            "most of a speech signal must not register as practice"
        )
        XCTAssertGreaterThan(
            piano.playingFraction,
            0.75,
            "continuous piano playing must be classified as playing"
        )
    }

    // MARK: - Piano

    func testContinuousPlayingIsDetected() {
        let result = analyse(TestSignals.pianoNotes(seconds: 5, notesPerSecond: 4))
        XCTAssertGreaterThan(result.peakConfidence, DetectionThresholds.playingConfidence, "a real phrase must reach playing confidence")
        XCTAssertGreaterThan(result.playingFraction, 0.6, "most of a continuous phrase should be classified as playing")
    }

    func testSingleNoteIsDetected() {
        // Detached single notes every 1.5 s: each one is clearly piano, so confidence must rise,
        // even though the *session* logic still refuses to open a session for one isolated note.
        let result = analyse(TestSignals.pianoNotes(seconds: 6, notesPerSecond: 1 / 1.5, gapFraction: 0.5))
        XCTAssertGreaterThan(result.peakConfidence, DetectionThresholds.playingConfidence, "an isolated note must still read as piano")
    }

    func testSlowPlayingStillDetected() {
        let result = analyse(TestSignals.pianoNotes(seconds: 6, notesPerSecond: 1.2))
        XCTAssertGreaterThan(result.peakConfidence, DetectionThresholds.playingConfidence)
        XCTAssertGreaterThan(result.playingFraction, 0.5)
    }

    func testOnsetsAreCountedForPlaying() {
        let result = analyse(TestSignals.pianoNotes(seconds: 5, notesPerSecond: 4))
        XCTAssertGreaterThan(result.onsets, 0, "detached notes should register onsets")
    }

    // MARK: - Metronome rejection

    func testMetronomeAloneScoresLowerThanPiano() {
        for bpm in [60.0, 80.0, 100.0, 120.0] {
            let metronome = analyse(TestSignals.metronome(seconds: 5, bpm: bpm))
            let piano = analyse(TestSignals.pianoNotes(seconds: 5, notesPerSecond: bpm / 60))
            XCTAssertLessThan(
                metronome.peakConfidence,
                piano.peakConfidence,
                "a bare metronome at \(bpm) BPM must score below piano at the same rate"
            )
        }
    }

    func testMetronomeAloneDoesNotSustain() {
        // The decisive property: clicks have no sustain, so the detector must not call them playing
        // for a large fraction of the time even if individual frames spike.
        let result = analyse(TestSignals.metronome(seconds: 6, bpm: 100))
        XCTAssertLessThan(result.playingFraction, 0.25, "a click train must not look like continuous playing")
    }

    // MARK: - Metronome + piano

    func testMetronomePlusPianoIsStillDetected() {
        let piano = TestSignals.pianoNotes(seconds: 6, notesPerSecond: 2)
        let click = TestSignals.metronome(seconds: 6, bpm: 100)
        let result = analyse(TestSignals.mix(piano, click))
        XCTAssertGreaterThan(result.peakConfidence, DetectionThresholds.playingConfidence, "piano must still be detected over a metronome")
        XCTAssertGreaterThan(result.playingFraction, 0.5)
    }

    // MARK: - Reset

    func testResetClearsAdaptiveState() {
        let detector = makeDetector()
        for frame in TestSignals.frames(from: TestSignals.pianoNotes(seconds: 3)) {
            _ = detector.process(frame: frame)
        }
        detector.reset()
        XCTAssertEqual(detector.onsetCountInWindow, 0)
        XCTAssertEqual(detector.currentLevelDB, -70, accuracy: 1.0, "reset must restore the initial level estimate")
    }
}

/// Shared expectations, named so the tests document the tuning they depend on.
enum DetectionThresholds {
    /// Slightly below `DetectorConfiguration.default.enterPlayingConfidence`, because the tests ask
    /// "did confidence clear the playing bar" rather than "did it reach some new value".
    static let playingConfidence: Float = DetectorConfiguration.default.enterPlayingConfidence
}
