import Foundation

/// All persisted user settings in one `Codable` value.
///
/// Storing settings as a single record keeps the schema stable: adding a field never requires a
/// migration, and both the SwiftData and JSON backends persist it as one blob.
public struct AppSettings: Codable, Equatable, Sendable {
    // MARK: Audio devices (stored as UIDs — stable across replug and reboot, unlike AudioDeviceID)
    public var inputDeviceUID: String?
    public var outputDeviceUID: String?
    /// Pass-through monitoring. Off by default: mic + speakers + gain is a feedback loop.
    public var monitoringEnabled: Bool
    /// Linear gain applied to the monitored signal.
    public var monitoringGain: Float
    /// How hard to push the hardware IO buffers down. The dominant term in monitoring latency.
    public var latencyProfile: LatencyProfile
    /// Whether the detector may duck the monitor path while playing. Off by default: monitoring is
    /// for hearing yourself, and the duck cannot prevent feedback anyway (it reacts too late).
    public var feedbackGuardEnabled: Bool

    // MARK: Detection
    /// 0…1; maps onto the detector's level gates. See `DetectorConfiguration.sensitivity`.
    public var sensitivity: Float
    /// Seconds of silence before `playing -> pause`. 5…10 s keeps a phrase break inside one session.
    public var pauseAfterSilenceSeconds: Double
    /// Seconds of silence before `pause -> idle` (session closed and persisted).
    public var endSessionAfterSilenceSeconds: Double

    // MARK: Tempo analyzer
    /// The BPM the user dialled into the external metronome, used for the error readout.
    public var metronomeTargetBPM: Double

    // MARK: App behaviour
    public var launchAtLogin: Bool
    public var verboseLogging: Bool
    /// Restrict the HTTP server to the local network. Kept as a setting for transparency even
    /// though it is always true in this version.
    public var allowLocalNetworkAPI: Bool
    /// Optional shared token required by the HTTP API. `nil` disables authentication.
    public var apiToken: String?
    /// Port for the HTTP server; `nil` asks the system for any free port.
    public var preferredPort: Int?

    public static let `default` = AppSettings(
        inputDeviceUID: nil,
        outputDeviceUID: nil,
        monitoringEnabled: false,
        monitoringGain: 1.0,
        latencyProfile: .minimal,
        feedbackGuardEnabled: false,
        sensitivity: 0.5,
        pauseAfterSilenceSeconds: 8,
        endSessionAfterSilenceSeconds: 180,
        metronomeTargetBPM: 100,
        launchAtLogin: false,
        verboseLogging: false,
        allowLocalNetworkAPI: true,
        apiToken: nil,
        preferredPort: 8_787
    )

    public init(
        inputDeviceUID: String?,
        outputDeviceUID: String?,
        monitoringEnabled: Bool,
        monitoringGain: Float,
        latencyProfile: LatencyProfile,
        feedbackGuardEnabled: Bool,
        sensitivity: Float,
        pauseAfterSilenceSeconds: Double,
        endSessionAfterSilenceSeconds: Double,
        metronomeTargetBPM: Double,
        launchAtLogin: Bool,
        verboseLogging: Bool,
        allowLocalNetworkAPI: Bool,
        apiToken: String?,
        preferredPort: Int?
    ) {
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.monitoringEnabled = monitoringEnabled
        self.monitoringGain = monitoringGain
        self.latencyProfile = latencyProfile
        self.feedbackGuardEnabled = feedbackGuardEnabled
        self.sensitivity = sensitivity
        self.pauseAfterSilenceSeconds = pauseAfterSilenceSeconds
        self.endSessionAfterSilenceSeconds = endSessionAfterSilenceSeconds
        self.metronomeTargetBPM = metronomeTargetBPM
        self.launchAtLogin = launchAtLogin
        self.verboseLogging = verboseLogging
        self.allowLocalNetworkAPI = allowLocalNetworkAPI
        self.apiToken = apiToken
        self.preferredPort = preferredPort
    }

    #if os(macOS)
    /// Builds the detector configuration implied by these settings.
    ///
    /// This is the single place where the three user-facing detection settings become thresholds —
    /// the spec's "thresholds must not be hard-coded in several places" rule. macOS only: the iOS
    /// app never runs a detector.
    public func detectorConfiguration() -> DetectorConfiguration {
        var configuration = DetectorConfiguration.default
        configuration.sensitivity = sensitivity
        configuration.pauseAfterSilenceSeconds = pauseAfterSilenceSeconds
        configuration.endSessionAfterSilenceSeconds = endSessionAfterSilenceSeconds
        return configuration
    }
    #endif
}
