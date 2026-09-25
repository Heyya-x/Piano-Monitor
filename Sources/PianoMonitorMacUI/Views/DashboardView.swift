import Charts
import PianoMonitorKit
import SwiftUI

/// The main dashboard: the same numbers as the menu bar, with room to breathe and a weekly chart.
public struct DashboardView: View {

    @ObservedObject private var runtime: PianoMonitorAppRuntime
    @State private var days: [PracticeDay] = []
    @State private var statistics = PracticeStatistics.empty
    @State private var refreshToken = 0

    public init(runtime: PianoMonitorAppRuntime) {
        self.runtime = runtime
    }

    private var status: LiveStatus { runtime.status }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if status.connection.isDegraded {
                    WarningBanner(status.connection.shortDescription)
                }
                if let error = runtime.startupError {
                    WarningBanner(error)
                }

                todaySection
                liveSection
                devicesSection
                weeklySection
                footerSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // The dashboard shows a waveform, so ask the engine for one.
            runtime.service?.setWaveformVisible(true)
            refresh()
        }
        .onDisappear {
            runtime.service?.setWaveformVisible(false)
        }
        .task(id: refreshToken) {
            days = await runtime.dailySummaries(days: 7)
            statistics = await runtime.statistics(period: .week)
        }
        // Refresh the slower statistics whenever the practice state changes, not on a timer.
        .onChange(of: status.state) { _, _ in refresh() }
    }

    private func refresh() {
        refreshToken += 1
    }

    // MARK: - Sections

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Today")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DurationFormatter.short(status.todayActiveDuration))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("across \(status.todaySessionCount) session\(status.todaySessionCount == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Now")
            StatusIndicatorView(status: status)

            WaveformView(
                waveform: status.waveform,
                levelDB: status.inputLevelDB,
                noiseFloorDB: status.noiseFloorDB,
                isPlaying: status.state == .playing
            )
            .frame(height: 70)

            HStack(spacing: 18) {
                MetricRow("Confidence", String(format: "%.0f%%", status.confidence * 100))
                MetricRow("Level", String(format: "%.0f dB", status.inputLevelDB))
                MetricRow("Noise floor", String(format: "%.0f dB", status.noiseFloorDB))
            }

            if status.state != .idle {
                MetricRow("Current session", DurationFormatter.clock(status.metrics.currentSessionActiveDuration), emphasis: true)
                if let start = status.metrics.sessionStart {
                    MetricRow("Started", MacFormat.time(start))
                }
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Audio")
            MetricRow("Input", status.inputDeviceName ?? "—", emphasis: false)
            MetricRow("Output", status.outputDeviceName ?? "—")
            MetricRow("Sample rate", status.sampleRate > 0 ? String(format: "%.0f Hz", status.sampleRate) : "—")
            MetricRow("Monitoring", monitoringDescription)
            MetricRow("Profile", status.analysisMode.rawValue.capitalized)
            if status.droppedBuffers > 0 {
                MetricRow("Dropped buffers", "\(status.droppedBuffers)")
            }
        }
    }

    private var monitoringDescription: String {
        switch status.monitoring {
        case .off: return "Off"
        case .active: return "Input → Output"
        case .suppressed(let reason): return "Suppressed (\(reason))"
        }
    }

    private var weeklySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("This week")
            HStack(spacing: 22) {
                MetricRow("Total", DurationFormatter.short(statistics.totalActiveDuration), emphasis: true)
                MetricRow("Sessions", "\(statistics.sessionCount)")
                MetricRow("Average", DurationFormatter.short(statistics.averageDailyDuration))
                MetricRow("Longest", DurationFormatter.short(statistics.longestSessionDuration))
                MetricRow("Streak", "\(statistics.currentStreakDays) day\(statistics.currentStreakDays == 1 ? "" : "s")")
            }

            if days.contains(where: { $0.activeDuration > 0 }) {
                Chart(days, id: \.day) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Practice", day.activeDuration / 60)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(MacFormat.weekday(date))
                            }
                        }
                    }
                }
                .chartYAxisLabel("minutes")
                .frame(height: 120)
            } else {
                Text("No practice recorded this week yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(height: 120, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Diagnostics")
            MetricRow("Storage", runtime.storeKind)
            MetricRow("Detector", status.detectorName.isEmpty ? "—" : status.detectorName)
            MetricRow("LAN API", apiDescription)
        }
    }

    private var apiDescription: String {
        if let failure = runtime.service?.apiFailure { return "Failed: \(failure)" }
        guard let port = runtime.service?.apiPort, port != 0 else { return "Starting…" }
        return "Bonjour \(APIConstants.bonjourServiceType) · port \(port)"
    }
}
