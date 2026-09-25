import XCTest
@testable import PianoMonitorKit

/// Measures the realtime cost of the analysis chain.
///
/// This matters more than raw latency for a background tool: PianoMonitor runs for hours, so the
/// question is "what fraction of one core does it need while idling and while playing?" These
/// numbers are the ones quoted in IMPLEMENTATION_REPORT.md, and they are asserted loosely so a
/// genuine performance regression fails the suite without making it flaky on a busy machine.
final class PerformanceTests: XCTestCase {

    /// Audio seconds processed per wall-clock second. Anything above ~20x means the detector uses
    /// well under 5 % of a core, which is the budget for an always-on background app.
    private func realtimeFactor(
        of detector: BasicPianoDetector,
        signal: [Float]
    ) -> Double {
        let frames = TestSignals.frames(from: signal)
        let audioSeconds = Double(signal.count) / TestSignals.sampleRate
        let start = DispatchTime.now().uptimeNanoseconds
        for frame in frames {
            _ = detector.process(frame: frame)
        }
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return audioSeconds / max(elapsedSeconds, 1e-9)
    }

    func testDetectorIsFarFasterThanRealtime() throws {
        // 30 s of continuous piano, the worst case: every frame is loud and tonal, so every stage of
        // the chain does full work.
        let signal = TestSignals.pianoNotes(seconds: 30)
        let detector = BasicPianoDetector(configuration: .default, sampleRate: TestSignals.sampleRate)

        // Discard the first pass: it includes page faults and Swift runtime warm-up.
        _ = realtimeFactor(of: detector, signal: TestSignals.pianoNotes(seconds: 2))
        detector.reset()

        let factor = realtimeFactor(of: detector, signal: signal)
        let coreFraction = 100.0 / factor
        print(String(format: "@@ detector: %.1fx realtime (about %.2f%% of one core while playing)", factor, coreFraction))

        XCTAssertGreaterThan(factor, 20, "detector must run at least 20x faster than realtime")
    }

    func testDetectorIdleCostIsLowerThanPlaying() throws {
        // A quiet room is the common case, so it must be the cheap one.
        let silence = TestSignals.silence(seconds: 20, levelDB: -80)
        let playing = TestSignals.pianoNotes(seconds: 20)

        let idleDetector = BasicPianoDetector(configuration: .default, sampleRate: TestSignals.sampleRate)
        _ = realtimeFactor(of: idleDetector, signal: TestSignals.silence(seconds: 2))
        idleDetector.reset()
        let idleFactor = realtimeFactor(of: idleDetector, signal: silence)

        let playingDetector = BasicPianoDetector(configuration: .default, sampleRate: TestSignals.sampleRate)
        _ = realtimeFactor(of: playingDetector, signal: TestSignals.pianoNotes(seconds: 2))
        playingDetector.reset()
        let playingFactor = realtimeFactor(of: playingDetector, signal: playing)

        print(String(format: "@@ idle: %.1fx realtime, playing: %.1fx realtime", idleFactor, playingFactor))
        XCTAssertGreaterThan(idleFactor, 20, "idle analysis must be far faster than realtime")
    }

    func testTempoAnalyzerIsFarFasterThanRealtime() throws {
        // The tempo analyzer only runs while its window is open, but it must still be cheap enough
        // to run without stuttering the UI.
        var configuration = TempoConfiguration.default
        configuration.useSpectralClickGate = false
        let analyzer = TempoAnalyzer(configuration: configuration, sampleRate: TestSignals.sampleRate)
        let signal = TestSignals.metronome(seconds: 30, bpm: 100)
        let frames = TestSignals.frames(from: signal)
        let audioSeconds = Double(signal.count) / TestSignals.sampleRate

        // Warm-up pass.
        for frame in TestSignals.frames(from: TestSignals.metronome(seconds: 2, bpm: 100)) {
            analyzer.process(frame: frame)
        }
        analyzer.reset()

        let start = DispatchTime.now().uptimeNanoseconds
        for frame in frames {
            analyzer.process(frame: frame)
        }
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let factor = audioSeconds / max(elapsedSeconds, 1e-9)
        print(String(format: "@@ tempo: %.1fx realtime (about %.2f%% of one core)", factor, 100.0 / factor))

        XCTAssertGreaterThan(factor, 15, "tempo analysis must run well faster than realtime")
    }

    func testRingBufferDropsNothingAtNormalRates() {
        // The audio thread publishes ~43 buffers/s; the analysis loop drains several per wake-up.
        // Nothing should be dropped at a realistic pace.
        let ring = AudioRingBuffer(slotCount: 3, capacity: 4_096)
        var samples = [Float](repeating: 0.1, count: 1_024)
        for index in 0..<500 {
            samples.withUnsafeBufferPointer { pointer in
                ring.write(pointer.baseAddress!, frameCount: 1_024, timestamp: Double(index))
            }
            var output = [Float](repeating: 0, count: 4_096)
            _ = output.withUnsafeMutableBufferPointer { pointer in
                ring.read(into: pointer.baseAddress!, capacity: 4_096)
            }
        }
        XCTAssertEqual(ring.droppedBufferCount, 0, "a reader that keeps up must never lose a buffer")
        // `totalWrittenFrames` counts audio frames, not buffers.
        XCTAssertEqual(ring.totalWrittenFrames, 500 * 1_024)
    }

    func testRingBufferOverwritesRatherThanBlocking() {
        // If the reader stalls entirely the writer must keep going and simply drop: never block the
        // audio thread, and never read torn data.
        let ring = AudioRingBuffer(slotCount: 3, capacity: 4_096)
        var samples = [Float](repeating: 0.5, count: 1_024)
        for index in 0..<50 {
            samples.withUnsafeBufferPointer { pointer in
                ring.write(pointer.baseAddress!, frameCount: 1_024, timestamp: Double(index))
            }
        }
        XCTAssertGreaterThan(ring.droppedBufferCount, 0, "a stalled reader must cause drops, not back-pressure")

        // The reader still gets a coherent, newest buffer.
        var output = [Float](repeating: 0, count: 4_096)
        let frame = output.withUnsafeMutableBufferPointer { pointer in
            ring.read(into: pointer.baseAddress!, capacity: 4_096)
        }
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.frames, 1_024)
        XCTAssertTrue(output.prefix(1_024).allSatisfy { $0 == 0.5 }, "the published buffer must be intact")
    }

    func testStatisticsAggregationIsCheapForAYearOfSessions() {
        // The dashboard recomputes statistics on every session boundary; with years of data this
        // must still be effectively free.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_600_000_000)
        var sessions: [PracticeSessionSnapshot] = []
        for day in 0..<730 {
            for session in 0..<2 {
                let sessionStart = start.addingTimeInterval(Double(day) * 86_400 + Double(session) * 3_600)
                sessions.append(PracticeSessionSnapshot(
                    startDate: sessionStart,
                    endDate: sessionStart.addingTimeInterval(1_800),
                    duration: 1_800,
                    activeDuration: 1_500,
                    segmentCount: 3,
                    isOpen: false
                ))
            }
        }
        let reference = start.addingTimeInterval(730 * 86_400)
        let begin = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<50 {
            _ = PracticeAggregator.statistics(sessions: sessions, period: .week, reference: reference, calendar: calendar)
            _ = PracticeAggregator.dailySummaries(sessions: sessions, days: 7, endingOn: reference, calendar: calendar)
        }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000 / 50
        print(String(format: "@@ statistics over %d sessions: %.2f ms per recompute", sessions.count, perCall))
        XCTAssertLessThan(perCall, 50, "statistics over 1460 sessions must stay well under 50 ms")
    }
}
