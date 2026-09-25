import Foundation

// The wire contract between the macOS app (server) and the iOS app (client).
//
// Rules that follow from the spec:
// - **Read-only.** There is no request type that mutates anything, and by construction no endpoint
//   can change practice data, settings, or the machine.
// - **Value types only.** Everything is `Codable`, so both apps can decode into the same structs
//   and there is no second schema to keep in sync.
// - Dates are ISO-8601 strings (RFC 3339), which is what `JSONDecoder.dateDecodingStrategy =
//   .iso8601` expects on both sides.

public enum APIConstants {
    public static let bonjourServiceType = "_pianomonitor._tcp"
    /// Bump when the wire format changes in a way older clients cannot read.
    public static let apiVersion = 1
    public static let defaultPort: UInt16 = 8_787

    /// The machine's name for display.
    ///
    /// **Do not use `ProcessInfo.processInfo.hostName` here.** On macOS it resolves through `NSHost`,
    /// which blocks the calling thread on a background `getaddrinfo` work item that itself needs the
    /// main queue. Calling it on the main thread — which the HTTP server setup does — deadlocked the
    /// app at launch; `sample` showed the main thread parked in `NSHost blockingResolveUntil:` while
    /// the resolver waited on the main queue.
    ///
    /// `gethostname(2)` is a plain kernel call: no DNS, no work item, no main-thread dependency.
    /// This file is shared with iOS, where the same call is available.
    public static let localHostName: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "Mac" }
        let raw = String(cString: buffer)
        guard !raw.isEmpty else { return "Mac" }
        // Strip a trailing `.local` so the UI shows "Studio" rather than "Studio.local".
        return raw.hasSuffix(".local") ? String(raw.dropLast(".local".count)) : raw
    }()
}

// MARK: - /api/status

public struct CurrentSessionResponse: Codable, Equatable, Sendable {
    public var start: Date
    /// Active (playing) seconds so far in this session.
    public var activeDuration: Double
    /// Wall-clock seconds since the session started.
    public var duration: Double

    public init(start: Date, activeDuration: Double, duration: Double = 0) {
        self.start = start
        self.activeDuration = activeDuration
        self.duration = duration
    }
}

public struct ServerInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: Int
    public var hostName: String

    public static let pianoMonitor = ServerInfo(
        name: "PianoMonitor",
        version: APIConstants.apiVersion,
        hostName: APIConstants.localHostName
    )

    public init(name: String, version: Int, hostName: String) {
        self.name = name
        self.version = version
        self.hostName = hostName
    }
}

public struct APIStatusResponse: Codable, Equatable, Sendable {
    public var isPlaying: Bool
    /// `idle` / `playing` / `pause`.
    public var state: String
    public var todayActiveDuration: Double
    public var todaySessionCount: Int
    public var currentSession: CurrentSessionResponse?
    public var inputDevice: String?
    public var outputDeviceName: String?
    public var audioState: String
    public var sampleRate: Double
    public var server: ServerInfo
    /// Server-side timestamp, used by the client to show "updated 2 min ago".
    public var generatedAt: Date

    public init(
        isPlaying: Bool,
        state: String,
        todayActiveDuration: Double,
        todaySessionCount: Int,
        currentSession: CurrentSessionResponse?,
        inputDevice: String?,
        outputDeviceName: String?,
        audioState: String,
        sampleRate: Double,
        server: ServerInfo,
        generatedAt: Date = Date()
    ) {
        self.isPlaying = isPlaying
        self.state = state
        self.todayActiveDuration = todayActiveDuration
        self.todaySessionCount = todaySessionCount
        self.currentSession = currentSession
        self.inputDevice = inputDevice
        self.outputDeviceName = outputDeviceName
        self.audioState = audioState
        self.sampleRate = sampleRate
        self.server = server
        self.generatedAt = generatedAt
    }

    /// Rendered by the client when the Mac is unreachable.
    public static let disconnected = APIStatusResponse(
        isPlaying: false,
        state: "unavailable",
        todayActiveDuration: 0,
        todaySessionCount: 0,
        currentSession: nil,
        inputDevice: nil,
        outputDeviceName: nil,
        audioState: "disconnected",
        sampleRate: 0,
        server: ServerInfo(name: "PianoMonitor", version: APIConstants.apiVersion, hostName: "unknown"),
        generatedAt: Date(timeIntervalSince1970: 0)
    )

    public var playingState: PlayingStateDescriptor {
        PlayingStateDescriptor(rawValue: state) ?? .idle
    }
}

/// String-valued playing state so the JSON stays readable and forward compatible.
public enum PlayingStateDescriptor: String, Codable, Sendable {
    case idle
    case playing
    case pause
    case unavailable
}

// MARK: - /api/sessions

public struct APISessionsResponse: Codable, Equatable, Sendable {
    public var count: Int
    public var sessions: [PracticeSessionSnapshot]

    public init(sessions: [PracticeSessionSnapshot]) {
        self.count = sessions.count
        self.sessions = sessions
    }
}

// MARK: - /api/statistics

public struct APIStatisticsResponse: Codable, Equatable, Sendable {
    public var period: String
    public var statistics: PracticeStatistics
    /// Per-day breakdown, oldest first, including days with no practice.
    public var days: [DailyPracticeSummary]

    public init(period: String, statistics: PracticeStatistics, days: [DailyPracticeSummary]) {
        self.period = period
        self.statistics = statistics
        self.days = days
    }
}

// MARK: - /api/tempo

public struct APITempoResponse: Codable, Equatable, Sendable {
    /// Most recent measurement, live from the analyzer when the Mac is running it.
    public var live: TempoLiveMeasurement?
    /// Stored runs, newest first.
    public var history: [TempoSessionSnapshot]

    public init(live: TempoLiveMeasurement?, history: [TempoSessionSnapshot]) {
        self.live = live
        self.history = history
    }
}

public struct TempoLiveMeasurement: Codable, Equatable, Sendable {
    public var bpm: Double?
    public var minBPM: Double?
    public var maxBPM: Double?
    public var stabilityMilliseconds: Double?
    public var averageBeatIntervalMilliseconds: Double?
    public var beatCount: Int

    public init(
        bpm: Double?,
        minBPM: Double?,
        maxBPM: Double?,
        stabilityMilliseconds: Double?,
        averageBeatIntervalMilliseconds: Double?,
        beatCount: Int
    ) {
        self.bpm = bpm
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        self.stabilityMilliseconds = stabilityMilliseconds
        self.averageBeatIntervalMilliseconds = averageBeatIntervalMilliseconds
        self.beatCount = beatCount
    }

    #if os(macOS)
    /// Built from the live analyzer's snapshot. macOS-only: `TempoSnapshot` comes from the tempo
    /// analyzer, which the iOS viewer never runs.
    public init(snapshot: TempoSnapshot) {
        self.bpm = snapshot.bpm
        self.minBPM = snapshot.minBPM
        self.maxBPM = snapshot.maxBPM
        self.stabilityMilliseconds = snapshot.stabilityMilliseconds
        self.averageBeatIntervalMilliseconds = snapshot.averageBeatIntervalMilliseconds
        self.beatCount = snapshot.beatCount
    }
    #endif
}

// MARK: - /api/diagnostics

/// Internal health, exposed so the pieces that cannot be unit-tested — microphone permission, the
/// Bonjour advertisement, the port actually in use — can be inspected from outside the app.
///
/// Still read-only, and still carries no audio or file data.
public struct APIDiagnosticsResponse: Codable, Equatable, Sendable {
    public var version: Int
    public var hostName: String
    public var bonjourServiceType: String
    public var listeningPort: UInt16?
    public var usedFallbackPort: Bool
    /// Whether Bonjour registration succeeded. The iPhone can only discover the Mac when this is
    /// true, so it is worth being able to see.
    public var bonjourAdvertising: Bool
    public var bonjourError: String?
    public var httpRequestCount: Int
    public var lastRequestPath: String?
    public var microphonePermission: String
    public var audioState: String
    public var audioDeviceName: String?
    public var analysisSampleRate: Double
    public var detectorName: String
    public var storageKind: String
    /// Monitoring latency, so "why does it feel laggy?" is answerable from outside the app.
    public var latencyProfile: String
    public var inputBufferFrames: Int?
    public var outputBufferFrames: Int?
    public var roundTripLatencyMilliseconds: Double?
    public var latencySummary: String
    public var latencyNotes: [String]
    public var generatedAt: Date

    public init(
        version: Int,
        hostName: String,
        bonjourServiceType: String,
        listeningPort: UInt16?,
        usedFallbackPort: Bool,
        bonjourAdvertising: Bool,
        bonjourError: String?,
        httpRequestCount: Int,
        lastRequestPath: String?,
        microphonePermission: String,
        audioState: String,
        audioDeviceName: String?,
        analysisSampleRate: Double,
        detectorName: String,
        storageKind: String,
        latencyProfile: String,
        inputBufferFrames: Int?,
        outputBufferFrames: Int?,
        roundTripLatencyMilliseconds: Double?,
        latencySummary: String,
        latencyNotes: [String],
        generatedAt: Date = Date()
    ) {
        self.version = version
        self.hostName = hostName
        self.bonjourServiceType = bonjourServiceType
        self.listeningPort = listeningPort
        self.usedFallbackPort = usedFallbackPort
        self.bonjourAdvertising = bonjourAdvertising
        self.bonjourError = bonjourError
        self.httpRequestCount = httpRequestCount
        self.lastRequestPath = lastRequestPath
        self.microphonePermission = microphonePermission
        self.audioState = audioState
        self.audioDeviceName = audioDeviceName
        self.analysisSampleRate = analysisSampleRate
        self.detectorName = detectorName
        self.storageKind = storageKind
        self.latencyProfile = latencyProfile
        self.inputBufferFrames = inputBufferFrames
        self.outputBufferFrames = outputBufferFrames
        self.roundTripLatencyMilliseconds = roundTripLatencyMilliseconds
        self.latencySummary = latencySummary
        self.latencyNotes = latencyNotes
        self.generatedAt = generatedAt
    }
}

// MARK: - Errors

/// Failures a caller must surface, as opposed to per-request errors.
public enum PianoAPIServerError: LocalizedError {
    case portUnavailable

    public var errorDescription: String? {
        switch self {
        case .portUnavailable:
            return "Could not open a network port for the LAN API. Practice recording is unaffected."
        }
    }
}

public struct APIErrorResponse: Codable, Equatable, Sendable {
    public var error: String
    public var message: String
    public var generatedAt: Date

    public init(error: String, message: String) {
        self.error = error
        self.message = message
        self.generatedAt = Date()
    }
}

// MARK: - Shared codec

/// One place that defines how the API encodes dates and keys, so client and server can never drift.
public enum APICoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
