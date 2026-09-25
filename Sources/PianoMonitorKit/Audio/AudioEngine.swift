import AVFoundation
import CoreAudio
import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// Health of the input/output path, surfaced verbatim to the UI and to the HTTP API.
public enum AudioConnectionState: Equatable, Sendable {
    case idle
    case running
    case inputDeviceMissing(name: String?)
    case outputDeviceMissing(name: String?)
    case permissionDenied
    case failed(String)

    /// Short status string for the menu bar (`⚠ Input Disconnected`).
    public var shortDescription: String {
        switch self {
        case .idle: return "Stopped"
        case .running: return "Running"
        case .inputDeviceMissing(let name):
            return name.map { "Input disconnected: \($0)" } ?? "Input disconnected"
        case .outputDeviceMissing(let name):
            return name.map { "Output disconnected: \($0)" } ?? "Output disconnected"
        case .permissionDenied: return "Microphone permission denied"
        case .failed(let message): return "Audio error: \(message)"
        }
    }

    public var isRunning: Bool { self == .running }

    public var isDegraded: Bool {
        switch self {
        case .running, .idle: return false
        default: return true
        }
    }
}

/// One analysed block of mono audio, handed to the detector stack.
///
/// This is the *only* thing that crosses from the audio side to the analysis side. It stays
/// small and value-typed so consumers can copy it cheaply and never touch audio buffers.
public struct ProcessedAudioFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let timestamp: Double
    /// Highest absolute sample in the block, before any filtering.
    public let peak: Float
    /// Root-mean-square of the block, in linear units.
    public let rms: Float

    public init(samples: [Float], sampleRate: Double, timestamp: Double, peak: Float, rms: Float) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
        self.peak = peak
        self.rms = rms
    }
}

/// Whether the monitored signal is actually being sent to the output device.
public enum MonitoringState: Equatable, Sendable {
    case off
    /// Pass-through enabled but temporarily muted because the detector hears piano playing
    /// (or a loop is suspected). This is the acoustic feedback guard.
    case suppressed(reason: String)
    case active

    public var isAudible: Bool { self == .active }
}

/// The realtime half of PianoMonitor: input capture, optional monitored pass-through, and a
/// cooperative analysis loop that converts PCM into `ProcessedAudioFrame`s.
///
/// Key design rules enforced here:
/// - **One engine, reused.** The engine is created once and never torn down/rebuilt for UI
///   reasons. Changing devices reconfigures it; changing settings never touches it.
/// - **No SwiftUI on the audio thread.** `onFrame` is documented to be invoked on
///   `analysisQueue`; the UI layer is responsible for hopping to the main actor.
/// - **Never crash on unplug.** Every Core Audio failure path lands in `connectionState`.
public final class AudioEngine: @unchecked Sendable {

    public typealias FrameHandler = @Sendable (ProcessedAudioFrame) -> Void

    // MARK: Public state

    /// Invoked on `analysisQueue` for every analysed block. Keep this cheap.
    public var onFrame: FrameHandler?
    /// Invoked on the main queue whenever health changes.
    public var onStateChange: (@Sendable (AudioConnectionState) -> Void)?
    /// Invoked on the main queue when the monitoring state changes.
    public var onMonitoringChange: (@Sendable (MonitoringState) -> Void)?

    /// User-selected devices. Assign through `configure(...)` so the engine can react.
    public private(set) var inputDeviceUID: String?
    public private(set) var outputDeviceUID: String?

    /// The devices actually opened, which is not always what was requested: a saved UID can outlive
    /// the device, in which case the engine falls back to the system default. The UI shows these, so
    /// it never names a device that is not the one in use.
    public private(set) var activeInputDevice: AudioDevice?
    public private(set) var activeOutputDevice: AudioDevice?
    /// Set when the requested device was missing and a fallback was used, naming what was requested.
    public private(set) var requestedInputDeviceUID: String?
    public private(set) var requestedOutputDeviceUID: String?

    /// Pass-through enable flag. Off by default: monitoring a live microphone through speakers
    /// is an acoustic feedback loop, so the user opts in deliberately.
    public private(set) var monitoringEnabled = false
    /// Linear gain applied to the monitored signal.
    public private(set) var monitoringGain: Float = 1.0

    public private(set) var connectionState: AudioConnectionState = .idle {
        didSet {
            guard oldValue != connectionState else { return }
            Log.audio.notice("Audio state: \(oldValue.shortDescription, privacy: .public) -> \(self.connectionState.shortDescription, privacy: .public)")
            let state = connectionState
            let handler = onStateChange
            DispatchQueue.main.async { handler?(state) }
        }
    }

    public private(set) var monitoringState: MonitoringState = .off {
        didSet {
            guard oldValue != monitoringState else { return }
            let state = monitoringState
            let handler = onMonitoringChange
            DispatchQueue.main.async { handler?(state) }
        }
    }

    /// Set when the engine had to fall back to the system-default device instead of pinning the
    /// selected one. Surfaced in diagnostics so "it recorded the wrong microphone" is explainable.
    public private(set) var pinningFallbackDescription: String?

    /// How hard to push the hardware buffers down. Assign through `configure(...)`.
    public private(set) var latencyProfile: LatencyProfile = .minimal
    /// What the latency configuration actually achieved, as measured rather than assumed.
    public private(set) var latencyReport = LatencyReport()
    /// Set when a buffer change needed the engine restarted, so the caller can restart once instead
    /// of fighting the running engine.
    private var needsRestartForLatency = false

    /// Analysis profile; drives FFT usage and the polling cadence.
    public var mode: AnalysisMode = .eco {
        didSet {
            guard oldValue != mode else { return }
            analysisQueue.async { [weak self] in self?.applyMode() }
        }
    }

    public private(set) var analysisSampleRate: Double = 44_100

    /// Number of min/max pairs in the waveform display buffer. ~300 points is what the spec asks
    /// for: enough to look like a waveform, few enough that SwiftUI can draw it cheaply.
    public static let waveformPointCount = 300

    /// Waveform feeding is opt-in. When no window is visible there is no reason to compute or
    /// publish a display buffer at all, which keeps the background path free of even this small
    /// cost. Set by `setWaveformEnabled(_:)` as windows open and close.
    private let waveformEnabled = AtomicInt(0)
    private let waveformLock = NSLock()
    private var waveformStorage: [Float] = []

    // MARK: Private state

    private let devices: AudioDeviceManager
    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "com.pianomonitor.audio.analysis", qos: .utility)
    private let ringBuffer: AudioRingBuffer

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var scratch: [Float] = []
    private var scratchPointer: UnsafeMutablePointer<Float>?
    /// Reused buffer for waveform downsampling, so no allocation happens per block.
    private var waveformScratch: [Float] = []
    private let scratchCapacity = 16_384

    private var pollTimer: DispatchSourceTimer?
    private var retryTimer: DispatchSourceTimer?
    private var configurationChangeObserver: NSObjectProtocol?
    private var deviceObserverToken: UUID?
    private var isRunning = false
    private var wantsToRun = false
    /// Set by the detector layer so the monitor path can duck instead of howling.
    private var suppressMonitoringUntil: Double = 0
    /// Whether the detector may duck the monitor path. Off by default.
    ///
    /// When monitoring is on, the user's explicit intent is to hear themselves play — and the
    /// previous behaviour suppressed the monitor for two seconds every time the detector heard
    /// anything, which is the opposite of monitoring. It also could not have prevented feedback:
    /// the detection signal arrives tens of milliseconds after the sound that caused it, which is far
    /// too late to stop an acoustic loop from building. Real feedback protection means "use
    /// headphones", which the UI says. The guard remains available for anyone who wants the ducking
    /// as a crude limiter.
    public private(set) var feedbackGuardEnabled = false

    // MARK: Init

    public init(devices: AudioDeviceManager = AudioDeviceManager()) {
        self.devices = devices
        self.ringBuffer = AudioRingBuffer(slotCount: 3, capacity: 16_384)
        scratch = [Float](repeating: 0, count: scratchCapacity)
        scratch.withUnsafeMutableBufferPointer { buffer in
            scratchPointer = buffer.baseAddress
        }
        installConfigurationChangeObserver()
        installDeviceObserver()
    }

    deinit {
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let token = deviceObserverToken {
            devices.removeObserver(token)
        }
        pollTimer?.cancel()
        retryTimer?.cancel()
    }

    // MARK: - Configuration

    /// Applies persisted settings. Safe to call repeatedly; the engine is only restarted when
    /// something audio-relevant actually changed. This is what keeps UI refreshes from
    /// interrupting audio.
    public func configure(
        inputDeviceUID: String?,
        outputDeviceUID: String?,
        monitoringEnabled: Bool,
        monitoringGain: Float,
        latencyProfile: LatencyProfile? = nil,
        feedbackGuardEnabled: Bool? = nil
    ) {
        if let feedbackGuardEnabled { self.feedbackGuardEnabled = feedbackGuardEnabled }
        let inputChanged = inputDeviceUID != self.inputDeviceUID
        let outputChanged = outputDeviceUID != self.outputDeviceUID
        let monitoringChanged = monitoringEnabled != self.monitoringEnabled || monitoringGain != self.monitoringGain
        let latencyChanged = latencyProfile != nil && latencyProfile != self.latencyProfile
        if let latencyProfile { self.latencyProfile = latencyProfile }

        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.monitoringEnabled = monitoringEnabled
        self.monitoringGain = max(0, min(monitoringGain, 4))

        if monitoringChanged {
            analysisQueue.async { [weak self] in
                guard let self else { return }
                self.engine.mainMixerNode.outputVolume = self.monitoringEnabled ? self.monitoringGain : 0
                self.updateMonitoringState()
            }
        }

        // The buffer size lives on the hardware, so it can only change by restarting the engine —
        // unlike the monitoring gain, which the running graph absorbs.
        guard inputChanged || outputChanged || latencyChanged else { return }
        Log.audio.notice("Audio configuration changed (input=\(inputDeviceUID ?? "default", privacy: .public), output=\(outputDeviceUID ?? "default", privacy: .public), latency=\(self.latencyProfile.rawValue, privacy: .public))")
        restart()
    }

    /// Resolves a persisted UID to a live device, falling back to the system default.
    /// Returns the resolved device plus whether the *requested* device was missing.
    private func resolve(uid: String?, scope: AudioObjectPropertyScope, wantsInput: Bool) -> (AudioDevice?, String?) {
        if let uid, !uid.isEmpty {
            if let device = devices.device(withUID: uid) {
                return (device, nil)
            }
            // Requested device is gone: fall back to the default so we keep recording with
            // whatever is available, and report the miss so the UI can show a warning.
            let fallback = wantsInput ? devices.defaultInputDevice() : devices.defaultOutputDevice()
            return (fallback, uid)
        }
        return (wantsInput ? devices.defaultInputDevice() : devices.defaultOutputDevice(), nil)
    }

    // MARK: - Lifecycle

    /// Starts capture. Idempotent.
    public func start() {
        wantsToRun = true
        analysisQueue.async { [weak self] in self?.startLocked() }
    }

    public func stop() {
        wantsToRun = false
        analysisQueue.async { [weak self] in self?.stopLocked(reason: "requested") }
    }

    /// Full restart used after device or format changes.
    public func restart() {
        guard wantsToRun else {
            // Nothing was running: just refresh the resolved formats lazily on next start().
            return
        }
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.stopLocked(reason: "reconfigure")
            self.startLocked()
        }
    }

    /// Shrinks the hardware IO buffers for both devices, and measures what was achieved.
    ///
    /// Called before every engine start. The values are read back from CoreAudio rather than assumed,
    /// because devices clamp the request to their own supported range and a "low latency" setting
    /// that silently did nothing is worse than no setting at all.
    private func applyLatencyConfiguration(inputDevice: AudioDevice, outputDevice: AudioDevice?) {
        var report = LatencyReport()
        report.profile = latencyProfile
        report.inputDeviceName = inputDevice.name
        report.outputDeviceName = outputDevice?.name

        let target = latencyProfile.targetBufferFrames
        report.inputBufferFrames = devices.setBufferFrameSize(target, on: inputDevice.id)
        if let outputDevice {
            report.outputBufferFrames = devices.setBufferFrameSize(target, on: outputDevice.id)
        }

        report.inputBufferMilliseconds = Self.milliseconds(
            frames: report.inputBufferFrames,
            sampleRate: inputDevice.nominalSampleRate
        )
        report.outputBufferMilliseconds = Self.milliseconds(
            frames: report.outputBufferFrames,
            sampleRate: outputDevice?.nominalSampleRate ?? inputDevice.nominalSampleRate
        )
        report.inputDeviceMilliseconds = Self.milliseconds(
            frames: devices.deviceLatency(of: inputDevice.id, scope: kAudioObjectPropertyScopeInput)
                + devices.safetyOffset(of: inputDevice.id, scope: kAudioObjectPropertyScopeInput),
            sampleRate: inputDevice.nominalSampleRate
        )
        if let outputDevice {
            report.outputDeviceMilliseconds = Self.milliseconds(
                frames: devices.deviceLatency(of: outputDevice.id, scope: kAudioObjectPropertyScopeOutput)
                    + devices.safetyOffset(of: outputDevice.id, scope: kAudioObjectPropertyScopeOutput),
                sampleRate: outputDevice.nominalSampleRate
            )
        }
        if report.inputBufferFrames != target {
            report.notes.append("input device clamped the buffer to \(report.inputBufferFrames.map(String.init) ?? "?") frames")
        }
        if let outputFrames = report.outputBufferFrames, outputFrames != target {
            report.notes.append("output device clamped the buffer to \(outputFrames) frames")
        }
        latencyReport = report
    }

    /// Records what the running engine reports for its own IO nodes.
    ///
    /// `presentationLatency` comes from the live audio unit, so it includes whatever the engine and
    /// driver actually did — the buffer, the safety offsets and any conversion — rather than the sum
    /// of values read from the HAL beforehand.
    private func capturePresentationLatency() {
        var report = latencyReport
        report.inputPresentationMilliseconds = engine.inputNode.presentationLatency
        report.outputPresentationMilliseconds = engine.outputNode.presentationLatency
        latencyReport = report
        Log.audio.notice("Monitoring latency: \(report.summary, privacy: .public)")
    }

    private static func milliseconds(frames: Int?, sampleRate: Double) -> Double? {
        guard let frames, sampleRate > 0 else { return nil }
        return Double(frames) / sampleRate * 1_000
    }

    /// Starts the engine with a bounded wait, returning `false` if it does not come up in time.
    ///
    /// `AVAudioEngine.start()` can block indefinitely inside CoreAudio. That must never become the
    /// app's problem: a start that never returns would leave the engine half-built while
    /// `wantsToRun` is true, so no retry would ever fire and capture would silently never begin.
    ///
    /// On timeout the engine is deliberately left alone. Calling `stop()` from here would be worse
    /// than useless — `AVAudioEngine` is not thread-safe, and a `stop()` issued while another thread
    /// sits inside `start()` can block on the engine's internal lock, which is a deadlock this code
    /// would then have created itself. The retry path rebuilds from scratch instead.
    private func startWithWatchdog(timeout: TimeInterval = 5) -> Bool {
        let outcome = BoundedOperation.run(timeout: timeout) { [engine] in
            try engine.start()
        }
        switch outcome {
        case .finished:
            return true
        case .failed(let message):
            Log.audio.error("AVAudioEngine start failed: \(message, privacy: .public)")
            connectionState = .failed(message)
            scheduleRetry()
            return false
        case .timedOut:
            Log.audio.error("AVAudioEngine.start() did not return within \(timeout, privacy: .public)s; treating the audio system as stuck and scheduling a retry")
            connectionState = .failed("Audio system did not start within \(Int(timeout))s")
            scheduleRetry()
            return false
        }
    }

    private func startLocked() {
        guard !isRunning else { return }
        guard wantsToRun else { return }

        let (inputDevice, missingInputUID) = resolve(uid: inputDeviceUID, scope: kAudioObjectPropertyScopeInput, wantsInput: true)
        guard let inputDevice else {
            connectionState = .inputDeviceMissing(name: nil)
            scheduleRetry()
            return
        }
        let (outputDevice, missingOutputUID) = resolve(uid: outputDeviceUID, scope: kAudioObjectPropertyScopeOutput, wantsInput: false)

        // Pin the hardware on both nodes before reading formats, because the format depends on it.
        //
        // Pinning is attempted because it selects the device without disturbing the user's system
        // default. When a node cannot be pinned (the selector is unavailable on some OS versions),
        // the system default is switched instead: that is always available, and CoreAudio restores
        // the previous default when the app exits. Reporting honestly beats silently recording from
        // the wrong device.
        let inputWasPinned = Self.pin(device: inputDevice, on: engine.inputNode)
        if !inputWasPinned {
            let switched = devices.setSystemDefault(device: inputDevice, scope: kAudioObjectPropertyScopeInput)
            pinningFallbackDescription = switched
                ? "using system default input"
                : "could not select the input device"
            Log.audio.notice("Could not pin the input node; \(self.pinningFallbackDescription ?? "", privacy: .public)")
        }
        if let outputDevice {
            let outputWasPinned = Self.pin(device: outputDevice, on: engine.outputNode)
            if !outputWasPinned {
                _ = devices.setSystemDefault(device: outputDevice, scope: kAudioObjectPropertyScopeOutput)
                Log.audio.notice("Could not pin the output node; switched the system default output instead")
            }
        }

        // Shrink the IO buffers *before* the engine starts: `AVAudioEngine` has no API for this, and
        // the hardware buffer is the largest single term in monitoring latency (512 frames at
        // 48 kHz is 10.7 ms in each direction).
        applyLatencyConfiguration(inputDevice: inputDevice, outputDevice: outputDevice)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            connectionState = .inputDeviceMissing(name: inputDevice.name)
            scheduleRetry()
            return
        }
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            connectionState = .failed("could not build mono analysis format")
            return
        }

        analysisSampleRate = inputFormat.sampleRate
        sourceFormat = inputFormat
        converter = AVAudioConverter(from: inputFormat, to: monoFormat)

        // Monitoring path: input -> main mixer -> output.
        //
        // Deliberately *no* intermediate mixer. The signal used to pass through a dedicated
        // `monitorMixer` purely to hold the gain, which added a mixing stage — and therefore latency —
        // to the one path where latency is the whole point. The main mixer already exists and can
        // hold the gain itself.
        //
        // Formats are left as the nodes' own: forcing a format here is what makes the engine insert
        // a sample-rate converter (and its buffering) into the live path.
        engine.disconnectNodeOutput(engine.inputNode)
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: inputFormat)
        engine.mainMixerNode.outputVolume = monitoringEnabled ? monitoringGain : 0

        engine.prepare()
        // `AVAudioEngine.start()` can block indefinitely inside CoreAudio — a wedged HAL, an IO unit
        // waiting on hardware that never answers, or a driver still negotiating. That is bad enough
        // on the analysis queue, but it must never be allowed to become the app's problem: a
        // start that never returns would leave the engine half-built while `wantsToRun` is true, so
        // no retry ever fires and capture silently never begins. A watchdog turns that into an
        // ordinary reported failure that the retry timer can recover from.
        guard startWithWatchdog() else { return }

        installTap(on: inputFormat, monoFormat: monoFormat)
        isRunning = true
        startPollTimer()
        capturePresentationLatency()

        activeInputDevice = inputDevice
        activeOutputDevice = outputDevice
        requestedInputDeviceUID = missingInputUID
        requestedOutputDeviceUID = missingOutputUID

        // Report the *requested* device as missing (that is the actionable fact) but keep the
        // actually-opened device visible, because it is what the user is hearing.
        if let missingInputUID {
            connectionState = .inputDeviceMissing(name: devices.device(withUID: missingInputUID)?.name ?? missingInputUID)
        } else if let missingOutputUID {
            connectionState = .outputDeviceMissing(name: devices.device(withUID: missingOutputUID)?.name ?? missingOutputUID)
        } else {
            connectionState = .running
        }
        updateMonitoringState()
        Log.audio.notice("Audio started: in=\(inputDevice.name, privacy: .public) \(Int(inputFormat.sampleRate), privacy: .public)Hz/\(inputFormat.channelCount, privacy: .public)ch out=\(outputDevice?.name ?? "default", privacy: .public) monitor=\(self.monitoringEnabled, privacy: .public)")
    }

    private func stopLocked(reason: String) {
        guard isRunning || pollTimer != nil else {
            connectionState = .idle
            monitoringState = .off
            activeInputDevice = nil
            activeOutputDevice = nil
            return
        }
        pollTimer?.cancel()
        pollTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        monitoringState = .off
        activeInputDevice = nil
        activeOutputDevice = nil
        connectionState = .idle
        Log.audio.notice("Audio stopped (\(reason, privacy: .public))")
    }

    private func installTap(on inputFormat: AVAudioFormat, monoFormat: AVAudioFormat) {
        engine.inputNode.removeTap(onBus: 0)
        // 1024 frames ≈ 23 ms at 44.1 kHz: small enough for responsive onset detection,
        // large enough that the tap fires ~43×/s instead of thousands of times per second.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, when in
            self?.handleTap(buffer: buffer, when: when, monoFormat: monoFormat)
        }
    }

    /// Runs on the realtime audio thread: convert to mono, publish, return. No locks, no UI.
    private func handleTap(buffer: AVAudioPCMBuffer, when: AVAudioTime, monoFormat: AVAudioFormat) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(scratchCapacity)
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: mono, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, mono.frameLength > 0, let channel = mono.floatChannelData?[0] else { return }
        // Sample-time-derived timestamps are monotonic and unaffected by wall-clock changes,
        // which is what the onset/tempo analyzers need.
        let timestamp = when.isSampleTimeValid
            ? Double(when.sampleTime) / monoFormat.sampleRate
            : CACurrentMediaTime()
        ringBuffer.write(channel, frameCount: Int(mono.frameLength), timestamp: timestamp)
    }

    // MARK: - Analysis loop

    private func startPollTimer() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        applyMode(timer: timer)
        timer.setEventHandler { [weak self] in self?.drainRingBuffer() }
        timer.resume()
        pollTimer = timer
    }

    private func applyMode() {
        guard let pollTimer else { return }
        applyMode(timer: pollTimer)
    }

    private func applyMode(timer: DispatchSourceTimer) {
        // Eco mode wakes ~20×/s to drain audio (not to run FFT); analysis mode wakes more often
        // because the tempo analyzer needs finer temporal resolution. This is the main
        // background power lever, so the eco interval intentionally lags the audio blocks.
        let interval: Double = mode == .analysis ? 0.01 : (mode == .balanced ? 0.02 : 0.05)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(mode == .analysis ? 2 : 10))
    }

    /// Cooperatively drains everything the audio thread published, so no audio is lost while we
    /// were busy. Bounded (max 8 blocks) to avoid a runaway loop on a slow machine.
    private func drainRingBuffer() {
        guard let scratchPointer else { return }
        var processed = 0
        while processed < 8 {
            guard let frame = ringBuffer.read(into: scratchPointer, capacity: scratchCapacity) else { break }
            processed += 1
            guard frame.frames > 0, let handler = onFrame else { continue }
            let samples = Array(UnsafeBufferPointer(start: scratchPointer, count: frame.frames))
            var peak: Float = 0
            var sumSquares: Float = 0
            for sample in samples {
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
                sumSquares += sample * sample
            }
            let rms = (sumSquares / Float(samples.count)).squareRoot()
            updateWaveform(from: samples, accumulator: &waveformScratch)
            handler(ProcessedAudioFrame(
                samples: samples,
                sampleRate: analysisSampleRate,
                timestamp: frame.timestamp,
                peak: peak,
                rms: rms
            ))
        }
    }

    // MARK: - Feedback guard

    /// Called by the detector layer when the piano is (or stops being) audibly playing.
    /// While playing we duck the monitored signal, because a microphone + speakers + gain is
    /// exactly the topology that produces acoustic feedback.
    public func setPlayingForMonitoringGuard(_ playing: Bool) {
        let shouldSuppress = playing && monitoringEnabled && feedbackGuardEnabled
        let target: Double = shouldSuppress ? CACurrentMediaTime() + 2.0 : suppressMonitoringUntil
        if shouldSuppress {
            suppressMonitoringUntil = target
        }
        analysisQueue.async { [weak self] in
            guard let self else { return }
            if shouldSuppress {
                self.suppressMonitoringUntil = target
            }
            self.updateMonitoringState()
        }
    }

    private func updateMonitoringState() {
        if !monitoringEnabled {
            monitoringState = .off
            return
        }
        if CACurrentMediaTime() < suppressMonitoringUntil {
            monitoringState = .suppressed(reason: "piano detected — feedback guard")
        } else {
            monitoringState = .active
        }
    }

    /// Periodic refresh of the monitoring state (called from the analysis loop's idle path).
    public func refreshMonitoringState() {
        analysisQueue.async { [weak self] in self?.updateMonitoringState() }
    }

    // MARK: - Hot-plug handling

    private func installConfigurationChangeObserver() {
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Log.audio.notice("AVAudioEngineConfigurationChange received")
            self.analysisQueue.async {
                guard self.wantsToRun else { return }
                // The engine has already stopped itself; rebuild the graph against the new hardware.
                self.stopLocked(reason: "configuration change")
                self.startLocked()
            }
        }
    }

    private func installDeviceObserver() {
        deviceObserverToken = devices.addObserver { [weak self] _ in
            guard let self else { return }
            self.analysisQueue.async {
                guard self.wantsToRun else { return }
                self.stopLocked(reason: "device list changed")
                self.startLocked()
            }
        }
    }

    /// Retries a failed start with a slow, cancelable backoff. A disconnected TOP1 must not turn
    /// into a 100 % CPU spin loop while it is unplugged.
    private func scheduleRetry() {
        guard wantsToRun, retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.isRunning {
                self.retryTimer?.cancel()
                self.retryTimer = nil
                return
            }
            self.startLocked()
            if self.isRunning {
                self.retryTimer?.cancel()
                self.retryTimer = nil
            }
        }
        timer.resume()
        retryTimer = timer
    }

    // MARK: - Diagnostics

    public struct Diagnostics: Sendable {
        public let isRunning: Bool
        public let state: AudioConnectionState
        public let mode: AnalysisMode
        public let sampleRate: Double
        public let droppedBuffers: Int
        public let writtenFrames: Int
        public let readBuffers: Int
        public let monitoring: MonitoringState
        /// Measured latency of the capture/monitor path.
        public let latency: LatencyReport
    }

    public func diagnostics() -> Diagnostics {
        Diagnostics(
            isRunning: isRunning,
            state: connectionState,
            mode: mode,
            sampleRate: analysisSampleRate,
            droppedBuffers: ringBuffer.droppedBufferCount,
            writtenFrames: ringBuffer.totalWrittenFrames,
            readBuffers: ringBuffer.totalReadBuffers,
            monitoring: monitoringState,
            latency: latencyReport
        )
    }

    // MARK: - Waveform

    /// Enables or disables waveform production. Called by the UI when a view that shows a waveform
    /// appears or disappears.
    public func setWaveformEnabled(_ enabled: Bool) {
        waveformEnabled.store(enabled ? 1 : 0)
        if !enabled {
            waveformLock.lock()
            waveformStorage = []
            waveformLock.unlock()
        }
    }

    /// Latest downsampled waveform: interleaved min/max pairs in `-1...1`, oldest first.
    /// Empty when waveform production is disabled or the signal buffer is shorter than one column.
    public func waveform() -> [Float] {
        waveformLock.lock()
        defer { waveformLock.unlock() }
        return waveformStorage
    }

    /// Reduces a block to `pointCount` min/max pairs.
    ///
    /// This runs on the analysis queue, not the audio thread, and is O(n) with a tiny constant —
    /// far cheaper than handing 44 100 samples per second to SwiftUI, which is what the spec
    /// explicitly rules out.
    private func updateWaveform(from samples: [Float], accumulator: inout [Float]) {
        guard waveformEnabled.value == 1, !samples.isEmpty else { return }
        let points = Self.waveformPointCount
        let windowSize = max(1, samples.count / points)
        accumulator.removeAll(keepingCapacity: true)
        accumulator.reserveCapacity(points * 2)
        var index = 0
        while index < samples.count {
            let end = min(index + windowSize, samples.count)
            var minimum = samples[index]
            var maximum = samples[index]
            for position in index..<end {
                let value = samples[position]
                if value < minimum { minimum = value }
                if value > maximum { maximum = value }
            }
            accumulator.append(minimum)
            accumulator.append(maximum)
            index = end
        }
        waveformLock.lock()
        waveformStorage = accumulator
        waveformLock.unlock()
    }

    /// Pins `device` onto `node`, returning `false` when the node exposes no usable audio unit.
    private static func pin(device: AudioDevice, on node: AVAudioNode) -> Bool {
        guard let unit = audioUnit(of: node) else { return false }
        return AudioDeviceManager.setCurrentDevice(device.id, on: unit)
    }

    /// Extracts the underlying `AudioUnit` from an `AVAudioNode` so its device can be pinned.
    ///
    /// **Do not use `value(forKey: "audioUnit")` here.** The method exists on `AVAudioNode` and
    /// `AVAudioIONode`, but it is not KVC-compliant: `value(forKey:)` raises
    /// `NSInvalidArgumentException` ("this class is not key value coding-compliant for the key
    /// audioUnit") rather than returning nil, and an Objective-C exception cannot be caught in
    /// Swift — it terminated the app on the audio queue. `perform(_:)` invokes the same selector
    /// directly and has no such requirement.
    static func audioUnit(of node: AVAudioNode) -> AudioUnit? {
        let selector = NSSelectorFromString("audioUnit")
        if node.responds(to: selector), let value = node.perform(selector) {
            // `audioUnit` returns a C `AudioUnit` (a pointer), not an object. `takeUnretainedValue`
            // would over-release it, so the pointer is taken as-is and reinterpreted.
            return unsafeBitCast(value, to: AudioUnit.self)
        }
        // Older or newer systems may only expose the Objective-C `AUAudioUnit` wrapper.
        let wrapperSelector = NSSelectorFromString("AUAudioUnit")
        if node.responds(to: wrapperSelector), let value = node.perform(wrapperSelector) {
            let wrapper = value.takeUnretainedValue()
            let underlying = NSSelectorFromString("audioUnit")
            if let object = wrapper as? NSObject, object.responds(to: underlying), let unit = object.perform(underlying) {
                return unsafeBitCast(unit, to: AudioUnit.self)
            }
        }
        return nil
    }
}

#endif
