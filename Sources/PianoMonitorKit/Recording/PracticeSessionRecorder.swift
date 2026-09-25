import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// Owns the `PlayingStateMachine` and turns its transitions into persisted activity.
///
/// This type is the only place that decides *when* practice time is written. It writes on state
/// changes only — a handful of small writes per session, not one per audio frame — which is a large
/// part of why the app can run all day without showing up in Activity Monitor.
public final class PracticeSessionRecorder: @unchecked Sendable {

    private let store: PianoDataStore
    private let stateMachine: PlayingStateMachine
    private let queue = DispatchQueue(label: "com.pianomonitor.session.recorder", qos: .utility)

    /// Current session id, or `nil` when idle.
    private var sessionID: UUID?
    private var segmentID: UUID?
    private var segmentStart: Date?
    /// Running confidence accumulator for the open segment.
    private var segmentConfidenceSum: Double = 0
    private var segmentConfidenceCount: Int = 0
    /// Start of the whole session, for the live "current session" readout.
    private var sessionStart: Date?
    /// Active seconds accumulated in closed segments of the open session.
    private var closedActiveDuration: Double = 0

    /// Notified on the main queue after every transition, with a fresh live snapshot.
    public var onStateChange: (@Sendable (RecorderSnapshot) -> Void)?

    public init(store: PianoDataStore, configuration: DetectorConfiguration) {
        self.store = store
        self.stateMachine = PlayingStateMachine(configuration: configuration)
    }

    /// Immutable view of the recorder for the UI and `GET /api/status`.
    public struct RecorderSnapshot: Sendable, Equatable {
        public var state: PlayingStateMachine.State
        public var confidence: Float
        /// Active seconds of the open session (closed segments + the currently open one).
        public var currentSessionActiveDuration: Double
        /// Wall-clock seconds since the open session began.
        public var currentSessionDuration: Double
        public var sessionStart: Date?
        public var sessionID: UUID?

        public static let idle = RecorderSnapshot(
            state: .idle, confidence: 0, currentSessionActiveDuration: 0,
            currentSessionDuration: 0, sessionStart: nil, sessionID: nil
        )
    }

    public func update(configuration: DetectorConfiguration) {
        stateMachine.update(configuration: configuration)
    }

    /// Feeds one detection result and performs any resulting persistence.
    ///
    /// Called on the analysis queue. Storage work is dispatched to the recorder queue so a slow
    /// disk write can never stall audio analysis.
    public func process(_ result: DetectionResult, now: Date = Date()) {
        queue.async { [weak self] in
            self?.processLocked(result, now: now)
        }
    }

    private func processLocked(_ result: DetectionResult, now: Date) {
        guard let transition = stateMachine.process(result) else {
            publishSnapshot()
            return
        }

        switch transition {
        case .sessionStarted(let at):
            let id = UUID()
            sessionID = id
            sessionStart = at
            closedActiveDuration = 0
            write(ActivityRecord(kind: .sessionOpened(sessionID: id, at: at), timestamp: at))
            // A session always begins inside a playing segment.
            openSegment(sessionID: id, at: at)

        case .segmentEnded(let at):
            closeSegment(at: at)

        case .segmentStarted(let at):
            guard let sessionID else { return }
            openSegment(sessionID: sessionID, at: at)

        case .sessionEnded(let at, _):
            closeSegment(at: at)
            guard let id = sessionID else { return }
            // Fold the last segment into the reported total before clearing state.
            closedActiveDuration += max(0, at.timeIntervalSince(segmentStart ?? at))
            write(ActivityRecord(kind: .sessionClosed(sessionID: id, at: at), timestamp: at))
            resetCurrentSession()
        }

        publishSnapshot()
    }

    private func openSegment(sessionID: UUID, at: Date) {
        let id = UUID()
        segmentID = id
        segmentStart = at
        segmentConfidenceSum = 0
        segmentConfidenceCount = 0
        write(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: id, at: at), timestamp: at))
    }

    private func closeSegment(at: Date) {
        guard let sessionID, let segmentID, let segmentStart else { return }
        let elapsed = max(0, at.timeIntervalSince(segmentStart))
        closedActiveDuration += elapsed
        let confidence = segmentConfidenceCount > 0 ? segmentConfidenceSum / Double(segmentConfidenceCount) : 0
        write(ActivityRecord(
            kind: .segmentClosed(sessionID: sessionID, segmentID: segmentID, at: at, confidence: confidence),
            timestamp: at
        ))
        self.segmentID = nil
        self.segmentStart = nil
        segmentConfidenceSum = 0
        segmentConfidenceCount = 0
    }

    private func resetCurrentSession() {
        sessionID = nil
        sessionStart = nil
        closedActiveDuration = 0
        segmentID = nil
        segmentStart = nil
        segmentConfidenceSum = 0
        segmentConfidenceCount = 0
    }

    /// Closes any open session, e.g. on app quit or when capture stops.
    public func finalize(reason: PlayingStateMachine.Transition.EndReason = .stopped) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let transition = self.stateMachine.forceIdle(reason: reason) else { return }
            if case .sessionEnded(let at, _) = transition {
                self.closeSegment(at: at)
                if let id = self.sessionID {
                    self.write(ActivityRecord(kind: .sessionClosed(sessionID: id, at: at), timestamp: at))
                }
                self.resetCurrentSession()
                self.publishSnapshot()
            }
        }
    }

    /// Resets adaptive timing state after a device change, keeping any open session alive.
    public func rebase(timestamp: Double) {
        queue.async { [weak self] in
            self?.stateMachine.rebase(timestamp: timestamp)
        }
    }

    private func write(_ record: ActivityRecord) {
        let store = self.store
        Task {
            do {
                try await store.recordActivity(record)
            } catch {
                Log.session.error("Failed to persist activity: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func publishSnapshot() {
        let snapshot = currentSnapshot(now: Date())
        let handler = onStateChange
        DispatchQueue.main.async { handler?(snapshot) }
    }

    /// Reads the current state. Thread-safe enough for display purposes: the UI only needs an
    /// approximately-current value, and it is refreshed on every transition.
    public func currentSnapshot(now: Date = Date()) -> RecorderSnapshot {
        let openSegmentDuration = segmentStart.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return RecorderSnapshot(
            state: stateMachine.state,
            confidence: stateMachine.lastConfidence,
            currentSessionActiveDuration: closedActiveDuration + openSegmentDuration,
            currentSessionDuration: sessionStart.map { max(0, now.timeIntervalSince($0)) } ?? 0,
            sessionStart: sessionStart,
            sessionID: sessionID
        )
    }
}

#endif
