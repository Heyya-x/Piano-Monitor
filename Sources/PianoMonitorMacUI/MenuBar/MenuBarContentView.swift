import PianoMonitorKit
import SwiftUI

/// Which window the menu bar should open.
public enum WindowDestination: String, CaseIterable, Identifiable {
    case dashboard
    case tempo
    case history
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .tempo: return "Tempo Analyzer"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .dashboard: return "gauge"
        case .tempo: return "metronome"
        case .history: return "calendar"
        case .settings: return "gearshape"
        }
    }
}

/// The menu bar popover: the app's primary glanceable surface.
///
/// Layout follows the spec's sketch — waveform, status, today's total, devices, then navigation.
public struct MenuBarContentView: View {

    @ObservedObject private var runtime: PianoMonitorAppRuntime
    private let openWindow: (WindowDestination) -> Void
    private let quit: () -> Void

    public init(
        runtime: PianoMonitorAppRuntime,
        openWindow: @escaping (WindowDestination) -> Void,
        quit: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.openWindow = openWindow
        self.quit = quit
    }

    private var status: LiveStatus { runtime.status }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if status.connection.isDegraded {
                WarningBanner(status.connection.shortDescription)
            }
            if let error = runtime.startupError {
                WarningBanner(error)
            }

            // Waveform: only produced while this view is visible.
            WaveformView(
                waveform: status.waveform,
                levelDB: status.inputLevelDB,
                noiseFloorDB: status.noiseFloorDB,
                isPlaying: status.state == .playing
            )
            .frame(height: 44)
            .onAppear { runtime.service?.setWaveformVisible(true) }
            .onDisappear { runtime.service?.setWaveformVisible(false) }

            LevelMeterView(levelDB: status.inputLevelDB, noiseFloorDB: status.noiseFloorDB)

            StatusIndicatorView(status: status)

            Divider()

            MetricRow("Today", DurationFormatter.short(status.todayActiveDuration), emphasis: true)
            if status.state != .idle {
                MetricRow("Current session", DurationFormatter.clock(status.metrics.currentSessionActiveDuration))
            }
            MetricRow("Input", status.inputDeviceName ?? "—")
            MetricRow("Output", status.outputDeviceName ?? "—")

            Divider()

            navigation
        }
        .padding(12)
        .frame(width: 268)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "pianokeys")
                .font(.system(size: 12, weight: .medium))
            Text("Piano Monitor")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let port = runtime.service?.apiPort, port != 0 {
                Text("API \(port)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .help("LAN API port (Bonjour: _pianomonitor._tcp)")
            }
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(WindowDestination.allCases) { destination in
                Button {
                    openWindow(destination)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: destination.systemImage)
                            .font(.system(size: 11))
                            .frame(width: 14)
                        Text(destination.title)
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
            }

            Divider()
                .padding(.vertical, 3)

            Button {
                quit()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                        .frame(width: 14)
                    Text("Quit PianoMonitor")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
        }
    }
}
