import PianoMonitorKit
import SwiftUI

/// Settings: audio devices, detection tuning, app behaviour, and diagnostics.
///
/// Every change is written through `PianoMonitorAppRuntime.update(settings:)`, which persists it and
/// pushes it to the running audio engine. Nothing here reconfigures audio by side effect.
public struct SettingsView: View {

    @ObservedObject private var runtime: PianoMonitorAppRuntime

    @State private var devices: [AudioDevice] = []
    @State private var inputUID: String = ""
    @State private var outputUID: String = ""
    @State private var monitoringEnabled = false
    @State private var monitoringGain: Double = 1.0
    @State private var latencyProfile: LatencyProfile = .low
    @State private var feedbackGuardEnabled = false
    @State private var sensitivity: Double = 0.5
    @State private var pauseSeconds: Double = 8
    @State private var endSessionSeconds: Double = 180
    @State private var launchAtLogin = false
    @State private var verboseLogging = false
    @State private var apiToken: String = ""
    @State private var loaded = false

    public init(runtime: PianoMonitorAppRuntime) {
        self.runtime = runtime
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                audioSection
                detectionSection
                behaviourSection
                diagnosticsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            refreshDevices()
            seedFromSettings()
        }
        // Devices can be plugged in while Settings is open; CoreAudio tells us when.
        .onReceive(NotificationCenter.default.publisher(for: .pianoMonitorDevicesChanged)) { _ in
            refreshDevices()
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Audio devices")

            if runtime.service?.staleDeviceSelection.input != nil
                || runtime.service?.staleDeviceSelection.output != nil {
                HStack(spacing: 8) {
                    WarningBanner("A saved device is no longer connected, so the system default is being used instead.")
                    Button("Use defaults") {
                        Task {
                            await runtime.service?.clearStaleDeviceSelection()
                            seedFromSettings()
                        }
                    }
                    .controlSize(.small)
                }
            }

            labelled("Input device") {
                Picker("", selection: $inputUID) {
                    Text("System default").tag("")
                    ForEach(inputDevices) { device in
                        Text(deviceLabel(device)).tag(device.uid)
                    }
                }
                .labelsHidden()
                .onChange(of: inputUID) { _, _ in persist() }
            }

            labelled("Output device") {
                Picker("", selection: $outputUID) {
                    Text("System default").tag("")
                    ForEach(outputDevices) { device in
                        Text(deviceLabel(device)).tag(device.uid)
                    }
                }
                .labelsHidden()
                .onChange(of: outputUID) { _, _ in persist() }
            }

            Toggle("Pass input through to the output", isOn: $monitoringEnabled)
                .onChange(of: monitoringEnabled) { _, _ in persist() }

            if monitoringEnabled {
                WarningBanner("Monitor through speakers and the microphone will hear them: keep the gain low, or use headphones. PianoMonitor cannot cancel acoustic feedback.")

                labelled("Latency") {
                    HStack(spacing: 10) {
                        Picker("", selection: $latencyProfile) {
                            ForEach(LatencyProfile.allCases, id: \.self) { profile in
                                Text(profile.rawValue.capitalized).tag(profile)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .onChange(of: latencyProfile) { _, _ in persist() }
                        Text(latencyProfile.summary)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                MetricRow("Measured round trip", runtime.status.latencySummary)
                if latencyProfile == .minimal {
                    Text("Minimal uses the smallest buffer the hardware allows — on this machine 32 frames, about 6.7 ms round trip including driver latency. If you hear crackling or dropouts, step up to Low.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if runtime.status.droppedBuffers > 0 {
                    WarningBanner("The analysis path has dropped \(runtime.status.droppedBuffers) buffers. This is not the monitor path, but it suggests the machine is loaded — try the Low latency profile.")
                }

                labelled("Monitor gain") {
                    Slider(value: $monitoringGain, in: 0...2, step: 0.05)
                        .frame(width: 200)
                        .onChange(of: monitoringGain) { _, _ in persist() }
                }

                Toggle("Mute monitoring while playing (feedback guard)", isOn: $feedbackGuardEnabled)
                    .onChange(of: feedbackGuardEnabled) { _, _ in persist() }
                Text("Off by default: monitoring is for hearing yourself play, and this mutes the monitor whenever the detector hears the piano. It also cannot prevent feedback — it reacts tens of milliseconds too late. Turn it on only if you want the monitor ducked rather than continuous.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .suppressed(let reason) = runtime.status.monitoring {
                    MetricRow("Monitor state", "Suppressed — \(reason)")
                }
            }

            MetricRow("Actually in use", "\(runtime.status.inputDeviceName ?? "—") → \(runtime.status.outputDeviceName ?? "—")")
            MetricRow("Microphone permission", AudioPermission.currentStatusDescription)

            Text("Devices are matched by their stable Core Audio UID, so unplugging and replugging keeps your selection.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deviceLabel(_ device: AudioDevice) -> String {
        "\(device.name)  ·  \(device.transportDescription)"
    }

    // MARK: - Detection

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Detection")

            labelled("Sensitivity") {
                HStack(spacing: 10) {
                    Slider(value: $sensitivity, in: 0...1)
                        .frame(width: 220)
                        .onChange(of: sensitivity) { _, _ in persist() }
                    Text(sensitivityDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)
                }
            }

            labelled("Pause after") {
                HStack(spacing: 8) {
                    Slider(value: $pauseSeconds, in: 3...30, step: 1)
                        .frame(width: 180)
                        .onChange(of: pauseSeconds) { _, _ in persist() }
                    Text("\(Int(pauseSeconds)) s of silence")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            labelled("End session after") {
                HStack(spacing: 8) {
                    Slider(value: $endSessionSeconds, in: 30...600, step: 15)
                        .frame(width: 180)
                        .onChange(of: endSessionSeconds) { _, _ in persist() }
                    Text(DurationFormatter.short(endSessionSeconds))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Text("A short break only pauses the session, so thinking between phrases does not split your practice in two. The session is closed once the second threshold passes.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sensitivityDescription: String {
        switch sensitivity {
        case ..<0.3: return "Needs loud playing"
        case ..<0.55: return "Balanced"
        case ..<0.8: return "Sensitive"
        default: return "Very sensitive"
        }
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Application")
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, _ in persist() }
            MetricRow("Login item status", runtime.launchAtLoginDescription)

            Toggle("Verbose logging", isOn: $verboseLogging)
                .onChange(of: verboseLogging) { _, newValue in
                    Log.isVerbose = newValue
                    persist()
                }
            Text("Verbose logging writes per-buffer detector values to the unified log. Useful for a short calibration session, costly to leave on.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labelled("API token") {
                HStack(spacing: 8) {
                    TextField("none", text: $apiToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit { persist() }
                    Button("Apply") { persist() }
                        .controlSize(.small)
                }
            }
            Text("Optional. When set, every request to the LAN API must include it (?token=… or the X-PianoMonitor-Token header).")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Diagnostics")
            MetricRow("Storage", runtime.storeKind)
            MetricRow("Audio state", runtime.status.connection.shortDescription)
            MetricRow("Sample rate", runtime.status.sampleRate > 0 ? String(format: "%.0f Hz", runtime.status.sampleRate) : "—")
            MetricRow("Detector", runtime.status.detectorName.isEmpty ? "—" : runtime.status.detectorName)
            MetricRow("Dropped buffers", "\(runtime.status.droppedBuffers)")
            MetricRow("LAN API", apiDescription)
            networkActions
            if let error = runtime.startupError {
                WarningBanner(error)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Log streaming")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("log stream --predicate 'subsystem == \"\(Log.subsystem)\"' --level debug")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private var apiDescription: String {
        if let failure = runtime.service?.apiFailure { return "Failed: \(failure)" }
        guard let port = runtime.service?.apiPort, port != 0 else { return "Not running" }
        let discoverable = runtime.service?.isDiscoverable == true ? "discoverable" : "NOT discoverable"
        return "port \(port) · \(discoverable)"
    }

    /// Bonjour is registered asynchronously by the system, and a registration that never lands
    /// leaves the Mac reachable by IP but invisible to the iPhone. Restarting is the recovery.
    private var networkActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Restart LAN server") {
                    _ = runtime.service?.restartAPIServer()
                }
                .controlSize(.small)
                Text("Use this if the iPhone cannot find this Mac.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if let error = runtime.service?.bonjourError {
                WarningBanner("Bonjour: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 150, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private var inputDevices: [AudioDevice] { devices.filter(\.hasInput) }
    private var outputDevices: [AudioDevice] { devices.filter(\.hasOutput) }

    private func refreshDevices() {
        Task {
            let all = await Task.detached { AudioDeviceManager().allDevices() }.value
            devices = all
        }
    }

    private func seedFromSettings() {
        guard !loaded, let settings = runtime.service?.settings else { return }
        inputUID = settings.inputDeviceUID ?? ""
        outputUID = settings.outputDeviceUID ?? ""
        monitoringEnabled = settings.monitoringEnabled
        monitoringGain = Double(settings.monitoringGain)
        latencyProfile = settings.latencyProfile
        feedbackGuardEnabled = settings.feedbackGuardEnabled
        sensitivity = Double(settings.sensitivity)
        pauseSeconds = settings.pauseAfterSilenceSeconds
        endSessionSeconds = settings.endSessionAfterSilenceSeconds
        launchAtLogin = settings.launchAtLogin
        verboseLogging = settings.verboseLogging
        apiToken = settings.apiToken ?? ""
        // A stored UID that no longer exists would make the picker show nothing selected; clear the
        // selection locally so the UI reflects reality rather than a device that has gone away.
        if !settings.inputDeviceUID.isNilOrEmpty, devices.allSatisfy({ $0.uid != settings.inputDeviceUID }) {
            inputUID = ""
        }
        if !settings.outputDeviceUID.isNilOrEmpty, devices.allSatisfy({ $0.uid != settings.outputDeviceUID }) {
            outputUID = ""
        }
        loaded = true
    }

    private func persist() {
        guard loaded, var settings = runtime.service?.settings else { return }
        settings.inputDeviceUID = inputUID.isEmpty ? nil : inputUID
        settings.outputDeviceUID = outputUID.isEmpty ? nil : outputUID
        settings.monitoringEnabled = monitoringEnabled
        settings.monitoringGain = Float(monitoringGain)
        settings.latencyProfile = latencyProfile
        settings.feedbackGuardEnabled = feedbackGuardEnabled
        settings.sensitivity = Float(sensitivity)
        settings.pauseAfterSilenceSeconds = pauseSeconds
        settings.endSessionAfterSilenceSeconds = endSessionSeconds
        settings.launchAtLogin = launchAtLogin
        settings.verboseLogging = verboseLogging
        settings.apiToken = apiToken.isEmpty ? nil : apiToken
        Task { await runtime.update(settings: settings) }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

public extension Notification.Name {
    /// Posted when the audio device list changes, so Settings can refresh its pickers.
    static let pianoMonitorDevicesChanged = Notification.Name("com.pianomonitor.devicesChanged")
}
