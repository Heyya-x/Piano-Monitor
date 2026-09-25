import Foundation
import PianoMonitorKit
import SwiftUI

/// The iOS app's single source of UI state.
///
/// Position in the architecture, per the spec: **viewer, not controller.** It discovers a Mac,
/// fetches JSON over HTTP, caches the most recent good response locally, and renders it. It never
/// writes to the Mac and holds no authoritative data of its own.
@MainActor
public final class PianoMonitorClientModel: ObservableObject {

    public enum ConnectionState: Equatable {
        case searching
        case connected(macName: String)
        case noMacFound
        case disconnected(String)

        public var description: String {
            switch self {
            case .searching: return "Searching…"
            case .connected(let name): return "Connected to \(name)"
            case .noMacFound: return "Mac Not Found"
            case .disconnected(let reason): return reason
            }
        }

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published public private(set) var connection: ConnectionState = .searching
    @Published public private(set) var macs: [DiscoveredMac] = []
    @Published public private(set) var status: APIStatusResponse?
    @Published public private(set) var sessions: [PracticeSessionSnapshot] = []
    @Published public private(set) var statistics = PracticeStatistics.empty
    @Published public private(set) var dailySummaries: [DailyPracticeSummary] = []
    @Published public private(set) var tempoHistory: [TempoSessionSnapshot] = []
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var isOfflineCache = false
    /// Set when the user picks a Mac manually; otherwise the first discovered Mac is used.
    @Published public var preferredMacID: String? {
        didSet { connectToPreferredMac() }
    }

    private let browser = BonjourMacBrowser()
    private var client = PianoAPIClient()
    private var activeBaseURL: URL?
    private var refreshTask: Task<Void, Never>?
    private let cache: LocalCache

    public init(cache: LocalCache = LocalCache()) {
        self.cache = cache
        browser.onUpdate = { [weak self] state in
            Task { @MainActor in self?.handleBrowserState(state) }
        }
    }

    // MARK: - Lifecycle

    public func start() {
        // Show the last known values immediately, so opening the app offline is not an empty screen.
        loadCache()
        browser.start()
        startRefreshLoop()
    }

    public func stop() {
        browser.stop()
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Retries on a slow cadence. The Mac is a background app; the phone simply polls it.
    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval: UInt64 = self?.connection.isConnected == true ? 30 : 8
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    private func handleBrowserState(_ state: BonjourMacBrowser.State) {
        switch state {
        case .searching:
            macs = []
            if !connection.isConnected, case .disconnected = connection {} else if !connection.isConnected {
                connection = .searching
            }
        case .found(let found):
            macs = found.sorted { $0.name < $1.name }
            if activeBaseURL == nil {
                connectToPreferredMac()
            }
            if activeBaseURL == nil, macs.isEmpty {
                connection = .noMacFound
            }
        case .failed(let message):
            connection = .disconnected(message)
        case .idle:
            break
        }
    }

    /// Chooses which Mac to talk to: the user's pick when set, otherwise the first resolved one.
    private func connectToPreferredMac() {
        let candidate: DiscoveredMac?
        if let preferredMacID, let match = macs.first(where: { $0.id == preferredMacID }) {
            candidate = match
        } else {
            candidate = macs.first { $0.baseURL != nil } ?? macs.first
        }
        guard let candidate, let baseURL = candidate.baseURL else {
            activeBaseURL = nil
            if macs.isEmpty { connection = .noMacFound }
            return
        }
        guard activeBaseURL != baseURL else { return }
        activeBaseURL = baseURL
        connection = .connected(macName: candidate.name)
        Task { await refresh() }
    }

    // MARK: - Fetching

    public func refresh() async {
        guard let baseURL = activeBaseURL else {
            if macs.isEmpty { connection = .noMacFound }
            return
        }
        do {
            // One status call gates the rest: if the Mac is unreachable there is no point firing
            // three more requests that will each time out.
            let status = try await client.status(from: baseURL)
            self.status = status
            connection = .connected(macName: macs.first { $0.baseURL == baseURL }?.name ?? "Mac")

            async let sessionsTask = client.sessions(from: baseURL)
            async let statisticsTask = client.statistics(from: baseURL, period: .week)
            async let tempoTask = client.tempo(from: baseURL)

            let sessionsResponse = try? await sessionsTask
            let statisticsResponse = try? await statisticsTask
            let tempoResponse = try? await tempoTask

            if let sessionsResponse { sessions = sessionsResponse.sessions }
            if let statisticsResponse {
                statistics = statisticsResponse.statistics
                dailySummaries = statisticsResponse.days
            }
            if let tempoResponse { tempoHistory = tempoResponse.history }

            lastUpdated = Date()
            isOfflineCache = false
            saveCache()
        } catch {
            // Keep whatever was last shown, and say plainly that it is stale.
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connection = .disconnected(reason)
            isOfflineCache = lastUpdated != nil
        }
    }

    // MARK: - Local cache

    private func saveCache() {
        cache.save(CachedSnapshot(
            status: status,
            sessions: sessions,
            statistics: statistics,
            dailySummaries: dailySummaries,
            tempoHistory: tempoHistory,
            savedAt: Date()
        ))
    }

    private func loadCache() {
        guard let snapshot = cache.load() else { return }
        status = snapshot.status
        sessions = snapshot.sessions
        statistics = snapshot.statistics
        dailySummaries = snapshot.dailySummaries
        tempoHistory = snapshot.tempoHistory
        lastUpdated = snapshot.savedAt
        isOfflineCache = true
    }

    public func clearCache() {
        cache.clear()
        status = nil
        sessions = []
        statistics = .empty
        dailySummaries = []
        tempoHistory = []
        lastUpdated = nil
        isOfflineCache = false
    }

    // MARK: - Derived values for the UI

    /// Replaces the API token and reconnects, so a token change takes effect immediately.
    public func updateToken(_ token: String) {
        client = PianoAPIClient(token: token.isEmpty ? nil : token)
        Task { await refresh() }
    }

    /// Fetches statistics for a specific period without touching the model's cached week view.
    /// Used by the History screen, which lets the user choose its own period.
    public func statistics(for period: StatisticsPeriod) async -> (statistics: PracticeStatistics, days: [DailyPracticeSummary]) {
        guard let baseURL = activeBaseURL else {
            return (.empty, [])
        }
        do {
            let response = try await client.statistics(from: baseURL, period: period)
            return (response.statistics, response.days)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connection = .disconnected(reason)
            return (.empty, [])
        }
    }

    /// The currently connected Mac's base URL, exposed for screens that need a one-off fetch.
    public func activeBaseURLForHistory() -> URL? { activeBaseURL }

    /// Monday-first week for the chart, using the user's calendar.
    public var weekChartData: [DailyPracticeSummary] {
        Array(dailySummaries.suffix(7))
    }

    public var todayDuration: Double {
        status?.todayActiveDuration ?? 0
    }

    /// Sessions grouped by day, newest first — the shape the Sessions screen renders.
    public var sessionsByDay: [(day: Date, sessions: [PracticeSessionSnapshot])] {
        let calendar = Calendar.current
        var buckets: [Date: [PracticeSessionSnapshot]] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.startDate)
            buckets[day, default: []].append(session)
        }
        return buckets
            .map { (day: $0.key, sessions: $0.value.sorted { $0.startDate > $1.startDate }) }
            .sorted { $0.day > $1.day }
    }
}

/// The cached payload. Persisted as JSON in Application Support so the viewer has something to show
/// before the first successful fetch.
public struct CachedSnapshot: Codable, Sendable {
    public var status: APIStatusResponse?
    public var sessions: [PracticeSessionSnapshot]
    public var statistics: PracticeStatistics
    public var dailySummaries: [DailyPracticeSummary]
    public var tempoHistory: [TempoSessionSnapshot]
    public var savedAt: Date

    public init(
        status: APIStatusResponse?,
        sessions: [PracticeSessionSnapshot],
        statistics: PracticeStatistics,
        dailySummaries: [DailyPracticeSummary],
        tempoHistory: [TempoSessionSnapshot],
        savedAt: Date
    ) {
        self.status = status
        self.sessions = sessions
        self.statistics = statistics
        self.dailySummaries = dailySummaries
        self.tempoHistory = tempoHistory
        self.savedAt = savedAt
    }
}

/// Last-known-good cache on disk.
public struct LocalCache: Sendable {

    private let url: URL

    public init(filename: String = "last-snapshot.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("PianoMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent(filename)
    }

    public func save(_ snapshot: CachedSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // A cache write failure is never worth surfacing: the cache is a convenience.
            Log.ui.error("Could not write the iOS cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func load() -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedSnapshot.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
