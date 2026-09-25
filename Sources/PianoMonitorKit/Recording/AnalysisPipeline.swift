import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// Runs the entire realtime analysis chain **off the main actor**.
///
/// ```
/// AudioEngine.onFrame (analysis queue)
///        |
///        v
///   BasicPianoDetector -> PracticeSessionRecorder -> PianoDataStore
///        |
///        +-> TempoAnalyzer (only while the Tempo screen asks for it)
///        |
///        v
///   LiveMetrics (lock-protected) --read--> PianoMonitorService --throttled--> SwiftUI
/// ```
///
/// The detector and the tempo analyzer are separate objects with separate state, so a tempo
/// measurement can never influence practice-time recording. The only thing they share is the audio
/// frame they both read.
public final class AnalysisPipeline: @unchecked Sendable {

    private let store: PianoDataStore
    private let detector: BasicPianoDetector
    private let tempo: TempoAnalyzer
    private let recorder: PracticeSessionRecorder

    /// Serialises detector/tempo/recorder access. Nothing here is on the audio render thread — the
    /// engine hands us buffers on its own private analysis queue — so a plain queue is enough.
    private let queue = DispatchQueue(label: "com.pianomonitor.analysis.pipeline", qos: .utility)

    private let metricsLock = NSLock()
    private var storedMetrics = LiveMetrics.initial
    private var storedSessionStart: Date?

    /// Analysis profile, readable from any thread. `0 = eco, 1 = balanced, 2 = analysis`.
    /// Stored as an atomic so the detector can consult it from the analysis queue without a lock.
    private let modeStorage = AtomicInt(AnalysisMode.eco.rawValueIndex)

    /// Called (on an arbitrary queue) when a session opens or closes, so the service can refresh
    /// today's totals without polling the store.
    public var onSessionBoundary: (@Sendable () -> Void)?

    public init(store: PianoDataStore, configuration: DetectorConfiguration, sampleRate: Double) {
        self.store = store
        self.tempo = TempoAnalyzer(configuration: configuration.tempo, sampleRate: sampleRate)
        self.recorder = PracticeSessionRecorder(store: store, configuration: configuration)
        self.detector = BasicPianoDetector(configuration: configuration, sampleRate: sampleRate)
    }

    /// Current analysis profile. Safe from any thread.
    public var analysisMode: AnalysisMode {
        get { AnalysisMode(index: modeStorage.value) }
        set { modeStorage.store(newValue.rawValueIndex) }
    }

    /// Human-readable detector name, for diagnostics.
    public var detectorName: String { detector.name }

    // MARK: - Control (called from the main actor)

    public func update(configuration: DetectorConfiguration, targetBPM: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.detector.update(configuration: configuration)
            self.recorder.update(configuration: configuration)
            self.tempo.update(configuration: configuration.tempo, targetBPM: targetBPM)
        }
    }

    public func update(sampleRate: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.detector.update(sampleRate: sampleRate)
            self.tempo.update(sampleRate: sampleRate)
        }
    }

    /// Closes any open session (app quit, sleep, capture stop).
    public func finalize(reason: PlayingStateMachine.Transition.EndReason = .stopped) {
        queue.async { [weak self] in
            self?.recorder.finalize(reason: reason)
        }
    }

    public func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.detector.reset()
            self.tempo.reset()
        }
    }

    /// Clears tempo measurements only, leaving the piano detector's adaptive state alone so an
    /// in-progress practice session is unaffected.
    public func resetTempo() {
        queue.async { [weak self] in
            self?.tempo.reset()
        }
    }

    // MARK: - Realtime path (called on the engine's analysis queue)

    public func ingest(_ frame: ProcessedAudioFrame) {
        queue.async { [weak self] in
            self?.ingestLocked(frame)
        }
    }

    private func ingestLocked(_ frame: ProcessedAudioFrame) {
        let result = detector.process(frame: frame)
        recorder.process(result)

        let mode = analysisMode
        if mode == .analysis {
            tempo.process(frame: frame)
        }

        // Tempo snapshots are only recomputed at the UI cadence, not per audio block.
        let tempoSnapshot = mode == .analysis ? tempo.snapshot() : .empty
        let snapshot = recorder.currentSnapshot()

        metricsLock.lock()
        storedMetrics.state = snapshot.state
        storedMetrics.confidence = result.confidence
        storedMetrics.inputLevelDB = result.rmsDB
        storedMetrics.noiseFloorDB = result.noiseFloorDB
        storedMetrics.currentSessionActiveDuration = snapshot.currentSessionActiveDuration
        storedMetrics.currentSessionDuration = snapshot.currentSessionDuration
        storedMetrics.sessionStart = snapshot.sessionStart
        storedMetrics.onsetCount = detector.onsetCountInWindow
        storedMetrics.tempo = tempoSnapshot
        storedSessionStart = snapshot.sessionStart
        metricsLock.unlock()

        // Reduce history writes: only at session boundaries.
        if snapshot.state == .idle, result.confidence < 0.1, lastReportedState != .idle {
            lastReportedState = .idle
            onSessionBoundary?()
        } else if snapshot.state != .idle {
            lastReportedState = snapshot.state
        }
    }

    private var lastReportedState: PlayingStateMachine.State = .idle

    // MARK: - Reads (any thread)

    public func metrics() -> LiveMetrics {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return storedMetrics
    }

    /// Latest tempo measurement, computed on demand (cheap: a few dozen doubles).
    public func tempoSnapshot() -> TempoSnapshot {
        queue.sync { tempo.snapshot() }
    }

    /// Persists a tempo run, stamping in the user's dialled-in target so the error readout is stored.
    public func finishTempoRun(targetBPM: Double?) async {
        let snapshot: TempoSnapshot = queue.sync { tempo.snapshot() }
        guard snapshot.hasMeasurement else { return }
        let record = TempoSessionSnapshot(
            startDate: Date().addingTimeInterval(-Double(snapshot.beatCount) * (snapshot.averageBeatIntervalMilliseconds ?? 0) / 1000),
            endDate: Date(),
            averageBPM: snapshot.bpm ?? 0,
            minBPM: snapshot.minBPM ?? 0,
            maxBPM: snapshot.maxBPM ?? 0,
            stabilityMilliseconds: snapshot.stabilityMilliseconds ?? 0,
            targetBPM: targetBPM,
            errorPercent: targetBPM.flatMap { target in
                guard target > 0, let bpm = snapshot.bpm else { return nil }
                return (bpm - target) / target * 100
            },
            beatCount: snapshot.totalBeatCount
        )
        do {
            try await store.saveTempoSession(record)
        } catch {
            Log.store.error("Could not persist tempo session: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#endif
