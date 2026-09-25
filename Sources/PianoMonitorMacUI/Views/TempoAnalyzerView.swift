import PianoMonitorKit
import SwiftUI

/// Measures an external metronome.
///
/// The point is not to *be* a metronome but to reveal how far the dial on one is from the truth, so
/// the layout leads with set-versus-actual and the error, then the stability statistics.
///
/// This screen is the only thing that raises the app to `.analysis` mode, and it lowers it again on
/// disappear. That keeps the extra CPU (and the FFT-based click gate) strictly opt-in.
public struct TempoAnalyzerView: View {

    @ObservedObject private var runtime: PianoMonitorAppRuntime
    @State private var targetBPM: Double = 100
    @State private var snapshot = TempoSnapshot.empty
    @State private var history: [TempoSessionSnapshot] = []
    @State private var isRunning = false
    @State private var errorText: String?

    public init(runtime: PianoMonitorAppRuntime) {
        self.runtime = runtime
    }

    public var body: some View {
        // A 4 Hz refresh is plenty for a BPM readout and keeps this the only screen with a timer.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    controls
                    readout
                    beats
                    if !history.isEmpty { historySection }
                    explanation
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            targetBPM = runtime.service?.tempoTargetBPM() ?? 100
            isRunning = true
            // Ask for the analysis profile: this is the one screen that needs spectral resolution.
            runtime.setAnalysisMode(.analysis)
        }
        .onDisappear {
            isRunning = false
            runtime.setAnalysisMode(.eco)
            // Persist the run so it appears in history and in /api/tempo.
            Task {
                await runtime.service?.finishTempoRun()
                history = await runtime.tempoHistory()
            }
        }
        .task {
            history = await runtime.tempoHistory()
        }
        // Reading the snapshot on the timeline's cadence (rather than observing audio) is what keeps
        // this screen's cost predictable.
        .onChange(of: isRunning) { _, _ in snapshot = runtime.service?.tempoSnapshot() ?? .empty }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            guard isRunning else { return }
            snapshot = runtime.service?.tempoSnapshot() ?? .empty
        }
    }

    // MARK: - Sections

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Metronome setting")
            HStack(spacing: 14) {
                Text("Set")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("BPM", value: $targetBPM, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit { applyTarget() }
                Stepper("", value: $targetBPM, in: 30...240, step: 1)
                    .labelsHidden()
                    .onChange(of: targetBPM) { _, _ in applyTarget() }
                Text("BPM")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()

                Button("Reset measurement") {
                    runtime.service?.resetTempoMeasurement()
                    snapshot = .empty
                }
                .controlSize(.small)
            }
            Text("Type or step to the tempo you dialled in, then play the metronome. PianoMonitor measures what it actually does.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Measurement")
            if snapshot.hasMeasurement {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Actual")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", snapshot.bpm ?? 0))
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("BPM")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Set")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", targetBPM))
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        Text("BPM")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Error")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(errorDescription)
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(errorColor)
                        Text("of target")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 26) {
                    MetricRow("Beat interval", intervalDescription)
                    MetricRow("Stability", stabilityDescription)
                    MetricRow("Grid deviation", gridDescription)
                    MetricRow("Min / Max", minMaxDescription)
                    MetricRow("Beats", "\(snapshot.totalBeatCount)")
                }
            } else {
                Text("Listening… play the metronome and keep it going for a few seconds.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(height: 90, alignment: .center)
            }
        }
    }

    private var beats: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Per-beat deviation")
            if snapshot.beats.isEmpty {
                Text("No beats measured yet.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                // The most recent 16 beats, newest last, as the spec's "+12 ms / -8 ms" table.
                let recent = Array(snapshot.beats.suffix(16))
                HStack(spacing: 3) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { index, beat in
                        VStack(spacing: 2) {
                            Text(String(format: "%+.0f", beat.deviationMilliseconds))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(deviationColor(beat.deviationMilliseconds))
                            RoundedRectangle(cornerRadius: 1)
                                .fill(deviationColor(beat.deviationMilliseconds).opacity(0.7))
                                .frame(width: 18, height: max(2, abs(CGFloat(beat.deviationMilliseconds))))
                                .frame(height: 24, alignment: beat.deviationMilliseconds >= 0 ? .top : .bottom)
                            Text("\(index + 1)")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 20)
                    }
                    Spacer(minLength: 0)
                }
                Text("Positive = late, negative = early, relative to the fitted grid.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Recent measurements")
            ForEach(history.prefix(8)) { entry in
                HStack(spacing: 14) {
                    Text(MacFormat.day(entry.startDate))
                        .font(.system(size: 11))
                        .frame(width: 100, alignment: .leading)
                    Text(String(format: "%.1f BPM", entry.averageBPM))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    if let target = entry.targetBPM, let error = entry.errorPercent {
                        Text(String(format: "set %.0f, %+.2f%%", target, error))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Text(String(format: "±%.0f ms", entry.stabilityMilliseconds))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("How this works")
            Text("The analyzer band-passes the input around 2.8 kHz, where a metronome click has most of its energy, and looks for sharp rises in the envelope. Piano notes are largely rejected by the band-pass and by a tonal gate, but if a passage fools it the measurement is wrong — practice-time recording is unaffected either way.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Derived text

    private func applyTarget() {
        guard var settings = runtime.service?.settings else { return }
        settings.metronomeTargetBPM = targetBPM
        Task { await runtime.update(settings: settings) }
    }

    private var errorDescription: String {
        guard let bpm = snapshot.bpm, targetBPM > 0 else { return "—" }
        let percent = (bpm - targetBPM) / targetBPM * 100
        return String(format: "%+.2f%%", percent)
    }

    private var errorColor: Color {
        guard let bpm = snapshot.bpm, targetBPM > 0 else { return .secondary }
        let percent = abs((bpm - targetBPM) / targetBPM * 100)
        if percent < 1 { return .green }
        if percent < 3 { return .yellow }
        return .orange
    }

    private var intervalDescription: String {
        guard let interval = snapshot.averageBeatIntervalMilliseconds else { return "—" }
        return String(format: "%.0f ms", interval)
    }

    private var stabilityDescription: String {
        guard let stability = snapshot.stabilityMilliseconds else { return "—" }
        return String(format: "±%.0f ms", stability)
    }

    private var gridDescription: String {
        guard let deviation = snapshot.gridDeviationMilliseconds else { return "—" }
        return String(format: "±%.0f ms", deviation)
    }

    private var minMaxDescription: String {
        guard let minimum = snapshot.minBPM, let maximum = snapshot.maxBPM else { return "—" }
        return String(format: "%.1f / %.1f", minimum, maximum)
    }

    private func deviationColor(_ milliseconds: Double) -> Color {
        let magnitude = abs(milliseconds)
        if magnitude < 8 { return .green }
        if magnitude < 20 { return .yellow }
        return .orange
    }
}
