import XCTest
@testable import PianoMonitorKit

/// Verifies the aggregation that the macOS dashboard, the iOS dashboard and `GET /api/statistics`
/// all share. Because there is exactly one implementation, these assertions cover all three.
final class StatisticsTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Builds a closed session on `day` with the given active duration.
    private func session(on day: Date, activeSeconds: Double, wallSeconds: Double? = nil, hour: Int = 20) -> PracticeSessionSnapshot {
        let start = calendar.date(byAdding: .hour, value: hour, to: calendar.startOfDay(for: day))!
        let wall = wallSeconds ?? activeSeconds
        return PracticeSessionSnapshot(
            startDate: start,
            endDate: start.addingTimeInterval(wall),
            duration: wall,
            activeDuration: activeSeconds,
            segmentCount: 1,
            isOpen: false
        )
    }

    // MARK: - Periods

    func testDayStatisticsCountOnlyToday() {
        let today = date(2026, 9, 19)
        let sessions = [
            session(on: today, activeSeconds: 3_600),
            session(on: date(2026, 9, 18), activeSeconds: 7_200),
        ]
        let statistics = PracticeAggregator.statistics(sessions: sessions, period: .day, reference: today, calendar: calendar)
        XCTAssertEqual(statistics.totalActiveDuration, 3_600, accuracy: 0.01)
        XCTAssertEqual(statistics.sessionCount, 1)
    }

    func testWeekStatisticsUseTheCalendarWeekBoundary() throws {
        // 2026-09-19 is a Saturday. This calendar is Gregorian with a UTC time zone and no explicit
        // `firstWeekday`, so the week begins on Sunday 2026-09-13 — the period boundaries come from
        // the user's own calendar rather than a hard-coded Monday.
        let today = date(2026, 9, 19)
        let weekStart = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: today)?.start)
        XCTAssertEqual(calendar.component(.day, from: weekStart), 13, "precondition: week starts Sunday the 13th")

        let sessions = [
            session(on: date(2026, 9, 13), activeSeconds: 1_800), // first day of the week
            session(on: date(2026, 9, 16), activeSeconds: 2_400),
            session(on: today, activeSeconds: 3_000),
            session(on: date(2026, 9, 12), activeSeconds: 9_999), // previous week: excluded
        ]
        let statistics = PracticeAggregator.statistics(sessions: sessions, period: .week, reference: today, calendar: calendar)
        XCTAssertEqual(statistics.totalActiveDuration, 7_200, accuracy: 0.01)
        XCTAssertEqual(statistics.sessionCount, 3)
        XCTAssertEqual(statistics.averageSessionDuration, 2_400, accuracy: 0.01)
        XCTAssertEqual(statistics.longestSessionDuration, 3_000, accuracy: 0.01)
    }

    func testAverageDailyUsesFixedPeriodLength() {
        let today = date(2026, 9, 19)
        let sessions = [session(on: today, activeSeconds: 7_000)]
        let statistics = PracticeAggregator.statistics(sessions: sessions, period: .week, reference: today, calendar: calendar)
        // 7000 s over a 7-day period.
        XCTAssertEqual(statistics.averageDailyDuration, 1_000, accuracy: 0.01)
    }

    func testAllPeriodIgnoresLowerBound() {
        let sessions = [
            session(on: date(2020, 1, 1), activeSeconds: 600),
            session(on: date(2026, 9, 19), activeSeconds: 1_200),
        ]
        let statistics = PracticeAggregator.statistics(sessions: sessions, period: .all, reference: date(2026, 9, 19), calendar: calendar)
        XCTAssertEqual(statistics.totalActiveDuration, 1_800, accuracy: 0.01)
        XCTAssertEqual(statistics.sessionCount, 2)
    }

    // MARK: - Streaks

    func testStreakCountsConsecutiveDaysIncludingToday() {
        let today = date(2026, 9, 19)
        let sessions = (0..<5).map { session(on: calendar.date(byAdding: .day, value: -$0, to: today)!, activeSeconds: 600) }
        XCTAssertEqual(PracticeAggregator.streak(sessions: sessions, reference: today, calendar: calendar), 5)
    }

    func testStreakSurvivesAnUnpractisedToday() {
        // Practised yesterday and the four days before, but not yet today: the streak is intact.
        let today = date(2026, 9, 19)
        let sessions = (1..<5).map { session(on: calendar.date(byAdding: .day, value: -$0, to: today)!, activeSeconds: 600) }
        XCTAssertEqual(PracticeAggregator.streak(sessions: sessions, reference: today, calendar: calendar), 4)
    }

    func testStreakBreaksAfterTwoMissedDays() {
        let today = date(2026, 9, 19)
        let sessions = (2..<6).map { session(on: calendar.date(byAdding: .day, value: -$0, to: today)!, activeSeconds: 600) }
        XCTAssertEqual(PracticeAggregator.streak(sessions: sessions, reference: today, calendar: calendar), 0)
    }

    func testStreakIsZeroWithoutSessions() {
        XCTAssertEqual(PracticeAggregator.streak(sessions: [], reference: date(2026, 9, 19), calendar: calendar), 0)
    }

    // MARK: - Daily breakdown

    func testDailySummariesIncludeEmptyDaysInOrder() throws {
        let today = date(2026, 9, 19)
        let sessions = [
            session(on: today, activeSeconds: 600),
            session(on: calendar.date(byAdding: .day, value: -2, to: today)!, activeSeconds: 1_200),
        ]
        let days = PracticeAggregator.dailySummaries(sessions: sessions, days: 4, endingOn: today, calendar: calendar)
        XCTAssertEqual(days.count, 4, "the chart needs a bar per day, including empty ones")
        let last = try XCTUnwrap(days.last)
        XCTAssertEqual(last.activeDuration, 600, accuracy: 0.01)
        XCTAssertEqual(days[1].activeDuration, 1_200, accuracy: 0.01)
        XCTAssertEqual(days[2].activeDuration, 0)
        // Oldest first.
        XCTAssertLessThan(days.first!.day, days.last!.day)
    }

    func testDailySummariesCountSessionsPerDay() throws {
        let today = date(2026, 9, 19)
        let sessions = [
            session(on: today, activeSeconds: 600, hour: 9),
            session(on: today, activeSeconds: 900, hour: 21),
        ]
        let days = PracticeAggregator.dailySummaries(sessions: sessions, days: 1, endingOn: today, calendar: calendar)
        let first = try XCTUnwrap(days.first)
        XCTAssertEqual(first.sessionCount, 2)
        XCTAssertEqual(first.activeDuration, 1_500, accuracy: 0.01)
    }

    // MARK: - Formatting shared by both apps

    func testDurationFormatting() {
        XCTAssertEqual(DurationFormatter.short(0), "0s")
        XCTAssertEqual(DurationFormatter.short(59), "59s")
        XCTAssertEqual(DurationFormatter.short(3_600), "1h 0m")
        XCTAssertEqual(DurationFormatter.short(5_547), "1h 32m", "the spec's own example")
        XCTAssertEqual(DurationFormatter.short(2_537), "42m 17s")
        XCTAssertEqual(DurationFormatter.clock(2_537), "42:17")
        XCTAssertEqual(DurationFormatter.clock(5_547), "1:32:27")
    }

    func testStatisticsPeriodsParseFromAPIStrings() {
        XCTAssertEqual(StatisticsPeriod(rawValue: "week"), .week)
        XCTAssertEqual(StatisticsPeriod(rawValue: "year"), .year)
        XCTAssertNil(StatisticsPeriod(rawValue: "fortnight"))
    }
}
