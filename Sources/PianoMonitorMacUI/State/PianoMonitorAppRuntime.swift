#if canImport(ServiceManagement)
import ServiceManagement
#endif
import Foundation
import PianoMonitorKit
import SwiftUI

/// The composition root for the macOS app.
///
/// It owns the store (SwiftData where available, JSON otherwise), the `PianoMonitorService`, login
/// item registration, and the UI-facing observable state. Nothing else in the UI layer constructs
/// these, so there is exactly one place that decides how the app is wired.
@MainActor
public final class PianoMonitorAppRuntime: ObservableObject {

    @Published public private(set) var service: PianoMonitorService?
    /// Mirrors the throttled service status so SwiftUI can observe it.
    @Published public private(set) var status = LiveStatus.initial
    @Published public private(set) var startupError: String?
    /// Which persistence backend was selected. Surfaced in Settings → Diagnostics.
    @Published public private(set) var storeKind: String = "starting"

    private var observerToken: UUID?
    private let loginItem = LoginItemController()

    public init() {}

    // MARK: - Lifecycle

    public func start() async {
        guard service == nil else { return }

        let store: PianoDataStore
        do {
            store = try Self.makeStore()
        } catch {
            // A failure to open the primary store must not stop the app: fall back to JSON so the
            // user keeps recording practice time even if SwiftData is broken.
            Log.store.error("SwiftData unavailable, falling back to JSON: \(error.localizedDescription, privacy: .public)")
            let fallback = JSONDataStore(directory: JSONDataStore.defaultDirectory())
            await fallback.load()
            store = fallback
            startupError = "Using JSON storage because SwiftData could not be opened: \(error.localizedDescription)"
        }
        storeKind = store.kind

        let service = PianoMonitorService(store: store)
        self.service = service
        observerToken = service.addObserver { [weak self] status in
            Task { @MainActor in
                self?.status = status
            }
        }

        // Keep launch-at-login in sync with the persisted preference.
        let settings = await service.settingsSnapshot()
        loginItem.apply(enabled: settings.launchAtLogin)

        await service.start()
        if let error = service.lastError {
            startupError = error
        }
    }

    public func stop() async {
        guard let service else { return }
        if let observerToken {
            service.removeObserver(observerToken)
            self.observerToken = nil
        }
        await service.stop()
        self.service = nil
    }

    /// Opens the primary store, preferring SwiftData.
    private static func makeStore() throws -> PianoDataStore {
        #if canImport(SwiftData)
        if #available(macOS 14.0, *) {
            do {
                let container = try SwiftDataPianoStore.makeContainer()
                return SwiftDataPianoStore(modelContainer: container)
            } catch {
                Log.store.error("SwiftData container failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        #endif
        // macOS 10.15 – 13: JSON only. The app is fully functional, just without SwiftData.
        let fallback = JSONDataStore(directory: JSONDataStore.defaultDirectory())
        Task { await fallback.load() }
        return SynchronousJSONStoreProxy(store: fallback)
    }

    // MARK: - Settings

    public func update(settings: AppSettings) async {
        guard let service else { return }
        // Launch-at-login is a system-level side effect, so apply it before persisting: if the user
        // denies it, the stored preference would otherwise claim something untrue.
        if settings.launchAtLogin != service.settings.launchAtLogin {
            loginItem.apply(enabled: settings.launchAtLogin)
        }
        await service.update(settings: settings)
    }

    public var launchAtLoginDescription: String { loginItem.statusDescription }

    // MARK: - Analysis profile

    /// Called by screens that need a richer analysis profile (the Tempo Analyzer). Everything else
    /// leaves the app in eco mode.
    public func setAnalysisMode(_ mode: AnalysisMode) {
        service?.setAnalysisMode(mode)
    }

    // MARK: - Statistics reads

    public func sessions(limit: Int = 200) async -> [PracticeSessionSnapshot] {
        guard let service else { return [] }
        do {
            return try await service.store.sessions(from: nil, to: nil, limit: limit, includeSegments: true)
        } catch {
            Log.store.error("Could not load sessions: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func dailySummaries(days: Int) async -> [PracticeDay] {
        guard let service else { return [] }
        do {
            return try await service.store.dailySummaries(days: days, endingOn: Date())
        } catch {
            Log.store.error("Could not load daily summaries: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func statistics(period: StatisticsPeriod) async -> PracticeStatistics {
        guard let service else { return .empty }
        do {
            return try await service.store.statistics(period: period, reference: Date())
        } catch {
            Log.store.error("Could not load statistics: \(error.localizedDescription, privacy: .public)")
            return .empty
        }
    }

    public func tempoHistory(limit: Int = 50) async -> [TempoSessionSnapshot] {
        guard let service else { return [] }
        return (try? await service.store.tempoSessions(from: nil, to: nil, limit: limit)) ?? []
    }
}

/// Wraps a `JSONDataStore` created on the Catalina path, where the store cannot be loaded
/// asynchronously before first use.
///
/// On macOS 10.15–13 `makeStore()` cannot `await`, so loading is kicked off in a task; this proxy
/// forwards everything and performs the load lazily, once, before the first access.
private final class SynchronousJSONStoreProxy: PianoDataStore, @unchecked Sendable {
    nonisolated let kind: String

    private let store: JSONDataStore
    private let loadTask: Task<Void, Never>

    init(store: JSONDataStore) {
        self.store = store
        self.kind = store.kind
        self.loadTask = Task { await store.load() }
    }

    func session(id: UUID) async throws -> PracticeSessionSnapshot? {
        await loadTask.value
        return try await store.session(id: id)
    }

    @discardableResult
    func recordActivity(_ record: ActivityRecord) async throws -> Bool {
        await loadTask.value
        return try await store.recordActivity(record)
    }

    func sessions(from: Date?, to: Date?, limit: Int?, includeSegments: Bool) async throws -> [PracticeSessionSnapshot] {
        await loadTask.value
        return try await store.sessions(from: from, to: to, limit: limit, includeSegments: includeSegments)
    }

    func deleteSession(id: UUID) async throws {
        await loadTask.value
        try await store.deleteSession(id: id)
    }

    func statistics(period: StatisticsPeriod, reference: Date, calendar: Calendar) async throws -> PracticeStatistics {
        await loadTask.value
        return try await store.statistics(period: period, reference: reference, calendar: calendar)
    }

    func dailySummaries(days: Int, endingOn: Date, calendar: Calendar) async throws -> [PracticeDay] {
        await loadTask.value
        return try await store.dailySummaries(days: days, endingOn: endingOn, calendar: calendar)
    }

    func saveTempoSession(_ snapshot: TempoSessionSnapshot) async throws {
        await loadTask.value
        try await store.saveTempoSession(snapshot)
    }

    func tempoSessions(from: Date?, to: Date?, limit: Int?) async throws -> [TempoSessionSnapshot] {
        await loadTask.value
        return try await store.tempoSessions(from: from, to: to, limit: limit)
    }

    func loadSettings() async throws -> AppSettings {
        await loadTask.value
        return try await store.loadSettings()
    }

    func saveSettings(_ settings: AppSettings) async throws {
        await loadTask.value
        try await store.saveSettings(settings)
    }
}

/// Registers the app as a login item.
///
/// Uses `SMAppService` on macOS 13+ (the supported API) and falls back to the deprecated
/// `LSSharedFileList` mechanism on Catalina–Ventura, so "Launch at Login" works everywhere the app
/// runs instead of silently doing nothing.
public final class LoginItemController {

    public init() {}

    public func apply(enabled: Bool) {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                Log.ui.error("Could not \(enabled ? "enable" : "disable", privacy: .public) launch at login: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        #endif
        applyLegacy(enabled: enabled)
    }

    public var statusDescription: String {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "Enabled"
            case .notRegistered: return "Not registered"
            case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items"
            case .notFound: return "Login item not found (is the app in /Applications?)"
            @unknown default: return "Unknown"
            }
        }
        #endif
        return isLegacyEnabled() ? "Enabled" : "Not registered"
    }

    // MARK: - Legacy path (macOS 10.15 – 12)

    private func applyLegacy(enabled: Bool) {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let launchAgents = library.appendingPathComponent("LaunchAgents", isDirectory: true)
        let plistURL = launchAgents.appendingPathComponent("com.pianomonitor.app.plist")
        do {
            try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
            if enabled {
                let executable = Bundle.main.executablePath ?? ""
                let payload: [String: Any] = [
                    "Label": "com.pianomonitor.app",
                    "ProgramArguments": [executable],
                    "RunAtLoad": true,
                    "KeepAlive": false,
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch {
            Log.ui.error("Legacy launch-at-login \(enabled ? "install" : "removal", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isLegacyEnabled() -> Bool {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return false }
        let plistURL = library
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.pianomonitor.app.plist")
        return FileManager.default.fileExists(atPath: plistURL.path)
    }
}
