import AVFoundation
import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// Owns and wires together every runtime component.
///
/// Responsibilities, in order:
/// 1. resolve settings and audio devices,
/// 2. drive the audio engine (main actor: hardware lifecycle only),
/// 3. hand frames to `AnalysisPipeline` (utility queue: all DSP),
/// 4. publish throttled status to the UI,
/// 5. own the HTTP server.
///
/// Marked `@MainActor` because its published state is UI state. It never performs DSP itself.
@MainActor
public final class PianoMonitorService {

    // MARK: Public state

    public private(set) var status = LiveStatus.initial {
        didSet {
            guard oldValue != status else { return }
            for observer in observers.values { observer(status) }
        }
    }

    public private(set) var settings: AppSettings = .default
    public private(set) var isRunning = false
    /// Populated when persistence or startup fails, so the UI can show a real message.
    public private(set) var lastError: String?

    // MARK: Components

    public let devices: AudioDeviceManager
    public let audioEngine: AudioEngine
    public let store: PianoDataStore
    private let pipeline: AnalysisPipeline
    private let apiServer: PianoAPIServer?

    // MARK: Observations

    private var observers: [UUID: @Sendable (LiveStatus) -> Void] = [:]
    private var publishTimer: DispatchSourceTimer?
    private var isSleeping = false
    /// Published port of the HTTP API, or `nil` when the server is off.
    public private(set) var apiPort: UInt16?
    public private(set) var apiFailure: String?
    /// `true` once `_pianomonitor._tcp` was verified to resolve. `false` means the iPhone will not
    /// discover this Mac automatically, even though the HTTP API itself may be reachable by IP.
    public var isDiscoverable: Bool { apiServer?.isAdvertising ?? false }
    /// Last Bonjour problem, for display.
    public var bonjourError: String? { apiServer?.advertisementError }

    // MARK: Init

    public init(store: PianoDataStore, devices: AudioDeviceManager = AudioDeviceManager(), startAPIServer: Bool = true) {
        self.store = store
        self.devices = devices
        let settings = AppSettings.default
        self.pipeline = AnalysisPipeline(
            store: store,
            configuration: settings.detectorConfiguration(),
            sampleRate: 44_100
        )
        self.audioEngine = AudioEngine(devices: devices)
        self.apiServer = startAPIServer ? PianoAPIServer(store: store) : nil
        wire()
    }

    // MARK: - Lifecycle

    /// Loads settings and starts capture. Safe to call more than once.
    public func start() async {
        guard !isRunning else { return }

        do {
            settings = try await store.loadSettings()
        } catch {
            Log.store.error("Could not load settings: \(error.localizedDescription, privacy: .public)")
            lastError = "Settings could not be loaded: \(error.localizedDescription)"
        }
        Log.isVerbose = settings.verboseLogging
        applySettingsToComponents()
        await refreshTodayStatistics()

        startAPIServerIfNeeded()

        // Ask for microphone access before touching AVAudioEngine, so the user sees a proper prompt
        // instead of a silent failure. Bounded by a timeout: on a headless or locked session the
        // system prompt can never be answered, and an unbounded await would leave the app sitting
        // in `.idle` forever with no audio and no explanation.
        let granted = await AudioPermission.requestMicrophoneAccess(timeout: 60)
        guard granted else {
            updateStatus { $0.connection = .permissionDenied }
            Log.audio.error("Microphone permission denied; capture not started")
            lastError = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
            return
        }

        audioEngine.start()
        isRunning = true
        updateStatus { $0.isRunning = true }
        startPublishTimer()
    }

    public func stop() async {
        guard isRunning else { return }
        // Close any open session before tearing down audio so practice time is not lost.
        pipeline.finalize()
        audioEngine.stop()
        stopPublishTimer()
        isRunning = false
        updateStatus { $0.isRunning = false }
        await Task.yield()
        await refreshTodayStatistics()
    }

    /// Handles system sleep: audio is paused and the open session closed, so a closed lid neither
    /// leaves the engine spinning nor records an 8-hour "session".
    public func handleSleep() {
        guard isRunning else { return }
        isSleeping = true
        Log.session.notice("System sleeping: closing any open session")
        pipeline.finalize(reason: .audioLost)
        audioEngine.stop()
    }

    public func handleWake() {
        guard isRunning, isSleeping else { return }
        isSleeping = false
        Log.session.notice("System woke: resuming capture")
        audioEngine.start()
    }

    // MARK: - Settings

    public func update(settings newValue: AppSettings) async {
        let previous = settings
        settings = newValue
        Log.isVerbose = newValue.verboseLogging
        applySettingsToComponents()
        do {
            try await store.saveSettings(newValue)
        } catch {
            lastError = "Settings could not be saved: \(error.localizedDescription)"
            Log.store.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
            settings = previous
            applySettingsToComponents()
        }
    }

    private func applySettingsToComponents() {
        let configuration = settings.detectorConfiguration()
        pipeline.update(configuration: configuration, targetBPM: settings.metronomeTargetBPM)
        audioEngine.mode = status.analysisMode
        audioEngine.configure(
            inputDeviceUID: settings.inputDeviceUID,
            outputDeviceUID: settings.outputDeviceUID,
            monitoringEnabled: settings.monitoringEnabled,
            monitoringGain: settings.monitoringGain,
            latencyProfile: settings.latencyProfile,
            feedbackGuardEnabled: settings.feedbackGuardEnabled
        )
        updateStatus { status in
            status.inputDeviceName = self.resolvedInputName()
            status.outputDeviceName = self.resolvedOutputName()
            status.inputDeviceUID = self.settings.inputDeviceUID
            status.outputDeviceUID = self.settings.outputDeviceUID
            status.isInputDeviceConnected = self.isSelectedDeviceConnected(uid: self.settings.inputDeviceUID)
            status.isOutputDeviceConnected = self.isSelectedDeviceConnected(uid: self.settings.outputDeviceUID)
        }
    }

    private func isSelectedDeviceConnected(uid: String?) -> Bool {
        guard let uid else { return true } // nothing selected => system default is always "connected"
        return devices.device(withUID: uid) != nil
    }

    /// The device actually in use.
    ///
    /// Prefers what the engine really opened over what the settings ask for: a saved UID can outlive
    /// its device, and naming the requested-but-absent device made the UI claim "Input disconnected:
    /// USB Audio Device" while happily recording from the built-in microphone.
    public func resolvedInputName() -> String? {
        if let active = audioEngine.activeInputDevice { return active.name }
        if let uid = settings.inputDeviceUID, let device = devices.device(withUID: uid) {
            return device.name
        }
        return devices.defaultInputDevice()?.name
    }

    public func resolvedOutputName() -> String? {
        if let active = audioEngine.activeOutputDevice { return active.name }
        if let uid = settings.outputDeviceUID, let device = devices.device(withUID: uid) {
            return device.name
        }
        return devices.defaultOutputDevice()?.name
    }

    /// A saved device selection that no longer matches any connected device, if any. The Settings
    /// screen offers to clear it, because a stale UID otherwise survives every relaunch.
    public var staleDeviceSelection: (input: String?, output: String?) {
        let input = settings.inputDeviceUID.flatMap { devices.device(withUID: $0) == nil ? $0 : nil }
        let output = settings.outputDeviceUID.flatMap { devices.device(withUID: $0) == nil ? $0 : nil }
        return (input, output)
    }

    /// Clears device selections that no longer resolve, returning the audio to the system defaults.
    public func clearStaleDeviceSelection() async {
        guard staleDeviceSelection.input != nil || staleDeviceSelection.output != nil else { return }
        var updated = settings
        if staleDeviceSelection.input != nil { updated.inputDeviceUID = nil }
        if staleDeviceSelection.output != nil { updated.outputDeviceUID = nil }
        await update(settings: updated)
    }

    /// Reference count of views currently showing a waveform. When it drops to zero the engine
    /// stops producing one.
    private var waveformConsumers = 0

    /// Called by waveform views as they appear and disappear.
    public func setWaveformVisible(_ visible: Bool) {
        waveformConsumers = max(0, waveformConsumers + (visible ? 1 : -1))
        audioEngine.setWaveformEnabled(waveformConsumers > 0)
    }

    // MARK: - Analysis mode

    /// Switches the processing profile. Driven by UI visibility: eco in the background, analysis
    /// while the Tempo Analyzer window is on screen.
    public func setAnalysisMode(_ mode: AnalysisMode) {
        guard status.analysisMode != mode else { return }
        updateStatus { $0.analysisMode = mode }
        audioEngine.mode = mode
        pipeline.analysisMode = mode
        // The UI cadence follows the profile, which is what keeps an open window honest about its
        // cost while the background stays cheap.
        startPublishTimer()
    }

    // MARK: - Observation

    @discardableResult
    public func addObserver(_ observer: @escaping @Sendable (LiveStatus) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(status)
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func updateStatus(_ mutate: (inout LiveStatus) -> Void) {
        var copy = status
        mutate(&copy)
        status = copy
    }

    /// Single timer for all UI-facing updates.
    ///
    /// The spec's rule is "menu bar ~1 FPS, waveform 5–10 FPS, analysis page higher, only while
    /// visible" — so the cadence comes from the analysis profile rather than from each view's own
    /// timer, and there is exactly one place to tune for power.
    private func startPublishTimer() {
        publishTimer?.cancel()
        let interval = 1.0 / max(0.5, status.analysisMode.uiRefreshHz)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(Int(interval * 250))
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.publishLiveState()
            }
        }
        timer.resume()
        publishTimer = timer
    }

    private func stopPublishTimer() {
        publishTimer?.cancel()
        publishTimer = nil
    }

    /// Recomputed at the profile's cadence — never per audio frame.
    private func publishLiveState() {
        let metrics = pipeline.metrics()
        let diagnostics = audioEngine.diagnostics()
        // Only pull the waveform when something is actually displaying it.
        let waveform = waveformConsumers > 0 ? audioEngine.waveform() : []
        updateStatus { status in
            status.metrics = metrics
            status.waveform = waveform
            status.connection = diagnostics.state
            status.monitoring = diagnostics.monitoring
            status.latency = diagnostics.latency
            status.sampleRate = diagnostics.sampleRate
            status.droppedBuffers = diagnostics.droppedBuffers
            status.detectorName = self.pipeline.detectorName
            status.inputDeviceName = self.resolvedInputName()
            status.outputDeviceName = self.resolvedOutputName()
            status.isInputDeviceConnected = self.isSelectedDeviceConnected(uid: self.settings.inputDeviceUID)
            status.isOutputDeviceConnected = self.isSelectedDeviceConnected(uid: self.settings.outputDeviceUID)
        }
    }

    /// Recomputes today's total from the store. Deliberately *not* on the audio path: it runs on
    /// session boundaries and on start/stop.
    public func refreshTodayStatistics() async {
        do {
            let statistics = try await store.statistics(period: .day, reference: Date())
            updateStatus { status in
                status.todayActiveDuration = statistics.totalActiveDuration
                status.todaySessionCount = statistics.sessionCount
            }
        } catch {
            Log.store.error("Could not compute today's statistics: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Snapshot of everything the Tempo Analyzer screen needs.
    public func tempoSnapshot() -> TempoSnapshot {
        var snapshot = pipeline.metrics().tempo
        if !snapshot.hasMeasurement {
            snapshot = pipeline.tempoSnapshot()
        }
        return snapshot
    }

    public func tempoTargetBPM() -> Double { settings.metronomeTargetBPM }

    /// Current persisted settings — used by the UI to seed its editors.
    public func settingsSnapshot() -> AppSettings { settings }

    /// Clears the tempo analyzer's measurement without touching configuration.
    public func resetTempoMeasurement() {
        pipeline.resetTempo()
    }

    /// Flushes the current tempo run to the store (called when the analyzer screen closes).
    public func finishTempoRun() async {
        await pipeline.finishTempoRun(targetBPM: settings.metronomeTargetBPM)
    }

    /// Number of onsets the detector currently counts, for diagnostics.
    public var onsetCountInWindow: Int { pipeline.metrics().onsetCount }

    // MARK: - HTTP API

    private func startAPIServerIfNeeded() {
        guard let apiServer, settings.allowLocalNetworkAPI else { return }
        do {
            let preferredPort = settings.preferredPort
            let token = settings.apiToken
            let port = try apiServer.start(preferredPort: preferredPort, token: token)
            apiPort = port
            apiFailure = nil
            // Point the API at a *throttled* view of live state: no audio buffers, no ORM objects.
            // The closure hops to the main actor, so the network queue never reads UI state directly.
            let provider = PianoAPIServer.StatusProvider { [weak self] in
                let payload = await MainActor.run { () -> APIStatusResponse in
                    guard let self else { return .disconnected }
                    return self.apiStatusPayload()
                }
                return payload
            }
            apiServer.statusProvider = provider
            apiServer.tempoProvider = { [weak self] in
                await MainActor.run { self?.status.metrics.tempo }
            }
            apiServer.diagnosticsProvider = { [weak self] in
                await MainActor.run { self?.apiDiagnosticsPayload() ?? nil }
            }
            Log.network.notice("PianoMonitor API listening on port \(port, privacy: .public)")
        } catch {
            // A failure to bind must never take the app down: practice recording is the priority.
            apiFailure = error.localizedDescription
            Log.network.error("HTTP server failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Restarts the LAN API, including its Bonjour registration. Exposed in Settings so a Mac that
    /// is reachable by IP but invisible to the iPhone can be recovered without relaunching.
    @discardableResult
    public func restartAPIServer() -> Bool {
        guard let apiServer else { return false }
        do {
            apiPort = try apiServer.restart()
            apiFailure = nil
            return true
        } catch {
            apiFailure = error.localizedDescription
            Log.network.error("Could not restart the API server: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func markAPIServerFailed(_ message: String) {
        apiFailure = message
    }

    /// Internal health for `GET /api/diagnostics`.
    ///
    /// Exists because the pieces that cannot be unit-tested — whether the microphone prompt was
    /// granted, whether Bonjour actually got advertised, which port is really in use — need to be
    /// observable from outside the app.
    private func apiDiagnosticsPayload() -> APIDiagnosticsResponse? {
        guard let apiServer else { return nil }
        let requests = apiServer.requestStatistics()
        let diagnostics = audioEngine.diagnostics()
        return APIDiagnosticsResponse(
            version: APIConstants.apiVersion,
            hostName: APIConstants.localHostName,
            bonjourServiceType: APIConstants.bonjourServiceType,
            listeningPort: apiServer.port,
            usedFallbackPort: apiServer.didFallBackToEphemeralPort,
            bonjourAdvertising: apiServer.isAdvertising,
            bonjourError: apiServer.advertisementError,
            httpRequestCount: requests.count,
            lastRequestPath: requests.lastPath,
            microphonePermission: AudioPermission.currentStatusDescription,
            audioState: diagnostics.state.shortDescription,
            audioDeviceName: resolvedInputName(),
            analysisSampleRate: diagnostics.sampleRate,
            detectorName: pipeline.detectorName,
            storageKind: store.kind,
            latencyProfile: diagnostics.latency.profile.rawValue,
            inputBufferFrames: diagnostics.latency.inputBufferFrames,
            outputBufferFrames: diagnostics.latency.outputBufferFrames,
            roundTripLatencyMilliseconds: diagnostics.latency.estimatedRoundTripMilliseconds,
            latencySummary: diagnostics.latency.summary,
            latencyNotes: diagnostics.latency.notes
        )
    }

    private func apiStatusPayload() -> APIStatusResponse {
        APIStatusResponse(
            isPlaying: status.state == .playing,
            state: status.state.rawValue,
            todayActiveDuration: status.todayActiveDuration,
            todaySessionCount: status.todaySessionCount,
            currentSession: status.metrics.sessionStart.map {
                CurrentSessionResponse(start: $0, activeDuration: status.metrics.currentSessionActiveDuration)
            },
            inputDevice: status.inputDeviceName,
            outputDeviceName: status.outputDeviceName,
            audioState: status.connection.shortDescription,
            sampleRate: status.sampleRate,
            server: .pianoMonitor
        )
    }

    // MARK: - Wiring

    private func wire() {
        audioEngine.onStateChange = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateStatus { $0.connection = state }
                // A device change invalidates adaptive audio state; keep sessions but rebase clocks.
                if case .running = state {
                    self.pipeline.update(sampleRate: self.audioEngine.analysisSampleRate)
                }
            }
        }

        audioEngine.onMonitoringChange = { [weak self] state in
            MainActor.assumeIsolated {
                self?.updateStatus { $0.monitoring = state }
            }
        }

        audioEngine.onFrame = { [weak self] frame in
            // Runs on the engine's analysis queue. Everything here is DSP plus a queue hop.
            guard let self else { return }
            self.pipeline.ingest(frame)
            // Feedback guard: duck the monitor path while the detector hears piano playing.
            self.audioEngine.setPlayingForMonitoringGuard(frame.rms > 0.01)
        }

        pipeline.onSessionBoundary = { [weak self] in
            Task { @MainActor in
                await self?.refreshTodayStatistics()
            }
        }
    }
}

/// Microphone permission, requested explicitly before the audio engine is started.
public enum AudioPermission {
    /// `true` when capture is allowed. On macOS this triggers the system prompt the first time.
    ///
    /// - Parameter timeout: Seconds to wait for an answer. The prompt can be unanswerable — headless
    ///   session, locked screen, no logged-in GUI — and an unbounded `await` would leave the app in
    ///   `.idle` forever with no audio and no explanation. Timing out reports "not granted" so the
    ///   UI can say so plainly.
    public static func requestMicrophoneAccess(timeout: TimeInterval = 30) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // A `CheckedContinuation` must be resumed exactly once, so both the callback and the
                // timeout race through a one-shot flag.
                let answered = OneShotFlag()
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    if answered.claim() { continuation.resume(returning: granted) }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if answered.claim() {
                        Log.audio.error("Microphone permission prompt went unanswered for \(timeout, privacy: .public)s; continuing without capture")
                        continuation.resume(returning: false)
                    }
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Current status without prompting, for the Settings screen.
    public static var currentStatusDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "Granted"
        case .notDetermined: return "Not requested yet"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
}

/// One-shot flag that makes "resume exactly once" explicit.
private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    /// Returns `true` for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}

#endif
