import Charts
import PianoMonitorKit
import SwiftUI

/// History: period picker, totals and a daily chart.
public struct IOSHistoryView: View {

    @ObservedObject private var model: PianoMonitorClientModel
    @State private var period: StatisticsPeriod = .week
    @State private var statistics = PracticeStatistics.empty
    @State private var days: [DailyPracticeSummary] = []

    public init(model: PianoMonitorClientModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section {
                Picker("Period", selection: $period) {
                    Text("Week").tag(StatisticsPeriod.week)
                    Text("Month").tag(StatisticsPeriod.month)
                    Text("Year").tag(StatisticsPeriod.year)
                    Text("All").tag(StatisticsPeriod.all)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            Section("Totals") {
                LabeledContent("Total playing", value: DurationFormatter.short(statistics.totalActiveDuration))
                LabeledContent("Sessions", value: "\(statistics.sessionCount)")
                LabeledContent("Average session", value: DurationFormatter.short(statistics.averageSessionDuration))
                LabeledContent("Longest session", value: DurationFormatter.short(statistics.longestSessionDuration))
                LabeledContent("Average per day", value: DurationFormatter.short(statistics.averageDailyDuration))
                LabeledContent("Current streak", value: "\(statistics.currentStreakDays) day\(statistics.currentStreakDays == 1 ? "" : "s")")
            }

            Section("Daily") {
                if days.contains(where: { $0.totalActiveDuration > 0 }) {
                    Chart(days, id: \.date) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Minutes", day.totalActiveDuration / 60)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(2)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(IOSFormat.shortDay(date))
                                        .font(.system(size: 9))
                                }
                            }
                        }
                    }
                    .frame(height: 160)
                    .padding(.vertical, 4)

                    ForEach(days.reversed(), id: \.date) { day in
                        if day.sessionCount > 0 {
                            HStack {
                                Text(IOSFormat.day(day.date))
                                    .font(.system(size: 13))
                                Spacer()
                                Text("\(day.sessionCount) session\(day.sessionCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(DurationFormatter.short(day.totalActiveDuration))
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                            }
                        }
                    }
                } else {
                    Text("No practice recorded in this period.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .task {
            let base = await model.activeBaseURLForHistory()
            guard let base else { return }
            statistics = model.statistics
            days = model.dailySummaries
            _ = base
        }
        .task(id: period) {
            let fetched = await model.statistics(for: period)
            statistics = fetched.statistics
            days = fetched.days
        }
        .refreshable {
            let fetched = await model.statistics(for: period)
            statistics = fetched.statistics
            days = fetched.days
        }
    }
}

/// Settings: connection details, manual Mac choice, cache controls and diagnostics.
public struct IOSSettingsView: View {

    @ObservedObject private var model: PianoMonitorClientModel
    @State private var token: String = UserDefaults.standard.string(forKey: "apiToken") ?? ""

    public init(model: PianoMonitorClientModel) {
        self.model = model
    }

    public var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Status", value: model.connection.description)
                if let status = model.status {
                    LabeledContent("Mac", value: status.server.hostName)
                    LabeledContent("API version", value: "\(status.server.version)")
                }
                if let updated = model.lastUpdated {
                    LabeledContent("Last updated", value: IOSFormat.time(updated))
                }
                Toggle("Show cached data", isOn: .constant(true))
                    .disabled(true)
            }

            Section("Discovered Macs") {
                if model.macs.isEmpty {
                    Text("No PianoMonitor Mac found on this network.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.macs) { mac in
                        Button {
                            model.preferredMacID = mac.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(mac.name)
                                    if let host = mac.host, let port = mac.port {
                                        Text("\(host):\(port)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("resolving…")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if model.status?.server.hostName == mac.name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Access token") {
                SecureField("Optional token", text: $token)
                    .onSubmit { save() }
                Button("Save token") { save() }
                Text("Only needed if a token was set on the Mac. The iOS app can read practice data and cannot change anything.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Cache") {
                Button("Clear cached data", role: .destructive) {
                    model.clearCache()
                }
            }

            Section("About") {
                Text("PianoMonitor is a viewer for practice time recorded on your Mac. Audio analysis never runs on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func save() {
        UserDefaults.standard.set(token, forKey: "apiToken")
        model.updateToken(token)
    }
}
