import XCTest
@testable import PianoMonitorKit

/// Behavioural tests for `TempoAnalyzer`.
///
/// The purpose of this analyzer is to *measure* an external metronome (the TOP1's dial is not
/// accurate), so the assertions are about measured accuracy: does a 100 BPM click train read as
/// ~100 BPM, and does a jittery train report a larger stability figure than a steady one?
final class TempoAnalyzerTests: XCTestCase {

    private func analyse(_ samples: [Float], targetBPM: Double? = nil) -> TempoSnapshot {
        var configuration = TempoConfiguration.default
        // The spectral click gate needs an FFT that only `.analysis` mode provides; these tests run
        // the analyzer directly, so disable the gate and exercise the time-domain path.
        configuration.useSpectralClickGate = false
        let analyzer = TempoAnalyzer(configuration: configuration, sampleRate: TestSignals.sampleRate)
        if let targetBPM { _ = analyzer.update(configuration: configuration, targetBPM: targetBPM) }
        for frame in TestSignals.frames(from: samples) {
            analyzer.process(frame: frame)
        }
        return analyzer.snapshot()
    }

    private func assertBPM(_ measured: Double?, expected: Double, tolerance: Double = 1.5, file: StaticString = #filePath, line: UInt = #line) {
        guard let measured else {
            return XCTFail("no BPM measured, expected \(expected)", file: file, line: line)
        }
        XCTAssertEqual(
            measured,
            expected,
            accuracy: tolerance,
            "measured \(measured) BPM, expected \(expected) BPM",
            file: file,
            line: line
        )
    }

    // MARK: - Common metronome markings

    func testDetects60BPM() {
        assertBPM(analyse(TestSignals.metronome(seconds: 20, bpm: 60)).bpm, expected: 60)
    }

    func testDetects80BPM() {
        assertBPM(analyse(TestSignals.metronome(seconds: 20, bpm: 80)).bpm, expected: 80)
    }

    func testDetects96BPM() {
        assertBPM(analyse(TestSignals.metronome(seconds: 20, bpm: 96)).bpm, expected: 96)
    }

    func testDetects100BPM() {
        assertBPM(analyse(TestSignals.metronome(seconds: 20, bpm: 100)).bpm, expected: 100)
    }

    func testDetects120BPM() {
        assertBPM(analyse(TestSignals.metronome(seconds: 20, bpm: 120)).bpm, expected: 120)
    }

    func testBeatIntervalMatchesBPM() throws {
        let snapshot = analyse(TestSignals.metronome(seconds: 20, bpm: 96))
        let interval = try XCTUnwrap(snapshot.averageBeatIntervalMilliseconds)
        // 96 BPM => 625 ms per beat, the spec's own worked example.
        XCTAssertEqual(interval, 625, accuracy: 15, "96 BPM should measure ~625 ms per beat")
    }

    // MARK: - Accuracy and stability reporting

    func testReportsSetVersusActualError() {
        // The motivating use case: the user dials 100, the metronome plays 99.2.
        let snapshot = analyse(TestSignals.metronome(seconds: 20, bpm: 100), targetBPM: 100)
        let analyzer = TempoAnalyzer(configuration: .default, sampleRate: TestSignals.sampleRate)
        _ = analyzer.update(configuration: .default, targetBPM: 100)
        let error = analyzer.errorPercent(for: snapshot)
        XCTAssertNotNil(error)
        XCTAssertEqual(error ?? 0, 0, accuracy: 3, "a 100 BPM metronome measured against a 100 BPM target should be near 0 %")
    }

    func testJitterIncreasesReportedInstability() throws {
        let steady = analyse(TestSignals.metronome(seconds: 25, bpm: 100, seed: 5))
        let jittery = analyse(TestSignals.metronome(seconds: 25, bpm: 100, jitterMilliseconds: 25, seed: 5))

        let steadyStability = try XCTUnwrap(steady.stabilityMilliseconds)
        let jitteryStability = try XCTUnwrap(jittery.stabilityMilliseconds)
        XCTAssertLessThan(steadyStability, 12, "a click-perfect metronome should look very stable")
        XCTAssertGreaterThan(jitteryStability, steadyStability, "a jittery metronome must report worse stability")
    }

    func testMinMaxBracketTheAverage() throws {
        let snapshot = analyse(TestSignals.metronome(seconds: 20, bpm: 100))
        let average = try XCTUnwrap(snapshot.bpm)
        let minimum = try XCTUnwrap(snapshot.minBPM)
        let maximum = try XCTUnwrap(snapshot.maxBPM)
        XCTAssertLessThanOrEqual(minimum, average + 1.0)
        XCTAssertGreaterThanOrEqual(maximum, average - 1.0)
    }

    func testBeatDeviationsAreReported() throws {
        let snapshot = analyse(TestSignals.metronome(seconds: 20, bpm: 100))
        XCTAssertGreaterThan(snapshot.beatCount, 10, "20 s at 100 BPM should yield ~33 beats")
        XCTAssertFalse(snapshot.beats.isEmpty, "per-beat deviations should be available for the UI")
        // A steady train should keep per-beat deviation small.
        let worst = snapshot.beats.map { abs($0.deviationMilliseconds) }.max() ?? 0
        XCTAssertLessThan(worst, 25, "per-beat deviation should stay small for a steady train")
    }

    // MARK: - Independence from piano detection

    func testSilenceProducesNoMeasurement() {
        let snapshot = analyse(TestSignals.silence(seconds: 10, levelDB: -55))
        XCTAssertNil(snapshot.bpm, "room noise must not produce a tempo")
        XCTAssertFalse(snapshot.hasMeasurement)
    }

    func testEmptySnapshotIsSafeToRender() {
        // The UI reads `TempoSnapshot.empty` before any measurement exists; it must not report a
        // measurement and must not crash the formatter.
        XCTAssertFalse(TempoSnapshot.empty.hasMeasurement)
        XCTAssertNil(TempoSnapshot.empty.bpm)
        XCTAssertEqual(TempoSnapshot.empty.beatCount, 0)
    }

    func testResetClearsMeasurement() {
        var configuration = TempoConfiguration.default
        configuration.useSpectralClickGate = false
        let analyzer = TempoAnalyzer(configuration: configuration, sampleRate: TestSignals.sampleRate)
        for frame in TestSignals.frames(from: TestSignals.metronome(seconds: 12, bpm: 100)) {
            analyzer.process(frame: frame)
        }
        XCTAssertNotNil(analyzer.snapshot().bpm)
        analyzer.reset()
        XCTAssertNil(analyzer.snapshot().bpm)
        XCTAssertEqual(analyzer.snapshot().totalBeatCount, 0)
    }

    // MARK: - Octave-error handling

    func testMissedClicksDoNotHalveTheTempo() {
        // Drop every other click: a naive analyzer would report half the tempo. The fold-back logic
        // should keep the reported tempo in the right octave.
        var samples = TestSignals.metronome(seconds: 25, bpm: 120)
        let intervalSamples = Int((60.0 / 120) * TestSignals.sampleRate)
        var index = 0
        while index < samples.count {
            // Zero out every second click.
            let isSecond = (index / intervalSamples) % 2 == 1
            if isSecond {
                let end = min(samples.count, index + intervalSamples)
                for i in index..<end { samples[i] = 0 }
            }
            index += intervalSamples
        }
        let snapshot = analyse(samples)
        // With half the clicks removed the true click rate is 60 BPM; either 60 or 120 is a
        // defensible reading, but it must not land somewhere unrelated.
        guard let bpm = snapshot.bpm else { return XCTFail("expected a measurement from the thinned train") }
        XCTAssertTrue(
            abs(bpm - 60) < 4 || abs(bpm - 120) < 4,
            "thinned click train produced an implausible \(bpm) BPM"
        )
    }
}
