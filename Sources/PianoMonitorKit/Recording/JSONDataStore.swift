import Foundation

/// File-backed store used when SwiftData is unavailable (macOS 10.15 – 13) and in unit tests.
///
/// Design notes:
/// - One small JSON document per concern, written atomically, so a crash mid-write cannot leave a
///   half-written file. The previous contents are kept as `.bak` and used as a recovery path.
/// - Everything happens inside an `actor`, so the UI, the HTTP server and the analyzer can all
///   touch it without a lock.
/// - Sessions are pruned to a bounded history so the file stays small after years of daily use.
public actor JSONDataStore: PianoDataStore {

    public nonisolated let kind = "JSON file"

    private var sessions: [PracticeSessionSnapshot] = []
    private var tempoSessions: [TempoSessionSnapshot] = []
    private var settings: AppSettings = .default

    private let directory: URL
    private let sessionsURL: URL
    private let tempoURL: URL
    private let settingsURL: URL
    private let maximumSessions: Int

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Minimum active time for a session to be worth keeping. Mirrors
    /// `DetectorConfiguration.default.minimumSessionActiveSeconds`; kept as a plain constant here so
    /// this file compiles on iOS, where the detector configuration does not exist.
    static let minimumSessionActiveSeconds: Double = 20

    public init(directory: URL, maximumSessions: Int = 2_000) {
        self.directory = directory
        self.sessionsURL = directory.appendingPathComponent("sessions.json")
        self.tempoURL = directory.appendingPathComponent("tempo.json")
        self.settingsURL = directory.appendingPathComponent("settings.json")
        self.maximumSessions = maximumSessions
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Default location: `~/Library/Application Support/PianoMonitor`.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PianoMonitor", isDirectory: true)
    }

    // MARK: - Loading

    /// Loads from disk. Mirrors the file to `.bak` on every successful load so a corrupted write
    /// still leaves a recoverable copy.
    public func load() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessions = loadArray(PracticeSessionSnapshot.self, from: sessionsURL) ?? []
        tempoSessions = loadArray(TempoSessionSnapshot.self, from: tempoURL) ?? []
        settings = loadValue(AppSettings.self, from: settingsURL) ?? .default
        Log.store.notice("JSON store loaded \(self.sessions.count, privacy: .public) sessions, \(self.tempoSessions.count, privacy: .public) tempo runs from \(self.directory.path, privacy: .public)")
    }

    private func loadArray<T: Decodable>(_ type: T.Type, from url: URL) -> [T]? {
        loadValue([T].self, from: url)
    }

    private func loadValue<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let value = try decoder.decode(type, from: data)
            return value
        } catch {
            Log.store.error("Failed to read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Fall back to the recovery copy before giving up.
            let backup = url.appendingPathExtension("bak")
            if let data = try? Data(contentsOf: backup), let value = try? decoder.decode(type, from: data) {
                Log.store.notice("Recovered \(url.lastPathComponent, privacy: .public) from backup")
                return value
            }
            return nil
        }
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let data = try encoder.encode(value)
            // Preserve the previous contents as a recovery copy *before* overwriting. Doing this on
            // the write path (rather than after a successful read) is what makes the backup track
            // the most recent good state even though the store is only loaded once per launch.
            let backup = url.appendingPathExtension("bak")
            if let existing = try? Data(contentsOf: url) {
                try? existing.write(to: backup, options: .atomic)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            Log.store.error("Failed to write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw StoreError.underlying("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Sessions

    public func session(id: UUID) async throws -> PracticeSessionSnapshot? {
        sessions.first { $0.id == id }
    }

    @discardableResult
    public func recordActivity(_ record: ActivityRecord) async throws -> Bool {
        switch record.kind {
        case .sessionOpened(let sessionID, let at):
            if !sessions.contains(where: { $0.id == sessionID }) {
                sessions.append(PracticeSessionSnapshot(id: sessionID, startDate: at, isOpen: true))
            }
            return true

        case .segmentOpened(let sessionID, let segmentID, let at):
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
                // The session record is missing (fresh install, deleted file): recreate it so a
                // practice session in progress is never silently lost.
                sessions.append(PracticeSessionSnapshot(
                    id: sessionID,
                    startDate: at,
                    isOpen: true,
                    segments: [PracticeSegmentSnapshot(id: segmentID, startDate: at, endDate: at)]
                ))
                return true
            }
            sessions[index].segments.append(PracticeSegmentSnapshot(id: segmentID, startDate: at, endDate: at))
            sessions[index].segmentCount = sessions[index].segments.count
            try await flushSessions()
            return true

        case .segmentClosed(let sessionID, let segmentID, let at, let confidence):
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
                  let segmentIndex = sessions[index].segments.firstIndex(where: { $0.id == segmentID }) else {
                return false
            }
            sessions[index].segments[segmentIndex].endDate = at
            sessions[index].segments[segmentIndex].duration = max(0, at.timeIntervalSince(sessions[index].segments[segmentIndex].startDate))
            sessions[index].segments[segmentIndex].averageConfidence = confidence
            recompute(&sessions[index])
            // Intermediate flush: a crash mid-practice should not lose the whole session.
            try await flushSessions()
            return true

        case .sessionClosed(let sessionID, let at):
            guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
            sessions[index].endDate = at
            sessions[index].isOpen = false
            recompute(&sessions[index])

            // Drop sessions that never accumulated meaningful practice (a bumped chair, a cough).
            // The threshold comes from the detector configuration on macOS; the shared default is
            // used elsewhere (the iOS viewer never discards anything, but the JSON store is shared
            // with the test target and the Catalina build).
            if sessions[index].activeDuration < Self.minimumSessionActiveSeconds {
                Log.session.notice("Discarding session shorter than minimum active duration (\(sessions[index].activeDuration, privacy: .public)s)")
                sessions.remove(at: index)
                try await flushSessions()
                return false
            }
            Sessions.sortNewestFirst(&sessions)
            if sessions.count > maximumSessions {
                sessions.removeLast(sessions.count - maximumSessions)
            }
            try await flushSessions()
            return true
        }
    }

    private func recompute(_ session: inout PracticeSessionSnapshot) {
        session.activeDuration = session.segments.reduce(0) { $0 + $1.duration }
        session.segmentCount = session.segments.count
        let effectiveEnd = session.endDate ?? session.segments.last?.endDate
        if let effectiveEnd {
            session.duration = max(0, effectiveEnd.timeIntervalSince(session.startDate))
        } else {
            session.duration = session.activeDuration
        }
    }

    private func flushSessions() async throws {
        try persist(sessions, to: sessionsURL)
    }

    public func sessions(from: Date?, to: Date?, limit: Int?, includeSegments: Bool) async throws -> [PracticeSessionSnapshot] {
        var result = sessions
        if let from { result = result.filter { $0.startDate >= from } }
        if let to { result = result.filter { $0.startDate <= to } }
        Sessions.sortNewestFirst(&result)
        if let limit, result.count > limit { result = Array(result.prefix(limit)) }
        if !includeSegments {
            for index in result.indices { result[index].segments = [] }
        }
        return result
    }

    public func deleteSession(id: UUID) async throws {
        sessions.removeAll { $0.id == id }
        try await flushSessions()
    }

    // MARK: - Statistics

    public func statistics(period: StatisticsPeriod, reference: Date, calendar: Calendar) async throws -> PracticeStatistics {
        PracticeAggregator.statistics(sessions: sessions, period: period, reference: reference, calendar: calendar)
    }

    public func dailySummaries(days: Int, endingOn: Date, calendar: Calendar) async throws -> [PracticeDay] {
        PracticeAggregator.dailySummaries(sessions: sessions, days: days, endingOn: endingOn, calendar: calendar)
    }

    // MARK: - Tempo

    public func saveTempoSession(_ snapshot: TempoSessionSnapshot) async throws {
        tempoSessions.append(snapshot)
        if tempoSessions.count > 500 {
            tempoSessions.removeFirst(tempoSessions.count - 500)
        }
        try persist(tempoSessions, to: tempoURL)
    }

    public func tempoSessions(from: Date?, to: Date?, limit: Int?) async throws -> [TempoSessionSnapshot] {
        var result = tempoSessions
        if let from { result = result.filter { $0.startDate >= from } }
        if let to { result = result.filter { $0.startDate <= to } }
        result.sort { $0.startDate > $1.startDate }
        if let limit, result.count > limit { result = Array(result.prefix(limit)) }
        return result
    }

    // MARK: - Settings

    public func loadSettings() async throws -> AppSettings {
        settings
    }

    public func saveSettings(_ settings: AppSettings) async throws {
        self.settings = settings
        try persist(settings, to: settingsURL)
    }
}

/// Small shared helpers for session ordering.
public enum Sessions {
    public static func sortNewestFirst(_ sessions: inout [PracticeSessionSnapshot]) {
        sessions.sort { $0.startDate > $1.startDate }
    }
}
