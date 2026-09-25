import AVFoundation
import Foundation

/// Which processing profile the audio pipeline is currently in.
///
/// This is the single most important low-power lever in the app. The DSP cost and the
/// UI refresh cadence both scale from here.
///
/// - `eco`: default background mode. Cheap time-domain only analysis (RMS/peak/onset
///   envelope). No FFT at all. Waveform UI ~2 fps, and only if a window is open.
/// - `balanced`: menu bar popover is open. Adds a small FFT for spectral cues and a
///   smoother waveform at ~8 fps.
/// - `analysis`: the Tempo Analyzer window is visible and needs real spectral resolution.
///   Highest cost; the user explicitly asked for it, and it stops when the window closes.
public enum AnalysisMode: String, Codable, Sendable, CaseIterable {
    case eco
    case balanced
    case analysis

    /// Target refresh rate for waveform/level UI, in frames per second.
    public var uiRefreshHz: Double {
        switch self {
        case .eco: return 2
        case .balanced: return 8
        case .analysis: return 20
        }
    }

    /// Whether the tempo analyzer should run its (more expensive) spectral gate.
    public var runsTempoSpectralGate: Bool {
        switch self {
        case .eco, .balanced: return false
        case .analysis: return true
        }
    }

    /// Stable integer form, for lock-free storage in an atomic.
    public var rawValueIndex: Int {
        switch self {
        case .eco: return 0
        case .balanced: return 1
        case .analysis: return 2
        }
    }

    public init(index: Int) {
        switch index {
        case 2: self = .analysis
        case 1: self = .balanced
        default: self = .eco
        }
    }
}

/// How aggressively to shrink the audio hardware buffers.
///
/// Monitoring is the one place where latency is the product: the player hears their own keystroke
/// late by however long the round trip takes, and anything past roughly 10 ms stops feeling like an
/// instrument and starts feeling like a recording. The hardware IO buffer is the dominant term —
/// macOS defaults to 512 frames, which is 10.7 ms *each way* at 48 kHz — and `AVAudioEngine` exposes
/// no way to change it, so it is set on the CoreAudio device.
public enum LatencyProfile: String, Codable, CaseIterable, Sendable {
    /// Smallest buffer the device will accept. Best feel; needs a driver that copes.
    case minimal
    /// A deliberately modest request: roughly 2.7 ms per direction at 48 kHz.
    case low
    /// macOS's own default. Only sensible if a device misbehaves at smaller sizes.
    case safe

    /// Buffer size to request. The device may clamp this; the achieved value is read back.
    public var targetBufferFrames: Int {
        switch self {
        case .minimal: return 32
        case .low: return 128
        case .safe: return 512
        }
    }

    public var summary: String {
        switch self {
        case .minimal: return "Minimal (smallest the device allows)"
        case .low: return "Low (≈2.7 ms per direction at 48 kHz)"
        case .safe: return "Safe (macOS default, 512 frames)"
        }
    }
}
