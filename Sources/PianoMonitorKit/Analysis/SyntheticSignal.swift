import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// Deterministic synthetic audio used for calibration, diagnostics and tests.
///
/// These live in the Kit rather than in the test target for two reasons:
///   * `PianoMonitorAnalyzer selftest` can verify the whole analysis chain on any machine, with no
///     piano and no microphone, so a failing detector can be told apart from a failing input device;
///   * the unit tests and the CLI then exercise the *same* reference signals.
///
/// Everything is seeded, so a given call always produces identical samples.
public enum SyntheticSignal {

    public static let sampleRate: Double = 44_100

    /// Deterministic pseudo-random source (no `Float.random` nondeterminism between runs).
    public struct SeededRandom {
        private var state: UInt64
        public init(seed: UInt64 = 0x5EED_1234_ABCD_9876) { self.state = seed }
        public mutating func next() -> Float {
            // xorshift64*
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let value = state &* 2_685_821_657_736_338_717
            return Float(Int64(bitPattern: value >> 11)) / Float(1 << 52)
        }
        /// Uniform noise in `-amplitude...amplitude`.
        public mutating func noise(_ amplitude: Float) -> Float {
            next() * amplitude
        }

        /// 1/f ("pink") noise, which is what real room ambience and microphone self-noise look
        /// like: energy concentrated at low frequencies rather than spread evenly.
        ///
        /// This matters for the tests. White noise has as much energy at 10 kHz as at 100 Hz, which
        /// is nothing like a room, and it would make the detector's spectral cues look far better
        /// than they are.
        private var pinkState: [Float] = [0, 0, 0, 0, 0, 0, 0]
        public mutating func pink(_ amplitude: Float) -> Float {
            // Paul Kellet's economical pink-noise filter.
            let white = next()
            pinkState[0] = 0.99886 * pinkState[0] + white * 0.0555179
            pinkState[1] = 0.99332 * pinkState[1] + white * 0.0750759
            pinkState[2] = 0.96900 * pinkState[2] + white * 0.1538520
            pinkState[3] = 0.86650 * pinkState[3] + white * 0.3104856
            pinkState[4] = 0.55000 * pinkState[4] + white * 0.5329522
            pinkState[5] = -0.7616 * pinkState[5] - white * 0.0168980
            let value = pinkState[0] + pinkState[1] + pinkState[2] + pinkState[3]
                + pinkState[4] + pinkState[5] + pinkState[6] + white * 0.5362
            pinkState[6] = white * 0.115926
            return value * amplitude * 0.11
        }
    }

    /// Additive noise at a given dBFS level.
    public static func silence(seconds: Double, levelDB: Float = -85, seed: UInt64 = 1) -> [Float] {
        var random = SeededRandom(seed: seed)
        let amplitude = pow(10, levelDB / 20)
        return (0..<Int(seconds * sampleRate)).map { _ in random.pink(amplitude) }
    }

    /// A sequence of piano-like notes.
    ///
    /// Each note is a harmonic stack with a fast attack and a slow exponential decay, which is the
    /// property that separates it from a click. `detached` inserts true silence between notes;
    /// otherwise notes overlap slightly, as legato playing does.
    public static func pianoNotes(
        seconds: Double,
        notesPerSecond: Double = 4,
        fundamental: Double = 261.63,
        amplitude: Float = 0.25,
        decaySeconds: Double = 0.9,
        gapFraction: Double = 0.15,
        jitter: Double = 0,
        seed: UInt64 = 7
    ) -> [Float] {
        var output = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var random = SeededRandom(seed: seed)
        let noteSpacing = 1.0 / notesPerSecond
        var time = 0.0
        var noteIndex = 0
        // A simple ascending/descending scale so successive notes differ, like real playing.
        let scale: [Double] = [0, 2, 4, 5, 7, 9, 11, 12]
        while time < seconds {
            let interval = noteSpacing * (1 + jitter * Double(random.next()))
            let frequency = fundamental * pow(2, scale[noteIndex % scale.count] / 12)
            let length = max(0.05, interval * (0.6 + 0.4 * (1 - gapFraction)))
            let startSample = Int(time * sampleRate)
            let noteSamples = Int(length * sampleRate)
            for offset in 0..<noteSamples {
                let index = startSample + offset
                guard index >= 0, index < output.count else { break }
                let t = Double(offset) / sampleRate
                // Attack 8 ms, then exponential decay.
                let attack = min(1.0, t / 0.008)
                let decay = exp(-t / decaySeconds)
                let envelope = Float(attack * decay)
                var sample = sin(2 * .pi * frequency * t)
                sample += 0.45 * sin(2 * .pi * frequency * 2 * t)
                sample += 0.22 * sin(2 * .pi * frequency * 3 * t)
                sample += 0.10 * sin(2 * .pi * frequency * 4 * t)
                output[index] += Float(sample) * amplitude * envelope / 1.77
            }
            time += interval
            noteIndex += 1
        }
        // A touch of room noise so the noise-floor estimator has something realistic to track.
        for index in 0..<output.count {
            output[index] += random.pink(0.000_02)
        }
        return output
    }

    /// Metronome click train. Short broadband transient in the click band — no sustain at all.
    public static func metronome(
        seconds: Double,
        bpm: Double,
        amplitude: Float = 0.30,
        jitterMilliseconds: Double = 0,
        seed: UInt64 = 3
    ) -> [Float] {
        var output = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var random = SeededRandom(seed: seed)
        let interval = 60.0 / bpm
        var time = 0.0
        while time < seconds {
            let startSample = Int(time * sampleRate)
            let clickLength = Int(0.012 * sampleRate)
            let frequency = 3_200.0 + 600.0 * Double(random.next())
            for offset in 0..<clickLength {
                let index = startSample + offset
                guard index >= 0, index < output.count else { break }
                let t = Double(offset) / sampleRate
                let envelope = Float(exp(-t / 0.0018))
                let tonal = sin(2 * .pi * frequency * t) * 0.7
                let sample = Float(tonal) + random.noise(0.3)
                output[index] += sample * amplitude * envelope
            }
            if jitterMilliseconds > 0 {
                time += interval + (Double(random.next()) - 0.5) * 2 * jitterMilliseconds / 1000
            } else {
                time += interval
            }
        }
        // Room noise, same as the piano signal.
        for index in 0..<output.count {
            output[index] += random.pink(0.000_02)
        }
        return output
    }

    /// Speech-like signal.
    ///
    /// Real speech is *not* a steady musical tone: it is a sequence of syllables with irregular
    /// pitch, formant-weighted harmonics, a variable onset, and real gaps between words. Modelling
    /// those properties is what makes this a fair test of the detector's speech rejection, rather
    /// than a test that only passes because the fake signal was too simple.
    public static func speech(seconds: Double, seed: UInt64 = 11) -> [Float] {
        var output = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var random = SeededRandom(seed: seed)

        // Formant-ish weighting: vowel-like energy concentrated in the 300–2500 Hz region.
        func vowelGain(_ harmonic: Int, _ f0: Double) -> Double {
            let frequency: Double = f0 * Double(harmonic)
            let f1: Double = (frequency - 700.0) / 500.0
            let f2: Double = (frequency - 1_600.0) / 700.0
            let formant1: Double = exp(-(f1 * f1))
            let formant2: Double = exp(-(f2 * f2))
            return 0.15 + formant1 + 0.6 * formant2
        }

        var time = 0.0
        while time < seconds {
            // Each syllable: a short voiced burst, then a gap. 4–6 syllables per second.
            let syllableRandom: Double = Double(random.next())
            let gapRandom: Double = Double(random.next())
            let pitchRandom: Double = Double(random.next())
            let syllableLength: Double = 0.09 + 0.06 * syllableRandom
            let gap: Double = 0.05 + 0.13 * gapRandom
            let pitch: Double = 95.0 + 70.0 * pitchRandom
            let startSample = Int(time * sampleRate)
            let syllableSamples = Int(syllableLength * sampleRate)

            for offset in 0..<syllableSamples {
                let index = startSample + offset
                guard index >= 0, index < output.count else { break }
                let t = Double(offset) / sampleRate
                // Voiced onset is not instantaneous, and it dies away like a syllable coda.
                let attack: Double = min(1.0, t / 0.02)
                let decay: Double = exp(-t / (syllableLength * 0.7))
                let envelope: Double = attack * decay
                // Slight vibrato/jitter, so consecutive pitch periods are not perfectly equal.
                let jitter: Double = Double(random.noise(1))
                let wobble: Double = 1.0 + 0.02 * jitter
                var sample: Double = 0
                for harmonic in 1...12 {
                    let gain: Double = vowelGain(harmonic, pitch)
                    if gain < 0.05 { continue }
                    let phase: Double = 2 * Double.pi * pitch * Double(harmonic) * t * wobble
                    sample += gain * sin(phase)
                }
                let scaled: Float = Float(sample / 4.0)
                let amplitude: Float = 0.22
                output[index] += scaled * Float(envelope) * amplitude
            }
            time += syllableLength + gap
        }

        // Room noise underneath, identical to the piano signal.
        for index in 0..<output.count {
            output[index] += random.pink(0.000_02)
        }
        return output
    }

    /// Mixes two signals sample-wise (used for "metronome + piano").
    public static func mix(_ lhs: [Float], _ rhs: [Float]) -> [Float] {
        let count = max(lhs.count, rhs.count)
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            output[index] = a + b
        }
        return output
    }

    /// Chops a long signal into `ProcessedAudioFrame`s the way the audio engine would,
    /// advancing a monotonic timestamp exactly like the real pipeline.
    public static func frames(
        from samples: [Float],
        blockSize: Int = 1_024,
        sampleRate: Double = SyntheticSignal.sampleRate
    ) -> [ProcessedAudioFrame] {
        var result: [ProcessedAudioFrame] = []
        var index = 0
        var time = 0.0
        while index < samples.count {
            let end = min(index + blockSize, samples.count)
            let block = Array(samples[index..<end])
            var peak: Float = 0
            var sumSquares: Float = 0
            for sample in block {
                peak = max(peak, abs(sample))
                sumSquares += sample * sample
            }
            let rms = (sumSquares / Float(block.count)).squareRoot()
            result.append(ProcessedAudioFrame(
                samples: block,
                sampleRate: sampleRate,
                timestamp: time,
                peak: peak,
                rms: rms
            ))
            time += Double(block.count) / sampleRate
            index = end
        }
        return result
    }
}

#endif
