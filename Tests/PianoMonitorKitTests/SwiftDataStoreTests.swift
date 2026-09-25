import XCTest
@testable import PianoMonitorKit

#if canImport(SwiftData)
import SwiftData

/// Persistence tests for the SwiftData backend (macOS 14+/iOS 17+), which is the primary store.
///
/// The suite is skipped on older systems rather than failing, because the app legitimately falls
/// back to `JSONDataStore` there.
@available(macOS 14.0, iOS 17.0, *)
final class SwiftDataStoreTests: XCTestCase {

    private func makeStore() throws -> (SwiftDataPianoStore, ModelContainer) {
        let schema = Schema([
            StoredPracticeSession.self,
            StoredPracticeSegment.self,
            StoredTempoSession.self,
            StoredSettings.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (SwiftDataPianoStore(modelContainer: container), container)
    }

    /// Verifies the app behaves identically on both backends by running the same expectations
    /// against each: the protocol is the contract.
    private func assertSessionLifecycle(_ store: PianoDataStore) async throws {
        let sessionID = UUID()
        let segmentA = UUID()
        let segmentB = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // 7 min playing, pause, 12 min playing: the spec's worked example.
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionOpened(sessionID: sessionID, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: segmentA, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentClosed(
            sessionID: sessionID, segmentID: segmentA,
            at: start.addingTimeInterval(420), confidence: 0.9
        )))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(
            sessionID: sessionID, segmentID: segmentB,
            at: start.addingTimeInterval(540)
        )))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentClosed(
            sessionID: sessionID, segmentID: segmentB,
            at: start.addingTimeInterval(1_260), confidence: 0.8
        )))
        let kept = try await store.recordActivity(ActivityRecord(kind: .sessionClosed(
            sessionID: sessionID, at: start.addingTimeInterval(1_260)
        )))
        XCTAssertTrue(kept)

        let fetched = try await store.session(id: sessionID)
        let session = try XCTUnwrap(fetched)
        XCTAssertEqual(session.activeDuration, 1_140, accuracy: 0.01, "19 min of playing")
        XCTAssertEqual(session.duration, 1_260, accuracy: 0.01, "21 min wall clock")
        XCTAssertEqual(session.segmentCount, 2)
        XCTAssertEqual(session.segments.count, 2)
        XCTAssertEqual(session.segments.map(\.duration).reduce(0, +), 1_140, accuracy: 0.01)

        // Statistics must match the JSON backend's numbers exactly.
        let statistics = try await store.statistics(period: .all, reference: Date())
        XCTAssertEqual(statistics.totalActiveDuration, 1_140, accuracy: 0.01)
        XCTAssertEqual(statistics.sessionCount, 1)
    }

    func testSessionLifecycle() async throws {
        let (store, _) = try makeStore()
        try await assertSessionLifecycle(store)
    }

    func testShortSessionIsDiscarded() async throws {
        let (store, _) = try makeStore()
        let sessionID = UUID()
        let segmentID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionOpened(sessionID: sessionID, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: segmentID, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentClosed(
            sessionID: sessionID, segmentID: segmentID,
            at: start.addingTimeInterval(3), confidence: 0.4
        )))
        let kept = try await store.recordActivity(ActivityRecord(kind: .sessionClosed(
            sessionID: sessionID, at: start.addingTimeInterval(3)
        )))
        XCTAssertFalse(kept)
        let sessions = try await store.sessions(from: nil, to: nil, limit: nil, includeSegments: false)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testSettingsRoundTrip() async throws {
        let (store, _) = try makeStore()
        var settings = AppSettings.default
        settings.inputDeviceUID = "TOP1-UID"
        settings.outputDeviceUID = "Speakers-UID"
        settings.sensitivity = 0.66
        settings.pauseAfterSilenceSeconds = 7
        settings.endSessionAfterSilenceSeconds = 200
        settings.metronomeTargetBPM = 96
        settings.launchAtLogin = true
        try await store.saveSettings(settings)

        let loaded = try await store.loadSettings()
        XCTAssertEqual(loaded, settings)

        // Saving again must update in place, not insert a second row.
        settings.sensitivity = 0.2
        try await store.saveSettings(settings)
        let reloaded = try await store.loadSettings()
        XCTAssertEqual(reloaded.sensitivity, 0.2, accuracy: 0.001)
    }

    func testDefaultSettingsWhenNothingStored() async throws {
        let (store, _) = try makeStore()
        let settings = try await store.loadSettings()
        XCTAssertEqual(settings, AppSettings.default)
    }

    func testTempoSessionsRoundTrip() async throws {
        let (store, _) = try makeStore()
        let snapshot = TempoSessionSnapshot(
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_600),
            averageBPM: 99.2,
            minBPM: 98.1,
            maxBPM: 100.4,
            stabilityMilliseconds: 11.5,
            targetBPM: 100,
            errorPercent: -0.8,
            beatCount: 96
        )
        try await store.saveTempoSession(snapshot)
        let history = try await store.tempoSessions(from: nil, to: nil, limit: nil)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.averageBPM ?? 0, 99.2, accuracy: 0.001)
        XCTAssertEqual(history.first?.errorPercent ?? 0, -0.8, accuracy: 0.001)
    }

    func testDailySummariesAndStreak() async throws {
        let (store, _) = try makeStore()
        // Build the sessions on consecutive *local* days, which is how the app records them.
        //
        // Every reference is derived from one fixed anchor rather than from repeated `Date()` calls.
        // The store buckets by the calendar it is handed, so a session stamped at 20:00 local and a
        // reference of "now" can land on different days if the two are captured either side of
        // midnight — which made this test fail at exactly that moment rather than catching a real
        // defect.
        //
        // The calendar is explicit — Gregorian with `firstWeekday = 2` (Monday) — rather than
        // `Calendar.current`. The weekly period boundary comes from `firstWeekday`, so a test that
        // assumes Sunday but runs under a Monday-first locale (or vice versa) compares against the
        // wrong window; and the default is locale-dependent, which makes it non-deterministic.
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let anchor = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3_600) // noon today

        for offset in 0..<3 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -offset, to: anchor))
            let start = calendar.startOfDay(for: day).addingTimeInterval(20 * 3_600) // 20:00 local
            let sessionID = UUID()
            let segmentID = UUID()
            _ = try await store.recordActivity(ActivityRecord(kind: .sessionOpened(sessionID: sessionID, at: start)))
            _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: segmentID, at: start)))
            _ = try await store.recordActivity(ActivityRecord(kind: .segmentClosed(
                sessionID: sessionID, segmentID: segmentID,
                at: start.addingTimeInterval(600 + Double(offset) * 60), confidence: 0.9
            )))
            _ = try await store.recordActivity(ActivityRecord(kind: .sessionClosed(
                sessionID: sessionID, at: start.addingTimeInterval(600 + Double(offset) * 60)
            )))
        }

        let days = try await store.dailySummaries(days: 7, endingOn: anchor, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last?.sessionCount, 1, "the most recent session should land on the last day")
        // All three sessions must be on distinct days, not stacked onto one by a time-zone shift.
        XCTAssertEqual(days.filter { $0.sessionCount > 0 }.count, 3)

        let statistics = try await store.statistics(period: .week, reference: anchor, calendar: calendar)
        // Every session created above must fall inside the week beginning on this calendar's own
        // week boundary, which is what the aggregator uses.
        let weekStart = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: anchor)?.start)
        let expectedInWeek = (0..<3).filter { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: anchor)!
            return calendar.startOfDay(for: day) >= weekStart
        }.count
        XCTAssertEqual(statistics.sessionCount, expectedInWeek)
        XCTAssertEqual(statistics.currentStreakDays, 3, "all three consecutive days form one streak")
    }

    func testSessionQueriesRespectRangeAndLimit() async throws {
        let (store, _) = try makeStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<5 {
            let start = base.addingTimeInterval(Double(index) * 86_400)
            let sessionID = UUID()
            let segmentID = UUID()
            _ = try await store.recordActivity(ActivityRecord(kind: .sessionOpened(sessionID: sessionID, at: start)))
            _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: segmentID, at: start)))
            _ = try await store.recordActivity(ActivityRecord(kind: .segmentClosed(
                sessionID: sessionID, segmentID: segmentID,
                at: start.addingTimeInterval(300), confidence: 0.9
            )))
            _ = try await store.recordActivity(ActivityRecord(kind: .sessionClosed(sessionID: sessionID, at: start.addingTimeInterval(300))))
        }

        let all = try await store.sessions(from: nil, to: nil, limit: nil, includeSegments: false)
        XCTAssertEqual(all.count, 5)
        XCTAssertTrue(all[0].startDate > all[4].startDate, "sessions come back newest first")

        let limited = try await store.sessions(from: nil, to: nil, limit: 2, includeSegments: false)
        XCTAssertEqual(limited.count, 2)

        let ranged = try await store.sessions(
            from: base.addingTimeInterval(86_400), to: base.addingTimeInterval(3 * 86_400),
            limit: nil, includeSegments: false
        )
        XCTAssertEqual(ranged.count, 3)
    }
}
#endif
