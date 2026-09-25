import PianoMonitorKit
import SwiftUI

/// Level meter plus a downsampled waveform.
///
/// Cost control, as required by the spec:
/// - the engine is only asked for a waveform while this view is on screen (`setWaveformVisible`),
/// - the data is already reduced to ~600 floats by `AudioEngine`,
/// - drawing happens only when the published status changes, which the service throttles to the
///   current `AnalysisMode` refresh rate (2 fps in the background, up to 20 fps in analysis mode).
public struct WaveformView: View {

    private let waveform: [Float]
    private let levelDB: Float
    private let noiseFloorDB: Float
    private let isPlaying: Bool

    public init(waveform: [Float], levelDB: Float, noiseFloorDB: Float, isPlaying: Bool) {
        self.waveform = waveform
        self.levelDB = levelDB
        self.noiseFloorDB = noiseFloorDB
        self.isPlaying = isPlaying
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                // The zero line, so a flat quiet signal still reads as "nothing here" rather than a bug.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)

                if waveform.count >= 2 {
                    waveformPath(in: size)
                        .stroke(
                            isPlaying ? Color.accentColor : Color.secondary,
                            style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                        )
                } else {
                    // No waveform (view just appeared, or capture is stopped).
                    Text("—")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .accessibilityLabel("Input waveform")
    }

    /// Builds a vertical min/max envelope: one line per column, which is the standard way to draw
    /// audio cheaply and still show its true amplitude.
    private func waveformPath(in size: CGSize) -> Path {
        var path = Path()
        let columns = waveform.count / 2
        guard columns > 0 else { return path }
        let columnWidth = size.width / CGFloat(columns)
        let halfHeight = size.height / 2
        for column in 0..<columns {
            let minimum = CGFloat(waveform[column * 2])
            let maximum = CGFloat(waveform[column * 2 + 1])
            let x = columnWidth * CGFloat(column) + columnWidth / 2
            // Clamp to the view: a signal above 0 dBFS would otherwise draw outside the box.
            let top = halfHeight - min(1, max(-1, maximum)) * halfHeight
            let bottom = halfHeight - min(1, max(-1, minimum)) * halfHeight
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: max(bottom, top + 0.5)))
        }
        return path
    }
}

/// Compact horizontal level meter, used in the menu bar popover where vertical space is tight.
public struct LevelMeterView: View {

    private let levelDB: Float
    private let noiseFloorDB: Float

    public init(levelDB: Float, noiseFloorDB: Float) {
        self.levelDB = levelDB
        self.noiseFloorDB = noiseFloorDB
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(levelDB)) decibels")
    }

    /// Maps -60…0 dBFS onto 0…1, with a floor so silence is visibly empty.
    private var fraction: CGFloat {
        let clamped = min(0, max(-60, levelDB))
        return CGFloat((clamped + 60) / 60)
    }
}

/// The `● Playing` / `○ Idle` / `⚠ Input Disconnected` indicator.
public struct StatusIndicatorView: View {

    private let status: LiveStatus

    public init(status: LiveStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    private var text: String {
        if status.connection.isDegraded {
            return status.connection.shortDescription
        }
        switch status.state {
        case .playing: return "Playing"
        case .pause: return "Paused"
        case .idle: return "Idle"
        }
    }

    private var color: Color {
        if status.connection.isDegraded { return .orange }
        switch status.state {
        case .playing: return .green
        case .pause: return .yellow
        case .idle: return .secondary
        }
    }
}
