import Charts
import PianoMonitorKit
import SwiftUI

/// Practice history: per-day totals, session list, and the aggregate figures the spec asks for.
public struct HistoryView: View {

    @ObservedObject private var runtime: PianoMonitorAppRuntime
    @State private var period: StatisticsPeriod = .week
    @State private var statistics = PracticeStatistics.empty
    @State private var days: [PracticeDay] = []
    @State private var sessions: [PracticeSessionSnapshot] = []
    @State private var refreshToken = 0

    public init(runtime: PianoMonitorAppRuntime) {
        self.runtime = runtime
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summary
                    chart
                    sessionList
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: refreshToken) {
            async let statisticsTask = runtime.statistics(period: period)
            async let daysTask = runtime.dailySummaries(days: dayCount)
            async let sessionsTask = runtime.sessions(limit: 100)
            statistics = await statisticsTask
            days = await daysTask
            sessions = await sessionsTask
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SectionHeader("Practice History")
            Spacer()
            Picker("", selection: $period) {
                Text("Today").tag(StatisticsPeriod.day)
                Text("Week").tag(StatisticsPeriod.week)
                Text("Month").tag(StatisticsPeriod.month)
                Text("Year").tag(StatisticsPeriod.year)
                Text("All").tag(StatisticsPeriod.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var dayCount: Int {
        switch period {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .year: return 90
        case .all: return 90
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Totals")
            HStack(alignment: .top, spacing: 30) {
                bigMetric("Total", DurationFormatter.short(statistics.totalActiveDuration))
                bigMetric("Sessions", "\(statistics.sessionCount)")
                bigMetric("Average session", DurationFormatter.short(statistics.averageSessionDuration))
                bigMetric("Longest session", DurationFormatter.short(statistics.longestSessionDuration))
                bigMetric("Streak", "\(statistics.currentStreakDays) day\(statistics.currentStreakDays == 1 ? "" : "s")")
            }
        }
    }

    private func bigMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Daily practice")
            if days.contains(where: { $0.activeDuration > 0 }) {
                Chart(days, id: \.day) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Minutes", day.activeDuration / 60)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 7)) { value in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(MacFormat.weekday(date))
                            }
                        }
                    }
                }
                .frame(height: 130)
            } else {
                Text("Nothing recorded in this period.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Sessions")
            if sessions.isEmpty {
                Text("No sessions yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(sessions) { session in
                    SessionRow(session: session)
                    if session.id != sessions.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

/// One session: date, time range, wall clock and — most importantly — actual playing time.
struct SessionRow: View {

    let session: PracticeSessionSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(MacFormat.day(session.startDate))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110, alignment: .leading)

            Text(MacFormat.range(session.startDate, session.endDate))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)

            Text(DurationFormatter.short(session.activeDuration))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()

            if session.segmentCount > 1 {
                Text("\(session.segmentCount) segments")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            if session.isOpen {
                Text("in progress")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(MacFormat.day(session.startDate)), \(DurationFormatter.short(session.activeDuration)) of playing")
    }
}
