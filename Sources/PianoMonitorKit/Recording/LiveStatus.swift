import Foundation

// macOS-only: this is the live audio/analysis state the macOS UI renders.
#if os(macOS)


/// Immutable metrics shared between the analysis pipeline (which runs on a utility queue) and the
/// UI (which reads them at a throttled cadence).
public struct LiveMetrics: Sendable, Equatable {
    public var state: PlayingStateMachine.State = .idle
    public var confidence: Float = 0
    public var inputLevelDB: Float = -120
    public var noiseFloorDB: Float = -70
    public var currentSessionActiveDuration: Double = 0
    public var currentSessionDuration: Double = 0
    public var sessionStart: Date?
    public var onsetCount: Int = 0
    public var tempo: TempoSnapshot = .empty

    public static let initial = LiveMetrics()
}

/// Everything the UI renders, in one immutable value.
///
/// The UI never reads live audio state directly — it observes `LiveStatus` values published at a
/// throttled rate. This is the boundary the spec insists on: the audio thread cannot touch SwiftUI,
/// and the view tree cannot be rebuilt per audio buffer.
public struct LiveStatus: Sendable, Equatable {
    public var metrics = LiveMetrics.initial
    public var todayActiveDuration: Double = 0
    public var todaySessionCount: Int = 0
    public var connection: AudioConnectionState = .idle
    public var monitoring: MonitoringState = .off
    public var inputDeviceName: String?
    public var outputDeviceName: String?
    public var inputDeviceUID: String?
    public var outputDeviceUID: String?
    public var isInputDeviceConnected = true
    public var isOutputDeviceConnected = true
    public var analysisMode: AnalysisMode = .eco
    /// Downsampled min/max waveform pairs, only populated while a waveform view is on screen.
    public var waveform: [Float] = []
    public var sampleRate: Double = 44_100
    public var droppedBuffers: Int = 0
    public var detectorName: String = ""
    public var isRunning = false
    /// Measured latency of the capture/monitor path.
    public var latency = LatencyReport()

    public static let initial = LiveStatus()

    public var state: PlayingStateMachine.State { metrics.state }
    public var confidence: Float { metrics.confidence }
    public var inputLevelDB: Float { metrics.inputLevelDB }
    public var noiseFloorDB: Float { metrics.noiseFloorDB }
    public var latencySummary: String { latency.summary }
    public var todayDuration: Double { todayActiveDuration }
}

#endif
