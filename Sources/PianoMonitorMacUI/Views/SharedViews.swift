import PianoMonitorKit
import SwiftUI

/// A labelled value row, used throughout the menu bar and dashboard.
///
/// Deliberately plain: the spec asks for an Apple-like, restrained, "technical" feel rather than a
/// game-like dashboard, so the UI is mostly label/value pairs and one accent colour.
public struct MetricRow: View {
    private let label: String
    private let value: String
    private let emphasis: Bool

    public init(_ label: String, _ value: String, emphasis: Bool = false) {
        self.label = label
        self.value = value
        self.emphasis = emphasis
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: emphasis ? 15 : 12, weight: emphasis ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Section heading used in the dashboard and settings.
public struct SectionHeader: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .kerning(0.6)
    }
}

/// A quiet, inline warning strip for degraded audio states.
public struct WarningBanner: View {
    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundColor(.orange)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// Formatting shared by the macOS screens. Kept in one place so the menu bar, dashboard and history
/// never disagree about how a date or duration reads.
public enum MacFormat {

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let dayShortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    public static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    public static func weekday(_ date: Date) -> String { dayShortFormatter.string(from: date) }
    public static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// `20:31–21:13` for a session row.
    public static func range(_ start: Date, _ end: Date?) -> String {
        guard let end else { return "\(time(start)) – now" }
        return "\(time(start)) – \(time(end))"
    }

    /// Relative freshness for the API/connection indicator: `just now`, `2 min ago`.
    public static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3_600))h ago"
    }
}
