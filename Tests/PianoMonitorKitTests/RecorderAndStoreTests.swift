import XCTest
@testable import PianoMonitorKit

/// In-memory store used to observe exactly what the recorder persists, in order.
private final class SpyStore: PianoDataStore {
    nonisolated let kind = "spy"

    private let lock = NSLock()
    private var records: [ActivityRecord] = []

    func session(id: UUID) async throws -> PracticeSessionSnapshot? { nil }

    @discardableResult
    func recordActivity(_ record: ActivityRecord) async throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        records.append(record)
        return true
    }

    func sessions(from: Date?, to: Date?, limit: Int?, includeSegments: Bool) async throws -> [PracticeSessionSnapshot] { [] }
    func deleteSession(id: UUID) async throws {}
    func statistics(period: StatisticsPeriod, reference: Date, calendar: Calendar) async throws -> PracticeStatistics { .empty }
    func dailySummaries(days: Int, endingOn: Date, calendar: Calendar) async throws -> [PracticeDay] { [] }
    func saveTempoSession(_ snapshot: TempoSessionSnapshot) async throws {}
    func tempoSessions(from: Date?, to: Date?, limit: Int?) async throws -> [TempoSessionSnapshot] { [] }
    func loadSettings() async throws -> AppSettings { .default }
    func saveSettings(_ settings: AppSettings) async throws {}

    var kinds: [String] {
        lock.lock(); defer { lock.unlock() }
        return records.map { record in
            switch record.kind {
            case .sessionOpened: return "sessionOpened"
            case .segmentOpened: return "segmentOpened"
            case .segmentClosed: return "segmentClosed"
            case .sessionClosed: return "sessionClosed"
            }
        }
    }
}

/// Verifies the recorder writes on *state changes only* and produces a well-formed session.
///
/// The write count matters as much as the shape: the spec's power requirement depends on practice
/// time producing a handful of writes per session rather than one per audio frame.
final class RecorderAndStoreTests: XCTestCase {

    private func result(_ playing: Bool, at time: Double) -> DetectionResult {
        DetectionResult(
            isPlaying: playing,
            confidence: playing ? 0.9 : 0,
            onset: playing,
            rms: playing ? 0.05 : 0.0001,
            rmsDB: playing ? -26 : -80,
            peakDB: playing ? -20 : -75,
            noiseFloorDB: -70,
            timestamp: time,
            features: DetectionFeatures()
        )
    }

    private func drain(_ recorder: PracticeSessionRecorder) {
        // The recorder processes asynchronously on its own queue; give it a moment to settle.
        let expectation = XCTestExpectation(description: "recorder drained")
        recorder.process(result(false, at: 0)) // no-op frame to enqueue after the rest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        _ = XCTWaiter.wait(for: [expectation], timeout: 3)
    }

    func testSessionProducesWellFormedActivitySequence() {
        var configuration = DetectorConfiguration.default
        configuration.pauseAfterSilenceSeconds = 5
        configuration.endSessionAfterSilenceSeconds = 20
        configuration.confirmPlayingSeconds = 0.5

        let store = SpyStore()
        let recorder = PracticeSessionRecorder(store: store, configuration: configuration)

        // Play 10 s, break 8 s (long enough to pause), play 10 s, then go quiet for 30 s.
        var time = 0.0
        let block = 1_024.0 / 44_100
        while time < 10 { recorder.process(result(true, at: time)); time += block }
        while time < 18 { recorder.process(result(false, at: time)); time += block }
        while time < 28 { recorder.process(result(true, at: time)); time += block }
        while time < 58 { recorder.process(result(false, at: time)); time += block }
        drain(recorder)

        XCTAssertEqual(
            store.kinds,
            ["sessionOpened", "segmentOpened", "segmentClosed", "segmentOpened", "segmentClosed", "sessionClosed"],
            "expected exactly one session containing two segments"
        )
    }

    func testWriteCountIsProportionalToTransitionsNotFrames() {
        var configuration = DetectorConfiguration.default
        configuration.pauseAfterSilenceSeconds = 5
        configuration.endSessionAfterSilenceSeconds = 10
        configuration.confirmPlayingSeconds = 0.5

        let store = SpyStore()
        let recorder = PracticeSessionRecorder(store: store, configuration: configuration)

        // ~430 audio blocks of continuous playing (10 s).
        var time = 0.0
        let block = 1_024.0 / 44_100
        var frames = 0
        while time < 10 { recorder.process(result(true, at: time)); time += block; frames += 1 }
        while time < 30 { recorder.process(result(false, at: time)); time += block; frames += 1 }
        drain(recorder)

        XCTAssertGreaterThan(frames, 800, "the test must actually push a lot of frames")
        XCTAssertLessThanOrEqual(store.kinds.count, 5, "a session must cost a handful of writes, not one per frame")
    }

    func testShortSessionIsDiscarded() {
        var configuration = DetectorConfiguration.default
        configuration.pauseAfterSilenceSeconds = 2
        configuration.endSessionAfterSilenceSeconds = 5
        configuration.confirmPlayingSeconds = 0.5
        configuration.minimumSessionActiveSeconds = 30

        let store = SpyStore()
        let recorder = PracticeSessionRecorder(store: store, configuration: configuration)
        var time = 0.0
        let block = 1_024.0 / 44_100
        // Only 5 s of playing, below the 30 s minimum: a session is opened, then closed, and the
        // *store* decides to discard it. The recorder still emits the closing record.
        while time < 5 { recorder.process(result(true, at: time)); time += block }
        while time < 20 { recorder.process(result(false, at: time)); time += block }
        drain(recorder)

        XCTAssertTrue(store.kinds.contains("sessionClosed"))
        XCTAssertLessThan(store.kinds.filter { $0 == "sessionOpened" }.count, 2)
    }
}

/// Persistence tests for the JSON store, which is also the fallback on macOS 10.15–13.
final class JSONDataStoreTests: XCTestCase {

    private func makeStore() async throws -> (JSONDataStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PianoMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = JSONDataStore(directory: directory)
        await store.load()
        return (store, directory)
    }

    func testSessionLifecycleRoundTripsToDisk() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = UUID()
        let segmentID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionOpened(sessionID: sessionID, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: segmentID, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentClosed(
            sessionID: sessionID, segmentID: segmentID,
            at: start.addingTimeInterval(600), confidence: 0.8
        )))
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionClosed(sessionID: sessionID, at: start.addingTimeInterval(600))))

        // Reload from disk into a fresh instance: the data must survive.
        let reloaded = JSONDataStore(directory: directory)
        await reloaded.load()
        let sessions = try await reloaded.sessions(from: nil, to: nil, limit: nil, includeSegments: true)

        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, sessionID)
        XCTAssertEqual(session.activeDuration, 600, accuracy: 0.01)
        XCTAssertEqual(session.duration, 600, accuracy: 0.01)
        XCTAssertEqual(session.segmentCount, 1)
        XCTAssertEqual(session.segments.first?.id, segmentID)
        XCTAssertFalse(session.isOpen)
    }

    func testSegmentsAndPausesProduceActiveVersusWallClockDifference() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // 7 min playing, 2 min pause, 12 min playing => 19 min active inside a 21 min session.
        let layout: [(Double, Double)] = [(0, 420), (540, 720)]
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionOpened(sessionID: sessionID, at: start)))
        for (offset, length) in layout {
            let segmentID = UUID()
            let segmentStart = start.addingTimeInterval(offset)
            _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: segmentID, at: segmentStart)))
            _ = try await store.recordActivity(ActivityRecord(kind: .segmentClosed(
                sessionID: sessionID, segmentID: segmentID,
                at: segmentStart.addingTimeInterval(length), confidence: 0.9
            )))
        }
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionClosed(sessionID: sessionID, at: start.addingTimeInterval(1_260))))

        let fetched = try await store.session(id: sessionID)
        let session = try XCTUnwrap(fetched)
        XCTAssertEqual(session.activeDuration, 1_140, accuracy: 0.01, "19 min of actual playing")
        XCTAssertEqual(session.duration, 1_260, accuracy: 0.01, "21 min of wall clock")
        XCTAssertEqual(session.segmentCount, 2)
    }

    func testShortSessionIsNotPersisted() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionOpened(sessionID: sessionID, at: start)))
        let segmentID = UUID()
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: segmentID, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentClosed(
            sessionID: sessionID, segmentID: segmentID,
            at: start.addingTimeInterval(2), confidence: 0.5
        )))
        let kept = try await store.recordActivity(ActivityRecord(kind: .sessionClosed(sessionID: sessionID, at: start.addingTimeInterval(2))))

        XCTAssertFalse(kept, "a 2-second session must be discarded")
        let remaining = try await store.sessions(from: nil, to: nil, limit: nil, includeSegments: false)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSettingsRoundTrip() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = AppSettings.default
        settings.inputDeviceUID = "TOP1-UID"
        settings.outputDeviceUID = "Speakers-UID"
        settings.sensitivity = 0.72
        settings.pauseAfterSilenceSeconds = 6
        settings.endSessionAfterSilenceSeconds = 240
        settings.metronomeTargetBPM = 108
        settings.launchAtLogin = true
        try await store.saveSettings(settings)

        let reloaded = JSONDataStore(directory: directory)
        await reloaded.load()
        let loaded = try await reloaded.loadSettings()
        XCTAssertEqual(loaded, settings)
    }

    func testSettingsProduceConsistentDetectorConfiguration() {
        var settings = AppSettings.default
        settings.sensitivity = 0.0
        let leastSensitive = settings.detectorConfiguration()
        settings.sensitivity = 1.0
        let mostSensitive = settings.detectorConfiguration()

        XCTAssertLessThan(
            leastSensitive.absoluteRMSFloorDB,
            mostSensitive.absoluteRMSFloorDB,
            "raising sensitivity must lower the absolute gate"
        )
        XCTAssertTrue(mostSensitive.validationIssues().isEmpty, "derived configuration must be self-consistent")
        XCTAssertTrue(leastSensitive.validationIssues().isEmpty)
    }

    func testCorruptedFileFallsBackToBackup() async throws {
        let (store, directory) = try await makeStore()
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionOpened(sessionID: sessionID, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: UUID(), at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionClosed(sessionID: sessionID, at: start.addingTimeInterval(300))))

        // A second load creates the `.bak` copy; then simulate a torn write.
        let reloaded = JSONDataStore(directory: directory)
        await reloaded.load()
        let sessionsURL = directory.appendingPathComponent("sessions.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionsURL.appendingPathExtension("bak").path))
        try Data("{ this is not json".utf8).write(to: sessionsURL)

        let recovered = JSONDataStore(directory: directory)
        await recovered.load()
        let sessions = try await recovered.sessions(from: nil, to: nil, limit: nil, includeSegments: false)
        XCTAssertEqual(sessions.count, 1, "the backup copy should have been used")
    }
}
