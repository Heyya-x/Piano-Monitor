import Charts
import PianoMonitorKit
import SwiftUI

/// Formatting shared by the iOS screens, so they read like the macOS app.
enum IOSFormat {

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func shortDay(_ date: Date) -> String { shortDayFormatter.string(from: date) }
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func range(_ start: Date, _ end: Date?) -> String {
        guard let end else { return "\(time(start)) – now" }
        return "\(time(start)) – \(time(end))"
    }
}

/// Connection banner: always visible when something is wrong, because a viewer that silently shows
/// stale numbers is worse than one that admits the Mac is missing.
struct ConnectionBanner: View {

    let connection: PianoMonitorClientModel.ConnectionState
    let lastUpdated: Date?
    let isOfflineCache: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.description)
                    .font(.system(size: 12, weight: .medium))
                if isOfflineCache, let lastUpdated {
                    Text("Showing cached data from \(IOSFormat.time(lastUpdated))")
                        .font(.system(size: 10))
                }
            }
            Spacer(minLength: 0)
            if !connection.isConnected {
                Button("Retry", action: onRetry)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(background)
    }

    private var icon: String {
        switch connection {
        case .connected: return "wifi"
        case .searching: return "magnifyingglass"
        case .noMacFound: return "wifi.slash"
        case .disconnected: return "exclamationmark.triangle.fill"
        }
    }

    private var background: Color {
        switch connection {
        case .connected: return Color.green.opacity(0.14)
        case .searching: return Color.secondary.opacity(0.12)
        case .noMacFound, .disconnected: return Color.orange.opacity(0.16)
        }
    }
}

/// Home: the today / this-week summary the spec sketches.
public struct IOSHomeView: View {

    @ObservedObject private var model: PianoMonitorClientModel

    public init(model: PianoMonitorClientModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(DurationFormatter.short(model.todayDuration))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let status = model.status, status.isPlaying {
                        Label("Playing now", systemImage: "pianokeys")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if let status = model.status {
                        Text(status.state.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("This week") {
                HStack {
                    summary("Total", DurationFormatter.short(model.statistics.totalActiveDuration))
                    Divider()
                    summary("Sessions", "\(model.statistics.sessionCount)")
                    Divider()
                    summary("Avg / day", DurationFormatter.short(model.statistics.averageDailyDuration))
                }
                .frame(maxWidth: .infinity)

                HStack {
                    summary("Longest", DurationFormatter.short(model.statistics.longestSessionDuration))
                    Divider()
                    summary("Average", DurationFormatter.short(model.statistics.averageSessionDuration))
                    Divider()
                    summary("Streak", "\(model.statistics.currentStreakDays)d")
                }
                .frame(maxWidth: .infinity)
            }

            Section("Last 7 days") {
                if model.weekChartData.contains(where: { $0.totalActiveDuration > 0 }) {
                    Chart(model.weekChartData, id: \.date) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Minutes", day.totalActiveDuration / 60)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(IOSFormat.shortDay(date))
                                        .font(.system(size: 9))
                                }
                            }
                        }
                    }
                    .frame(height: 150)
                    .padding(.vertical, 4)
                } else {
                    Text("No practice recorded in the last 7 days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let status = model.status {
                Section("Mac") {
                    LabeledContent("State", value: status.audioState)
                    if let input = status.inputDevice {
                        LabeledContent("Input", value: input)
                    }
                    if let output = status.outputDeviceName {
                        LabeledContent("Output", value: output)
                    }
                    LabeledContent("Source", value: status.server.hostName)
                    if let updated = model.lastUpdated {
                        LabeledContent("Updated", value: IOSFormat.time(updated))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
    }

    private func summary(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Sessions: grouped by day, newest first.
public struct IOSSessionsView: View {

    @ObservedObject private var model: PianoMonitorClientModel

    public init(model: PianoMonitorClientModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if model.sessionsByDay.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "pianokeys",
                    description: Text("Practice time recorded on the Mac will appear here.")
                )
            } else {
                ForEach(model.sessionsByDay, id: \.day) { group in
                    Section(IOSFormat.day(group.day)) {
                        ForEach(group.sessions) { session in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(IOSFormat.range(session.startDate, session.endDate))
                                        .font(.system(size: 13, design: .monospaced))
                                    if session.segmentCount > 1 {
                                        Text("\(session.segmentCount) segments")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(DurationFormatter.short(session.activeDuration))
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
    }
}
