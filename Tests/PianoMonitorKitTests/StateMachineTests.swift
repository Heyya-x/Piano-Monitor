import XCTest
@testable import PianoMonitorKit

/// Verifies the practice state machine, with the spec's central rule under test:
/// **a short break must not split one practice session into two.**
final class StateMachineTests: XCTestCase {

    private func makeMachine(
        pause: Double = 8,
        endSession: Double = 180,
        confirm: Double = 0.8
    ) -> PlayingStateMachine {
        var configuration = DetectorConfiguration.default
        configuration.pauseAfterSilenceSeconds = pause
        configuration.endSessionAfterSilenceSeconds = endSession
        configuration.confirmPlayingSeconds = confirm
        return PlayingStateMachine(configuration: configuration)
    }

    /// Builds a detection result at a given audio timestamp.
    private func result(_ playing: Bool, at time: Double, confidence: Float = 0.9) -> DetectionResult {
        DetectionResult(
            isPlaying: playing,
            confidence: playing ? confidence : 0,
            onset: playing,
            rms: playing ? 0.05 : 0.0001,
            rmsDB: playing ? -26 : -80,
            peakDB: playing ? -20 : -75,
            noiseFloorDB: -70,
            timestamp: time,
            features: DetectionFeatures()
        )
    }

    /// Feeds `playing` frames for `duration` seconds starting at `start`, advancing in 23 ms blocks.
    @discardableResult
    private func feed(
        _ machine: PlayingStateMachine,
        playing: Bool,
        from start: Double,
        duration: Double,
        transitions: inout [PlayingStateMachine.Transition]
    ) -> Double {
        let block = 1_024.0 / 44_100
        var time = start
        let end = start + duration
        while time < end {
            if let transition = machine.process(result(playing, at: time)) {
                transitions.append(transition)
            }
            time += block
        }
        return time
    }

    // MARK: - Happy path

    func testIdleToPlayingRequiresConfirmation() {
        let machine = makeMachine(confirm: 1.0)
        // A single instantaneous sound must NOT open a session.
        XCTAssertNil(machine.process(result(true, at: 0.0)))
        XCTAssertEqual(machine.state, .idle)
        // Still inside the confirmation window.
        XCTAssertNil(machine.process(result(true, at: 0.5)))
        XCTAssertEqual(machine.state, .idle)
        // Past the window: playing begins.
        let transition = machine.process(result(true, at: 1.1))
        XCTAssertEqual(machine.state, .playing)
        guard case .sessionStarted = transition else {
            return XCTFail("expected sessionStarted, got \(String(describing: transition))")
        }
    }

    func testShortPauseDoesNotEndSession() {
        var transitions: [PlayingStateMachine.Transition] = []
        let machine = makeMachine(pause: 8, endSession: 180)
        var time = feed(machine, playing: true, from: 0, duration: 20, transitions: &transitions)
        // A 6-second break: under the pause threshold, so `playing` continues uninterrupted.
        time = feed(machine, playing: false, from: time, duration: 6, transitions: &transitions)
        time = feed(machine, playing: true, from: time, duration: 20, transitions: &transitions)

        XCTAssertEqual(machine.state, .playing)
        XCTAssertEqual(transitions.count, 1, "a 6 s break must not generate any transition")
        guard case .sessionStarted = transitions.first else {
            return XCTFail("expected exactly one sessionStarted")
        }
    }

    func testPauseThenResumeStaysInOneSession() {
        var transitions: [PlayingStateMachine.Transition] = []
        let machine = makeMachine(pause: 8, endSession: 180)
        var time = feed(machine, playing: true, from: 0, duration: 20, transitions: &transitions)
        // A 12-second break: past the pause threshold, so we enter `pause` but stay in the session.
        time = feed(machine, playing: false, from: time, duration: 12, transitions: &transitions)
        XCTAssertEqual(machine.state, .pause, "long-ish silence should pause, not end")
        time = feed(machine, playing: true, from: time, duration: 15, transitions: &transitions)

        XCTAssertEqual(machine.state, .playing)
        let ended = transitions.contains { if case .sessionEnded = $0 { return true }; return false }
        XCTAssertFalse(ended, "a 12 s break must not end the session")
        let segmentEnded = transitions.contains { if case .segmentEnded = $0 { return true }; return false }
        let segmentStarted = transitions.contains { if case .segmentStarted = $0 { return true }; return false }
        XCTAssertTrue(segmentEnded, "the first segment should have closed")
        XCTAssertTrue(segmentStarted, "a new segment should have opened on resume")
    }

    func testLongSilenceEndsSession() {
        var transitions: [PlayingStateMachine.Transition] = []
        let machine = makeMachine(pause: 8, endSession: 30)
        var time = feed(machine, playing: true, from: 0, duration: 20, transitions: &transitions)
        time = feed(machine, playing: false, from: time, duration: 40, transitions: &transitions)

        XCTAssertEqual(machine.state, .idle)
        let ends = transitions.compactMap { transition -> PlayingStateMachine.Transition.EndReason? in
            if case .sessionEnded(_, let reason) = transition { return reason }
            return nil
        }
        XCTAssertEqual(ends, [.silence])
    }

    func testTwoSessionsAreSeparatedByLongSilence() {
        var transitions: [PlayingStateMachine.Transition] = []
        let machine = makeMachine(pause: 8, endSession: 30)
        var time = feed(machine, playing: true, from: 0, duration: 20, transitions: &transitions)
        time = feed(machine, playing: false, from: time, duration: 40, transitions: &transitions)
        time = feed(machine, playing: true, from: time, duration: 20, transitions: &transitions)

        let starts = transitions.filter { if case .sessionStarted = $0 { return true }; return false }
        XCTAssertEqual(starts.count, 2, "a 40 s break must produce two distinct sessions")
    }

    func testIsolatedSoundDoesNotOpenSession() {
        var transitions: [PlayingStateMachine.Transition] = []
        let machine = makeMachine(confirm: 0.8)
        // One block of "sound" (23 ms), then silence: a chair bump, not practice.
        if let transition = machine.process(result(true, at: 0.0)) { transitions.append(transition) }
        var time = 0.023
        time = feed(machine, playing: false, from: time, duration: 10, transitions: &transitions)
        _ = time

        XCTAssertTrue(transitions.isEmpty, "a single 23 ms sound must not open a session")
        XCTAssertEqual(machine.state, .idle)
    }

    func testForceIdleClosesOpenSession() {
        let machine = makeMachine()
        _ = machine.process(result(true, at: 0.0))
        _ = machine.process(result(true, at: 2.0))
        XCTAssertEqual(machine.state, .playing)

        let transition = machine.forceIdle()
        guard case .sessionEnded(_, let reason)? = transition else {
            return XCTFail("forceIdle should close the session")
        }
        XCTAssertEqual(reason, .stopped)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNil(machine.forceIdle(), "forceIdle on an idle machine is a no-op")
    }
}
