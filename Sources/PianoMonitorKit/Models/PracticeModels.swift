import Foundation

/// Public, `Codable` view of a practice segment.
///
/// The app never stores raw audio or writes segments sample-by-sample: a segment is one stretch of
/// continuous playing, and it is written exactly twice (on open and on close).
public struct PracticeSegmentSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    /// Seconds. Kept alongside the dates so the iOS client (and JSON consumers) do not have to
    /// recompute it, and so a partially-open segment can still report elapsed time.
    public var duration: Double
    /// Mean detector confidence across the segment, 0…1.
    public var averageConfidence: Double

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        duration: Double = 0,
        averageConfidence: Double = 0
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.averageConfidence = averageConfidence
    }
}

/// Public, `Codable` view of one practice session.
///
/// `duration` is wall-clock time from first note to last, `activeDuration` excludes the pauses —
/// which is the number the user actually cares about ("39 min" in the spec's example).
public struct PracticeSessionSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startDate: Date
    /// `nil` while the session is still open (a long session in progress, or a paused one).
    public var endDate: Date?
    public var duration: Double
    public var activeDuration: Double
    public var segmentCount: Int
    /// True while the state machine still considers this session open.
    public var isOpen: Bool
    public var segments: [PracticeSegmentSnapshot]

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date? = nil,
        duration: Double = 0,
        activeDuration: Double = 0,
        segmentCount: Int = 0,
        isOpen: Bool = false,
        segments: [PracticeSegmentSnapshot] = []
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.activeDuration = activeDuration
        self.segmentCount = segmentCount
        self.isOpen = isOpen
        self.segments = segments
    }
}

/// Result of one tempo-measurement run.
public struct TempoSessionSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startDate: Date
    public var endDate: Date?
    public var averageBPM: Double
    public var minBPM: Double
    public var maxBPM: Double
    /// Standard deviation of the beat intervals, in milliseconds.
    public var stabilityMilliseconds: Double
    /// The BPM the user dialled into the metronome, when known.
    public var targetBPM: Double?
    /// Measured-minus-target as a percentage.
    public var errorPercent: Double?
    public var beatCount: Int

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date? = nil,
        averageBPM: Double,
        minBPM: Double,
        maxBPM: Double,
        stabilityMilliseconds: Double,
        targetBPM: Double? = nil,
        errorPercent: Double? = nil,
        beatCount: Int = 0
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

/// Aggregated practice time for one calendar day.
public struct DailyPracticeSummary: Codable, Identifiable, Hashable, Sendable {
    /// Start of day in the local calendar.
    public var date: Date
    public var totalActiveDuration: Double
    public var sessionCount: Int
    public var longestSession: Double

    public var id: Date { date }

    public init(date: Date, totalActiveDuration: Double, sessionCount: Int, longestSession: Double) {
        self.date = date
        self.totalActiveDuration = totalActiveDuration
        self.sessionCount = sessionCount
        self.longestSession = longestSession
    }
}

/// The statistics block the iOS dashboard and the menu bar both render.
public struct PracticeStatistics: Codable, Equatable, Sendable {
    public var from: Date?
    public var to: Date?
    public var totalActiveDuration: Double
    public var sessionCount: Int
    public var averageSessionDuration: Double
    public var longestSessionDuration: Double
    /// Consecutive days (ending today or yesterday) with at least one session.
    public var currentStreakDays: Int
    /// Average active time per day across the requested period.
    public var averageDailyDuration: Double

    public init(
        from: Date? = nil,
        to: Date? = nil,
        totalActiveDuration: Double = 0,
        sessionCount: Int = 0,
        averageSessionDuration: Double = 0,
        longestSessionDuration: Double = 0,
        currentStreakDays: Int = 0,
        averageDailyDuration: Double = 0
    ) {
        self.from = from
        self.to = to
        self.totalActiveDuration = totalActiveDuration
        self.sessionCount = sessionCount
        self.averageSessionDuration = averageSessionDuration
        self.longestSessionDuration = longestSessionDuration
        self.currentStreakDays = currentStreakDays
        self.averageDailyDuration = averageDailyDuration
    }

    public static let empty = PracticeStatistics()
}

/// Statistical period accepted by `GET /api/statistics`.
public enum StatisticsPeriod: String, Codable, CaseIterable, Sendable {
    case day
    case week
    case month
    case year
    case all

    /// Inclusive start date for the period, relative to `reference` in `calendar`.
    public func startDate(reference: Date, calendar: Calendar) -> Date? {
        switch self {
        case .day:
            return calendar.startOfDay(for: reference)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: reference)?.start
                ?? calendar.startOfDay(for: reference)
        case .month:
            return calendar.dateInterval(of: .month, for: reference)?.start
                ?? calendar.startOfDay(for: reference)
        case .year:
            return calendar.dateInterval(of: .year, for: reference)?.start
                ?? calendar.startOfDay(for: reference)
        case .all:
            return nil
        }
    }

    /// Number of days in the period, used to compute a per-day average. `nil` for `.all`.
    public func dayCount(reference: Date, calendar: Calendar) -> Int? {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month:
            return calendar.range(of: .day, in: .month, for: reference)?.count
        case .year:
            return calendar.range(of: .day, in: .year, for: reference)?.count
        case .all: return nil
        }
    }
}
