import Foundation

/// One day of practice, plus how many consecutive days lead up to it.
public struct PracticeDay: Codable, Identifiable, Hashable, Sendable {
    public var day: Date
    public var activeDuration: Double
    public var duration: Double
    public var sessionCount: Int

    public var id: Date { day }

    public init(day: Date, activeDuration: Double, duration: Double, sessionCount: Int) {
        self.day = day
        self.activeDuration = activeDuration
        self.duration = duration
        self.sessionCount = sessionCount
    }
}

/// A slice of live activity handed from the session recorder to the store.
///
/// The recorder calls this on state *changes* only (session open, segment open, segment close,
/// session close) — never per audio frame. That is what keeps the persistence layer off the
/// power budget.
public struct ActivityRecord: Sendable {
    public enum Kind: Sendable {
        case sessionOpened(sessionID: UUID, at: Date)
        case segmentOpened(sessionID: UUID, segmentID: UUID, at: Date)
        case segmentClosed(sessionID: UUID, segmentID: UUID, at: Date, confidence: Double)
        case sessionClosed(sessionID: UUID, at: Date)
    }

    public let kind: Kind
    public let timestamp: Date

    public init(kind: Kind, timestamp: Date = Date()) {
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// The persistence interface. Deliberately storage-agnostic so the app can run on
/// SwiftData (macOS 14+/iOS 17+) *or* the JSON fallback (Catalina), and so tests can run without
/// touching disk.
///
/// Everything is value-typed in and value-typed out: no ORM objects leak into the UI. That is what
/// lets the menu bar, the dashboard and the HTTP API all read the same snapshots.
public protocol PianoDataStore: AnyObject, Sendable {
    /// Human-readable backend name, shown in Settings → Diagnostics.
    var kind: String { get }

    // Sessions
    func session(id: UUID) async throws -> PracticeSessionSnapshot?
    /// Returns `false` when the session was filtered out as too short to be worth keeping.
    @discardableResult
    func recordActivity(_ record: ActivityRecord) async throws -> Bool
    /// Sessions whose start date falls inside the range, newest first.
    func sessions(from: Date?, to: Date?, limit: Int?, includeSegments: Bool) async throws -> [PracticeSessionSnapshot]
    func deleteSession(id: UUID) async throws

    // Statistics
    //
    // `calendar` is a parameter rather than an implicit `Calendar.current` so that "which day did
    // this session belong to" is always decided by the caller. Mixing time zones between where a
    // session was recorded and where it is bucketed silently shifts practice onto the wrong day.
    func statistics(period: StatisticsPeriod, reference: Date, calendar: Calendar) async throws -> PracticeStatistics
    func dailySummaries(days: Int, endingOn: Date, calendar: Calendar) async throws -> [PracticeDay]

    // Tempo
    func saveTempoSession(_ snapshot: TempoSessionSnapshot) async throws
    func tempoSessions(from: Date?, to: Date?, limit: Int?) async throws -> [TempoSessionSnapshot]

    // Settings
    func loadSettings() async throws -> AppSettings
    func saveSettings(_ settings: AppSettings) async throws
}

public extension PianoDataStore {
    func sessions(from: Date? = nil, to: Date? = nil, limit: Int? = nil) async throws -> [PracticeSessionSnapshot] {
        try await sessions(from: from, to: to, limit: limit, includeSegments: true)
    }

    func statistics(period: StatisticsPeriod) async throws -> PracticeStatistics {
        try await statistics(period: period, reference: Date(), calendar: .current)
    }

    func statistics(period: StatisticsPeriod, reference: Date) async throws -> PracticeStatistics {
        try await statistics(period: period, reference: reference, calendar: .current)
    }

    func dailySummaries(days: Int, endingOn: Date) async throws -> [PracticeDay] {
        try await dailySummaries(days: days, endingOn: endingOn, calendar: .current)
    }
}

/// Errors surfaced to the UI when persistence fails. The spec requires that SwiftData problems are
/// caught and reported rather than crashing the app.
public enum StoreError: LocalizedError {
    case notFound(String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): return "\(what) not found"
        case .underlying(let message): return message
        }
    }
}

/// Pure functions that turn session snapshots into the aggregates the UI and API expose.
///
/// Kept free of any storage dependency so the exact same numbers appear in the menu bar, the
/// dashboard, and `GET /api/statistics` — and so they are trivially unit-testable.
public enum PracticeAggregator {

    public static func statistics(
        sessions: [PracticeSessionSnapshot],
        period: StatisticsPeriod,
        reference: Date,
        calendar: Calendar = .current
    ) -> PracticeStatistics {
        let from = period.startDate(reference: reference, calendar: calendar)
        let relevant = sessions.filter { session in
            guard let from else { return true }
            return session.startDate >= from
        }
        .filter { !$0.isOpen || $0.activeDuration > 0 }

        let total = relevant.reduce(0) { $0 + $1.activeDuration }
        let longest = relevant.map(\.activeDuration).max() ?? 0
        let average = relevant.isEmpty ? 0 : total / Double(relevant.count)
        let dayCount = period.dayCount(reference: reference, calendar: calendar)
        let averageDaily = dayCount.map { total / Double($0) } ?? 0

        return PracticeStatistics(
            from: from,
            to: reference,
            totalActiveDuration: total,
            sessionCount: relevant.count,
            averageSessionDuration: average,
            longestSessionDuration: longest,
            currentStreakDays: streak(sessions: sessions, reference: reference, calendar: calendar),
            averageDailyDuration: averageDaily
        )
    }

    /// Consecutive practice days ending today (or yesterday, so a streak is not "lost" until a full
    /// day has been skipped).
    public static func streak(
        sessions: [PracticeSessionSnapshot],
        reference: Date,
        calendar: Calendar = .current
    ) -> Int {
        let days = Set(sessions.map { calendar.startOfDay(for: $0.startDate) })
        guard !days.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: reference)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }

        var cursor: Date
        if days.contains(today) {
            cursor = today
        } else if days.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// One entry per day, oldest first, including days with no practice (so charts show real gaps).
    public static func dailySummaries(
        sessions: [PracticeSessionSnapshot],
        days: Int,
        endingOn reference: Date,
        calendar: Calendar = .current
    ) -> [PracticeDay] {
        let end = calendar.startOfDay(for: reference)
        var buckets: [Date: [PracticeSessionSnapshot]] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startDate)
            buckets[day, default: []].append(session)
        }

        var result: [PracticeDay] = []
        result.reserveCapacity(max(0, days))
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            let sessionsForDay = buckets[day] ?? []
            result.append(PracticeDay(
                day: day,
                activeDuration: sessionsForDay.reduce(0) { $0 + $1.activeDuration },
                duration: sessionsForDay.reduce(0) { $0 + $1.duration },
                sessionCount: sessionsForDay.count
            ))
        }
        return result
    }
}

/// Duration formatting shared by the macOS and iOS UIs, so both show `1h 32m` identically.
public enum DurationFormatter {
    /// `1h 32m`, `42m 17s`, `9s`, `0s`.
    public static func short(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    /// `1:32:07` style, for the live "current session" readout where seconds matter.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
