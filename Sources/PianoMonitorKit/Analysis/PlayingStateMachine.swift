import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// The practice state machine the spec asks for:
/// ```
/// idle <-> playing <-> pause
/// ```
/// with the crucial rule that a short break does **not** end a practice session. Only a long
/// silence (`endSessionAfterSilenceSeconds`, default 3 min) closes it.
///
/// The machine is intentionally separated from the detector: the detector answers "is there piano
/// sound right now", this answers "what does that mean for the practice session". Swapping the
/// detector therefore cannot change session semantics.
public final class PlayingStateMachine {

    public enum State: String, Sendable, Equatable {
        case idle
        case playing
        case pause
    }

    /// A state change worth persisting or showing in the UI.
    public enum Transition: Equatable, Sendable {
        /// `idle -> playing`: a new session begins.
        case sessionStarted(at: Date)
        /// `playing -> pause`: the current segment ends, the session stays open.
        case segmentEnded(at: Date)
        /// `pause -> playing`: a new segment opens inside the same session.
        case segmentStarted(at: Date)
        /// `pause -> idle`: the session is closed and ready to persist.
        case sessionEnded(at: Date, reason: EndReason)

        public enum EndReason: String, Sendable {
            case silence
            case stopped
            case audioLost
        }
    }

    public private(set) var state: State = .idle
    /// Confidence of the most recent frame, for UI display.
    public private(set) var lastConfidence: Float = 0
    /// When the current playing stretch began (monotonic seconds), for "current session" display.
    public private(set) var playingSince: Double?

    private var configuration: DetectorConfiguration
    private let clock: () -> Date

    /// Monotonic timestamps (seconds) of state boundaries. `Date` is only materialised on
    /// transition, so the audio path never calls `Date()` per frame.
    private var sessionStartSeconds: Double?
    private var segmentStartSeconds: Double?
    /// Timestamp when the signal last looked like piano playing.
    private var lastPlayingSeconds: Double = -.greatestFiniteMagnitude
    /// Timestamp when continuous silence began (after leaving `playing`).
    private var silenceStartSeconds: Double?
    /// Timestamp of the first *continuous* piano evidence in the confirm window.
    private var confirmationStartSeconds: Double?
    /// Wall-clock anchor so monotonic seconds can be converted to real dates.
    private var anchorUptime: Double = ProcessInfo.processInfo.systemUptime

    public init(configuration: DetectorConfiguration, clock: @escaping () -> Date = { Date() }) {
        self.configuration = configuration
        self.clock = clock
    }

    public func update(configuration: DetectorConfiguration) {
        self.configuration = configuration
    }

    /// Feeds one detection result in and returns any transition it caused.
    ///
    /// - Parameter timestamp: monotonic seconds from the audio pipeline. Negative always forces a
    ///   fresh session, which is what we want on first frame anyway.
    public func process(_ result: DetectionResult) -> Transition? {
        lastConfidence = result.confidence
        let timestamp = result.timestamp
        let config = configuration

        switch state {
        case .idle:
            guard result.isPlaying else {
                confirmationStartSeconds = nil
                return nil
            }
            // Require *continuous* piano evidence, so one isolated bang does not open a session.
            if confirmationStartSeconds == nil {
                confirmationStartSeconds = timestamp
                return nil
            }
            guard timestamp - (confirmationStartSeconds ?? timestamp) >= config.confirmPlayingSeconds else {
                return nil
            }
            let date = wallClock(for: timestamp)
            state = .playing
            sessionStartSeconds = timestamp
            segmentStartSeconds = timestamp
            playingSince = timestamp
            lastPlayingSeconds = timestamp
            silenceStartSeconds = nil
            confirmationStartSeconds = nil
            Log.session.notice("Session started")
            return .sessionStarted(at: date)

        case .playing:
            if result.isPlaying {
                lastPlayingSeconds = timestamp
                silenceStartSeconds = nil
                return nil
            }
            // Leave `playing` only after the pause threshold, so thinking between phrases keeps
            // the session running.
            let silenceReference = silenceStartSeconds ?? lastPlayingSeconds
            guard timestamp - silenceReference >= config.pauseAfterSilenceSeconds else { return nil }
            silenceStartSeconds = timestamp
            let date = wallClock(for: timestamp)
            state = .pause
            playingSince = nil
            let endedSegmentStart = segmentStartSeconds
            segmentStartSeconds = nil
            Log.session.notice("Session paused after \(timestamp - (endedSegmentStart ?? timestamp))s segment")
            return .segmentEnded(at: date)

        case .pause:
            if result.isPlaying {
                let date = wallClock(for: timestamp)
                state = .playing
                segmentStartSeconds = timestamp
                playingSince = timestamp
                lastPlayingSeconds = timestamp
                silenceStartSeconds = nil
                Log.session.notice("Session resumed")
                return .segmentStarted(at: date)
            }
            let silenceReference = silenceStartSeconds ?? lastPlayingSeconds
            guard timestamp - silenceReference >= config.endSessionAfterSilenceSeconds else { return nil }
            let date = wallClock(for: timestamp)
            state = .idle
            sessionStartSeconds = nil
            segmentStartSeconds = nil
            silenceStartSeconds = nil
            playingSince = nil
            Log.session.notice("Session ended after \(config.endSessionAfterSilenceSeconds)s of silence")
            return .sessionEnded(at: date, reason: .silence)
        }
    }

    /// Forces the machine back to `idle`, e.g. when capture is stopped or the device disappears.
    /// Returns the closing transition when a session was open, so the caller can persist it.
    public func forceIdle(reason: Transition.EndReason = .stopped) -> Transition? {
        guard state != .idle else { return nil }
        let timestamp = lastPlayingSeconds.isFinite ? lastPlayingSeconds : 0
        let date = wallClock(for: timestamp)
        state = .idle
        sessionStartSeconds = nil
        segmentStartSeconds = nil
        silenceStartSeconds = nil
        playingSince = nil
        confirmationStartSeconds = nil
        return .sessionEnded(at: date, reason: reason)
    }

    /// Re-anchors the monotonic clock (used when the audio device changes and sample time restarts).
    public func rebase(timestamp: Double) {
        anchorUptime = ProcessInfo.processInfo.systemUptime
        if state != .idle {
            let shift = timestamp - lastPlayingSeconds
            sessionStartSeconds = sessionStartSeconds.map { $0 + shift }
            segmentStartSeconds = segmentStartSeconds.map { $0 + shift }
            lastPlayingSeconds = timestamp
        }
    }

    /// Converts a monotonic audio timestamp into a wall-clock `Date`.
    private func wallClock(for timestamp: Double) -> Date {
        let now = clock()
        let elapsed = ProcessInfo.processInfo.systemUptime - anchorUptime
        // `timestamp` is audio time; `elapsed` is how long ago that audio was captured.
        return now.addingTimeInterval(-max(0, elapsed))
    }
}

#endif
