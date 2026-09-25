import Foundation

#if canImport(SwiftData)
import SwiftData

/// SwiftData row for one practice segment.
///
/// The models are the *storage* representation only. Everything that leaves this file is a
/// `PracticeSegmentSnapshot`/`PracticeSessionSnapshot` value, which keeps the UI and the network
/// layer free of ORM objects (and their threading rules).
@available(macOS 14.0, iOS 17.0, *)
@Model
public final class StoredPracticeSegment {
    public var id: UUID = UUID()
    public var startDate: Date = Date()
    public var endDate: Date?
    public var duration: Double = 0
    public var averageConfidence: Double = 0
    public var session: StoredPracticeSession?

    public init(
        id: UUID,
        startDate: Date,
        endDate: Date?,
        duration: Double,
        averageConfidence: Double
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.averageConfidence = averageConfidence
    }
}

/// SwiftData row for one practice session.
@available(macOS 14.0, iOS 17.0, *)
@Model
public final class StoredPracticeSession {
    public var id: UUID = UUID()
    public var startDate: Date = Date()
    public var endDate: Date?
    /// Wall-clock span from first to last note.
    public var duration: Double = 0
    /// Time actually spent playing, i.e. excluding pauses. This is the headline number.
    public var activeDuration: Double = 0
    public var isOpen: Bool = false
    public var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \StoredPracticeSegment.session)
    public var segments: [StoredPracticeSegment]? = []

    public init(
        id: UUID,
        startDate: Date,
        endDate: Date?,
        duration: Double,
        activeDuration: Double,
        isOpen: Bool
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.activeDuration = activeDuration
        self.isOpen = isOpen
        self.createdAt = Date()
    }
}

/// SwiftData row for one tempo measurement run.
@available(macOS 14.0, iOS 17.0, *)
@Model
public final class StoredTempoSession {
    public var id: UUID = UUID()
    public var startDate: Date = Date()
    public var endDate: Date?
    public var averageBPM: Double = 0
    public var minBPM: Double = 0
    public var maxBPM: Double = 0
    public var stabilityMilliseconds: Double = 0
    public var targetBPM: Double?
    public var errorPercent: Double?
    public var beatCount: Int = 0

    public init(
        id: UUID,
        startDate: Date,
        endDate: Date?,
        averageBPM: Double,
        minBPM: Double,
        maxBPM: Double,
        stabilityMilliseconds: Double,
        targetBPM: Double?,
        errorPercent: Double?,
        beatCount: Int
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.averageBPM = averageBPM
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        self.stabilityMilliseconds = stabilityMilliseconds
        self.targetBPM = targetBPM
        self.errorPercent = errorPercent
        self.beatCount = beatCount
    }
}

/// SwiftData row holding the whole settings blob.
///
/// Settings live in a single `Codable` payload rather than one column per option: adding a setting
/// then never requires a schema migration, which matters for a tool the user runs for years.
@available(macOS 14.0, iOS 17.0, *)
@Model
public final class StoredSettings {
    public var id: String = "default"
    public var payload: Data = Data()
    public var updatedAt: Date = Date()

    public init(id: String = "default", payload: Data, updatedAt: Date = Date()) {
        self.id = id
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

/// SwiftData-backed store (macOS 14+/iOS 17+).
///
/// Runs as a `ModelActor`, so all context access is serialised on the actor's executor and nothing
/// ever touches `modelContext` from the main thread. The UI only sees value snapshots.
@available(macOS 14.0, iOS 17.0, *)
@ModelActor
public actor SwiftDataPianoStore {

    public nonisolated var kind: String { "SwiftData" }

    /// Builds a persistent container in Application Support.
    public static func makeContainer(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([
            StoredPracticeSession.self,
            StoredPracticeSegment.self,
            StoredTempoSession.self,
            StoredSettings.self,
        ])
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Sessions

    private func fetchSessionRow(id: UUID) throws -> StoredPracticeSession? {
        var descriptor = FetchDescriptor<StoredPracticeSession>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    @discardableResult
    public func recordActivity(_ record: ActivityRecord) async throws -> Bool {
        switch record.kind {
        case .sessionOpened(let sessionID, let at):
            guard try fetchSessionRow(id: sessionID) == nil else { return true }
            let row = StoredPracticeSession(
                id: sessionID, startDate: at, endDate: nil,
                duration: 0, activeDuration: 0, isOpen: true
            )
            modelContext.insert(row)
            try commit("open session")
            return true

        case .segmentOpened(let sessionID, let segmentID, let at):
            let row: StoredPracticeSession
            if let existing = try fetchSessionRow(id: sessionID) {
                row = existing
            } else {
                row = StoredPracticeSession(
                    id: sessionID, startDate: at, endDate: nil,
                    duration: 0, activeDuration: 0, isOpen: true
                )
                modelContext.insert(row)
            }
            let segment = StoredPracticeSegment(
                id: segmentID, startDate: at, endDate: nil, duration: 0, averageConfidence: 0
            )
            segment.session = row
            modelContext.insert(segment)
            row.segments = (row.segments ?? []) + [segment]
            try commit("open segment")
            return true

        case .segmentClosed(let sessionID, let segmentID, let at, let confidence):
            guard let row = try fetchSessionRow(id: sessionID),
                  let segment = (row.segments ?? []).first(where: { $0.id == segmentID }) else {
                return false
            }
            segment.endDate = at
            segment.duration = max(0, at.timeIntervalSince(segment.startDate))
            segment.averageConfidence = confidence
            refresh(row)
            // Intermediate save: a crash mid-practice must not lose the session.
            try commit("close segment")
            return true

        case .sessionClosed(let sessionID, let at):
            guard let row = try fetchSessionRow(id: sessionID) else { return false }
            row.endDate = at
            row.isOpen = false
            refresh(row)

            guard row.activeDuration >= JSONDataStore.minimumSessionActiveSeconds else {
                Log.session.notice("Discarding session shorter than minimum active duration (\(row.activeDuration, privacy: .public)s)")
                modelContext.delete(row)
                try commit("discard short session")
                return false
            }
            try commit("close session")
            return true
        }
    }

    private func refresh(_ row: StoredPracticeSession) {
        let segments = row.segments ?? []
        row.activeDuration = segments.reduce(0) { $0 + $1.duration }
        if let end = row.endDate ?? segments.compactMap({ $0.endDate }).max() {
            row.duration = max(0, end.timeIntervalSince(row.startDate))
        } else {
            row.duration = row.activeDuration
        }
        // Keep the cascade relationship consistent in both directions.
        for segment in segments where segment.session !== row {
            segment.session = row
        }
    }

    private func commit(_ what: String) throws {
        do {
            try modelContext.save()
        } catch {
            Log.store.error("SwiftData save failed while trying to \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw StoreError.underlying("Could not save practice data: \(error.localizedDescription)")
        }
    }

    private func snapshot(of row: StoredPracticeSession, includeSegments: Bool) -> PracticeSessionSnapshot {
        let segmentRows = (row.segments ?? []).sorted { $0.startDate < $1.startDate }
        let segments: [PracticeSegmentSnapshot] = includeSegments
            ? segmentRows.map {
                PracticeSegmentSnapshot(
                    id: $0.id,
                    startDate: $0.startDate,
                    endDate: $0.endDate ?? $0.startDate,
                    duration: $0.duration,
                    averageConfidence: $0.averageConfidence
                )
            }
            : []
        return PracticeSessionSnapshot(
            id: row.id,
            startDate: row.startDate,
            endDate: row.endDate,
            duration: row.duration,
            activeDuration: row.activeDuration,
            segmentCount: segmentRows.count,
            isOpen: row.isOpen,
            segments: segments
        )
    }

    public func session(id: UUID) async throws -> PracticeSessionSnapshot? {
        try fetchSessionRow(id: id).map { snapshot(of: $0, includeSegments: true) }
    }

    public func sessions(from: Date?, to: Date?, limit: Int?, includeSegments: Bool) async throws -> [PracticeSessionSnapshot] {
        var descriptor = FetchDescriptor<StoredPracticeSession>(
            sortBy: [SortDescriptor(\StoredPracticeSession.startDate, order: .reverse)]
        )
        // Relationship prefetching avoids a fault per session when segments are needed.
        descriptor.relationshipKeyPathsForPrefetching = includeSegments ? [\StoredPracticeSession.segments] : []
        let rows = try modelContext.fetch(descriptor)
        var result = rows
            .filter { row in
                if let from, row.startDate < from { return false }
                if let to, row.startDate > to { return false }
                return true
            }
            .map { snapshot(of: $0, includeSegments: includeSegments) }
        if let limit, result.count > limit { result = Array(result.prefix(limit)) }
        return result
    }

    public func deleteSession(id: UUID) async throws {
        guard let row = try fetchSessionRow(id: id) else { return }
        modelContext.delete(row)
        try commit("delete session")
    }

    // MARK: - Statistics

    /// Lightweight projection: dates and durations only, no segment traversal.
    private func allSessionSummaries() throws -> [PracticeSessionSnapshot] {
        let rows = try modelContext.fetch(FetchDescriptor<StoredPracticeSession>())
        return rows.map {
            PracticeSessionSnapshot(
                id: $0.id,
                startDate: $0.startDate,
                endDate: $0.endDate,
                duration: $0.duration,
                activeDuration: $0.activeDuration,
                segmentCount: 0,
                isOpen: $0.isOpen,
                segments: []
            )
        }
    }

    public func statistics(period: StatisticsPeriod, reference: Date, calendar: Calendar) async throws -> PracticeStatistics {
        PracticeAggregator.statistics(sessions: try allSessionSummaries(), period: period, reference: reference, calendar: calendar)
    }

    public func dailySummaries(days: Int, endingOn: Date, calendar: Calendar) async throws -> [PracticeDay] {
        PracticeAggregator.dailySummaries(sessions: try allSessionSummaries(), days: days, endingOn: endingOn, calendar: calendar)
    }

    // MARK: - Tempo

    public func saveTempoSession(_ snapshot: TempoSessionSnapshot) async throws {
        let row = StoredTempoSession(
            id: snapshot.id,
            startDate: snapshot.startDate,
            endDate: snapshot.endDate,
            averageBPM: snapshot.averageBPM,
            minBPM: snapshot.minBPM,
            maxBPM: snapshot.maxBPM,
            stabilityMilliseconds: snapshot.stabilityMilliseconds,
            targetBPM: snapshot.targetBPM,
            errorPercent: snapshot.errorPercent,
            beatCount: snapshot.beatCount
        )
        modelContext.insert(row)
        try commit("save tempo session")
    }

    public func tempoSessions(from: Date?, to: Date?, limit: Int?) async throws -> [TempoSessionSnapshot] {
        var descriptor = FetchDescriptor<StoredTempoSession>(
            sortBy: [SortDescriptor(\StoredTempoSession.startDate, order: .reverse)]
        )
        if let limit { descriptor.fetchLimit = limit }
        let rows = try modelContext.fetch(descriptor)
        return rows
            .filter { row in
                if let from, row.startDate < from { return false }
                if let to, row.startDate > to { return false }
                return true
            }
            .map {
                TempoSessionSnapshot(
                    id: $0.id,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    averageBPM: $0.averageBPM,
                    minBPM: $0.minBPM,
                    maxBPM: $0.maxBPM,
                    stabilityMilliseconds: $0.stabilityMilliseconds,
                    targetBPM: $0.targetBPM,
                    errorPercent: $0.errorPercent,
                    beatCount: $0.beatCount
                )
            }
    }

    // MARK: - Settings

    private func settingsRow() throws -> StoredSettings? {
        var descriptor = FetchDescriptor<StoredSettings>(predicate: #Predicate { $0.id == "default" })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    public func loadSettings() async throws -> AppSettings {
        guard let row = try settingsRow() else { return .default }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: row.payload)
        } catch {
            // A settings blob from an older/newer build must never brick the app.
            Log.store.error("Could not decode stored settings, falling back to defaults: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    public func saveSettings(_ settings: AppSettings) async throws {
        let payload = try JSONEncoder().encode(settings)
        if let row = try settingsRow() {
            row.payload = payload
            row.updatedAt = Date()
        } else {
            modelContext.insert(StoredSettings(payload: payload))
        }
        try commit("save settings")
    }
}

/// `SwiftDataPianoStore` is the production backend, so it must satisfy exactly the same protocol as
/// the JSON fallback. Declaring the conformance explicitly (rather than relying on the methods
/// coincidentally matching) means the compiler catches any divergence between the two backends.
@available(macOS 14.0, iOS 17.0, *)
extension SwiftDataPianoStore: PianoDataStore {}
#endif
