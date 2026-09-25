import Accelerate
import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// Thin, reusable FFT wrapper.
///
/// PianoMonitor only transforms short frames (≤ 2048 samples) a handful of times per second, and
/// only when the analysis profile asks for spectral features at all — `.eco` never constructs one
/// of these. Everything here is pre-allocated and safe to call repeatedly from a single queue.
public final class FFTProcessor {

    public let size: Int
    public let binCount: Int
    public let binWidth: Float

    private let setup: vDSP_DFT_Setup
    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private var window: [Float]
    private var magnitudesStorage: [Float]

    /// - Parameters:
    ///   - size: power-of-two transform length.
    ///   - sampleRate: used only to derive `binWidth`.
    public init?(size: Int, sampleRate: Double) {
        guard size >= 8, size & (size - 1) == 0 else { return nil }
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else { return nil }
        self.setup = setup
        self.size = size
        self.binCount = size / 2
        self.binWidth = Float(sampleRate) / Float(size)
        self.realIn = [Float](repeating: 0, count: size)
        self.imagIn = [Float](repeating: 0, count: size)
        self.realOut = [Float](repeating: 0, count: size)
        self.imagOut = [Float](repeating: 0, count: size)
        self.window = [Float](repeating: 0, count: size)
        self.magnitudesStorage = [Float](repeating: 0, count: size / 2)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
    }

    /// Windowed magnitude spectrum of the most recent `size` samples.
    /// `frame` must contain exactly `size` samples; shorter input is zero-padded.
    public func magnitudes(of frame: UnsafePointer<Float>, count: Int) -> [Float] {
        let usable = min(count, size)
        for index in 0..<usable {
            realIn[index] = frame[index] * window[index]
        }
        if usable < size {
            for index in usable..<size { realIn[index] = 0 }
        }
        for index in 0..<size { imagIn[index] = 0 }

        realIn.withUnsafeBufferPointer { realPointer in
            imagIn.withUnsafeBufferPointer { imagPointer in
                realOut.withUnsafeMutableBufferPointer { realOutput in
                    imagOut.withUnsafeMutableBufferPointer { imagOutput in
                        vDSP_DFT_Execute(
                            setup,
                            realPointer.baseAddress!,
                            imagPointer.baseAddress!,
                            realOutput.baseAddress!,
                            imagOutput.baseAddress!
                        )
                    }
                }
            }
        }

        realOut.withUnsafeBufferPointer { realPointer in
            imagOut.withUnsafeBufferPointer { imagPointer in
                magnitudesStorage.withUnsafeMutableBufferPointer { out in
                    for index in 0..<binCount {
                        let re = realPointer[index]
                        let im = imagPointer[index]
                        out[index] = (re * re + im * im).squareRoot()
                    }
                }
            }
        }
        return magnitudesStorage
    }
}

/// Rolling analysis window.
///
/// The audio tap hands us variable-size blocks, but every spectral feature needs a fixed frame
/// length. This keeps the most recent `size` samples in a single reusable buffer so the analysis
/// path allocates nothing per frame.
public struct FrameAssembler {
    public let size: Int
    private var storage: [Float]
    private var filled = 0

    public init(size: Int) {
        self.size = size
        self.storage = [Float](repeating: 0, count: size)
    }

    /// Appends a block, discarding the oldest samples once the window is full.
    public mutating func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        if samples.count >= size {
            // Fast path: only the tail matters.
            storage.replaceSubrange(0..<size, with: samples.suffix(size))
            filled = size
            return
        }
        let overflow = max(0, filled + samples.count - size)
        if overflow > 0 {
            storage.removeFirst(overflow)
            filled -= overflow
        }
        storage.append(contentsOf: samples)
        filled += samples.count
    }

    public var isFull: Bool { filled >= size }

    /// Provides the window to `body` without copying.
    public func withFrame<R>(_ body: (UnsafePointer<Float>, Int) -> R) -> R? {
        guard filled > 0 else { return nil }
        return storage.withUnsafeBufferPointer { pointer in
            body(pointer.baseAddress!, filled)
        }
    }
}

/// Second-order IIR section (RBJ cookbook). One section is enough for the tempo analyzer's
/// click band-pass and the detector's rumble high-pass.
public struct Biquad: Sendable {
    public var b0: Float = 1
    public var b1: Float = 0
    public var b2: Float = 0
    public var a1: Float = 0
    public var a2: Float = 0

    // Direct Form I state.
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    public init() {}

    public static func lowPass(cutoffHz: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let omega = 2 * Double.pi * cutoffHz / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosOmega = cos(omega)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = Float((1 - cosOmega) / 2 / a0)
        filter.b1 = Float((1 - cosOmega) / a0)
        filter.b2 = filter.b0
        filter.a1 = Float(-2 * cosOmega / a0)
        filter.a2 = Float((1 - alpha) / a0)
        return filter
    }

    public static func highPass(cutoffHz: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let omega = 2 * Double.pi * cutoffHz / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosOmega = cos(omega)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = Float((1 + cosOmega) / 2 / a0)
        filter.b1 = Float(-(1 + cosOmega) / a0)
        filter.b2 = filter.b0
        filter.a1 = Float(-2 * cosOmega / a0)
        filter.a2 = Float((1 - alpha) / a0)
        return filter
    }

    /// Constant-skirt-gain band-pass, used to isolate the metronome click band.
    public static func bandPass(centerHz: Double, bandwidthHz: Double, sampleRate: Double) -> Biquad {
        let omega = 2 * Double.pi * centerHz / sampleRate
        let alpha = sin(omega) * sinh(log(2.0) / 2 * bandwidthHz / centerHz * omega / sin(omega))
        let cosOmega = cos(omega)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = Float(alpha / a0)
        filter.b1 = 0
        filter.b2 = Float(-alpha / a0)
        filter.a1 = Float(-2 * cosOmega / a0)
        filter.a2 = Float((1 - alpha) / a0)
        return filter
    }

    /// Processes in place. Direct Form I: one multiply-add chain, no allocation.
    public mutating func process(_ samples: inout [Float]) {
        for index in 0..<samples.count {
            let x0 = samples[index]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            samples[index] = y0
        }
    }

    public mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for index in 0..<count {
            let x0 = samples[index]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            samples[index] = y0
        }
    }

    public mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }
}

/// Shared scalar helpers. Kept free-standing so both analyzers use identical maths —
/// divergence here is a classic source of "why do the two meters disagree" bugs.
public enum DSP {

    /// Linear amplitude to dBFS, with a floor instead of `-inf`.
    @inline(__always)
    public static func decibels(_ amplitude: Float, floor: Float = -120) -> Float {
        guard amplitude > 0 else { return floor }
        return max(floor, 20 * log10(amplitude))
    }

    @inline(__always)
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
        return (sum / Float(samples.count)).squareRoot()
    }

    @inline(__always)
    public static func peak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_maxmgv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    /// Normalised autocorrelation peak over the plausible musical pitch range.
    ///
    /// This is the primary "is this a musical tone?" cue, and it is deliberately computed in the
    /// time domain:
    /// - A piano note is periodic, so its waveform correlates strongly with itself at the pitch
    ///   period: a fundamental of 55–2200 Hz puts the period between 0.45 and 18 ms.
    /// - A metronome click, a chair scrape or a spoken fricative is *not* periodic, so no lag
    ///   agrees well.
    ///
    /// Unlike a single-bin spectral peak ratio, this is stable across window positions, and it needs
    /// no FFT, so `.eco` mode gets a real tonal test for free.
    ///
    /// **Cost control.** A full autocorrelation is O(n²): 2048 samples across 780 lags is ~1.7 M
    /// multiply-accumulates, which at 40 blocks/s would cost a few percent of a core — unacceptable
    /// for an always-on background tool. The frame is therefore decimated by `decimation` first.
    /// The highest piano fundamental we care about is ~2.2 kHz, so ~11 kHz is ample; decimating by
    /// 4 keeps the pitch range intact while cutting the work by roughly 16x.
    ///
    /// - Returns: the best normalised correlation in `0...1`, or 0 when the frame is too short.
    public static func periodicity(
        _ samples: UnsafePointer<Float>,
        count: Int,
        sampleRate: Double,
        decimation: Int = 4,
        minimumFrequency: Double = 55,
        maximumFrequency: Double = 2_200
    ) -> Float {
        let factor = max(1, decimation)
        let reducedCount = count / factor
        guard reducedCount > 64 else { return 0 }
        let reducedRate = sampleRate / Double(factor)

        let minimumLag = max(2, Int(reducedRate / maximumFrequency))
        let maximumLag = min(reducedCount / 2, Int(reducedRate / minimumFrequency))
        guard maximumLag > minimumLag else { return 0 }

        // Sum of squares over the decimated frame: a silent frame has no periodicity.
        var energy: Float = 0
        for index in stride(from: 0, to: reducedCount * factor, by: factor) {
            let value = samples[index]
            energy += value * value
        }
        guard energy > 1e-9 else { return 0 }

        var best: Float = 0
        for lag in minimumLag...maximumLag {
            var sum: Float = 0
            var energyA: Float = 0
            var energyB: Float = 0
            var index = 0
            let limit = reducedCount - lag
            while index < limit {
                let a = samples[index * factor]
                let b = samples[(index + lag) * factor]
                sum += a * b
                energyA += a * a
                energyB += b * b
                index += 1
            }
            let denominator = (energyA * energyB).squareRoot()
            guard denominator > 1e-9 else { continue }
            let correlation = sum / denominator
            if correlation > best {
                best = correlation
                // A perfectly periodic frame cannot be beaten; stop early and save the work.
                if best > 0.999 { break }
            }
        }
        return best
    }

    /// Convenience overload for array input (tests and offline analysis).
    public static func periodicity(_ samples: [Float], sampleRate: Double, decimation: Int = 4) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.withUnsafeBufferPointer { pointer in
            periodicity(pointer.baseAddress!, count: samples.count, sampleRate: sampleRate, decimation: decimation)
        }
    }

    /// Spectral centroid in Hz — the "brightness" of the frame. Cheap: one weighted sum.
    public static func spectralCentroid(magnitudes: [Float], binWidth: Float) -> Float {
        var weighted: Float = 0
        var total: Float = 0
        for index in 1..<magnitudes.count {
            weighted += magnitudes[index] * Float(index)
            total += magnitudes[index]
        }
        guard total > 0 else { return 0 }
        return (weighted / total) * binWidth
    }

    /// How far the strongest spectral peak stands above its local neighbourhood.
    ///
    /// This is the robust "is this tonal?" test. A single-bin energy ratio is *not* usable, because
    /// a 1/f (pink) room spectrum already concentrates most of its energy in the lowest bins. Peak
    /// prominence compares each bin against the median of the surrounding bins, so a steep overall
    /// slope cancels out and only genuine harmonic structure remains.
    ///
    /// - Piano: strong harmonic series -> high prominence.
    /// - Metronome click / room noise / fricatives: broad or noisy spectrum -> low prominence.
    public static func spectralPeakProminence(magnitudes: [Float], neighbourhood: Int = 12) -> Float {
        guard magnitudes.count > neighbourhood * 4 else { return 0 }
        var best: Float = 0
        // Skip the lowest bins: DC offset and window leakage live there.
        for index in neighbourhood..<(magnitudes.count - neighbourhood) {
            let value = magnitudes[index]
            guard value > 0 else { continue }
            var window = Array(magnitudes[(index - neighbourhood)...(index + neighbourhood)])
            // Drop the candidate itself so a pure spike cannot raise its own reference.
            window.remove(at: neighbourhood)
            window.sort()
            let median = window[window.count / 2]
            guard median > 0 else { continue }
            let prominence = value / median
            if prominence > best { best = prominence }
        }
        return best
    }
    public static func peakiness(magnitudes: [Float]) -> Float {
        guard magnitudes.count > 1 else { return 0 }
        var maxValue: Float = 0
        var total: Float = 0
        for index in 1..<magnitudes.count {
            let value = magnitudes[index]
            if value > maxValue { maxValue = value }
            total += value
        }
        guard total > 0 else { return 0 }
        return maxValue / total
    }

    /// Half-wave-rectified spectral flux: how much the spectrum *grew* since the last frame.
    /// Robust to the piano's slow decay, which is what makes it a good onset cue.
    public static func positiveFlux(current: [Float], previous: [Float]) -> Float {
        let count = min(current.count, previous.count)
        guard count > 1 else { return 0 }
        var flux: Float = 0
        for index in 1..<count {
            let delta = current[index] - previous[index]
            if delta > 0 { flux += delta }
        }
        // Normalise by total energy so loudness changes do not dominate the cue.
        var total: Float = 0
        for index in 1..<count { total += current[index] }
        guard total > 0 else { return 0 }
        return flux / total
    }
}

#endif
