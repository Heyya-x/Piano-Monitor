import AVFoundation
import Foundation
import PianoMonitorKit

// A command-line bench for the parts of PianoMonitor that need real hardware.
//
// The unit tests validate the detector and tempo analyzer against *synthetic* signals, which cannot
// answer the only question that really matters: does this recognise a TOP1 piano in this room? This
// tool closes that gap. It runs the exact production code paths (`AudioEngine`,
// `BasicPianoDetector`, `TempoAnalyzer`) against live input and prints the raw evidence, so the
// thresholds can be judged against reality rather than assumption.
//
// Usage:
//   swift run PianoMonitorAnalyzer devices
//   swift run PianoMonitorAnalyzer listen [--seconds N] [--input <uid|substring>] [--verbose]
//   swift run PianoMonitorAnalyzer session [--seconds N]     # state machine + session timing

// MARK: - Argument parsing

struct Options {
    var command = "listen"
    var seconds: Double = 20
    var inputMatch: String?
    var verbose = false
    var quiet = false

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var rest = Array(arguments.dropFirst())
        // The first non-flag argument is the command; anything else is an option.
        if let first = rest.first, !first.hasPrefix("--") {
            options.command = first
            rest.removeFirst()
        }
        var iterator = rest.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--seconds":
                if let value = iterator.next(), let seconds = Double(value) { options.seconds = seconds }
            case "--input":
                options.inputMatch = iterator.next()
            case "--verbose":
                options.verbose = true
            case "--quiet":
                options.quiet = true
            default:
                break
            }
        }
        return options
    }
}

let options = Options.parse(CommandLine.arguments)

if options.verbose {
    Log.isVerbose = true
}

// MARK: - Formatting helpers

func db(_ value: Float) -> String { String(format: "%6.1f", value) }
func f(_ value: Float, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", value) }
func bar(_ fraction: Float, width: Int = 28) -> String {
    let filled = Int(max(0, min(1, fraction)) * Float(width))
    return String(repeating: "#", count: filled) + String(repeating: ".", count: width - filled)
}

func printHeader(_ title: String) {
    print("")
    print("=== \(title) ===")
}

// MARK: - devices

func runDevices() {
    let manager = AudioDeviceManager()
    printHeader("Core Audio devices")
    let all = manager.allDevices()
    if all.isEmpty {
        print("No audio devices found.")
    }
    for device in all {
        let channels = "in \(device.inputChannelCount)ch / out \(device.outputChannelCount)ch"
        let rate = device.nominalSampleRate > 0 ? String(format: "%.0f Hz", device.nominalSampleRate) : "—"
        print("  \(device.name)")
        print("      uid: \(device.uid)")
        print("      \(device.transportDescription) · \(channels) · \(rate)")
    }
    if let input = manager.defaultInputDevice() {
        print("\nSystem default input:  \(input.name)\(input.isVirtual ? "  (virtual — loopback devices capture output, not a microphone)" : "")")
    }
    if let output = manager.defaultOutputDevice() {
        print("System default output: \(output.name)")
    }
    print("\nTip: connect the TOP1, then re-run `devices` and use the UID with `listen --input`.")
}

// MARK: - Live capture

/// Collects statistics over a capture window, using the production detector.
final class CaptureStatistics: @unchecked Sendable {
    private let lock = NSLock()

    private(set) var frames = 0
    private(set) var playingFrames = 0
    private(set) var onsets = 0
    private(set) var peakConfidence: Float = 0
    private(set) var confidenceSum: Float = 0
    private(set) var rmsSumDB: Float = 0
    private(set) var peakDB: Float = -120
    private(set) var periodicities: [Float] = []
    private(set) var noiseFloorDB: Float = -120

    func record(_ result: DetectionResult, onset: Bool) {
        lock.lock()
        defer { lock.unlock() }
        frames += 1
        if result.isPlaying { playingFrames += 1 }
        if onset { onsets += 1 }
        peakConfidence = max(peakConfidence, result.confidence)
        confidenceSum += result.confidence
        rmsSumDB += result.rmsDB
        peakDB = max(peakDB, result.peakDB)
        noiseFloorDB = result.noiseFloorDB
        if result.features.periodicity > 0 {
            periodicities.append(result.features.periodicity)
        }
    }

    func summary(seconds: Double) -> String {
        lock.lock()
        defer { lock.unlock() }
        let playingFraction = frames == 0 ? 0 : Float(playingFrames) / Float(frames)
        let meanConfidence = frames == 0 ? 0 : confidenceSum / Float(frames)
        let meanRMS = frames == 0 ? -120 : rmsSumDB / Float(frames)
        let sorted = periodicities.sorted()
        let medianPeriodicity = sorted.isEmpty ? 0 : sorted[sorted.count / 2]

        var lines: [String] = []
        lines.append("")
        lines.append("--- summary over \(f(Float(seconds), 1)) s ---")
        lines.append("analysis frames      : \(frames)  (~\(f(Float(frames) / Float(max(seconds, 0.001)), 1)) fps)")
        lines.append("noise floor          : \(db(noiseFloorDB)) dBFS   <-- should settle near your room's ambience")
        lines.append("mean input level     : \(db(meanRMS)) dBFS")
        lines.append("peak input level     : \(db(peakDB)) dBFS   <-- should be well above the floor while playing")
        lines.append("onset count          : \(onsets)")
        lines.append("mean confidence      : \(f(meanConfidence, 3))")
        lines.append("peak confidence      : \(f(peakConfidence, 3))   (playing threshold \(f(DetectorConfiguration.default.enterPlayingConfidence, 2)))")
        lines.append("median periodicity   : \(f(medianPeriodicity, 4))   <-- >0.5 while playing, ~0.2 for speech/noise")
        lines.append("classified as playing: \(f(playingFraction * 100, 1))% of the time")
        lines.append("")
        if peakConfidence < DetectorConfiguration.default.enterPlayingConfidence {
            lines.append("VERDICT: nothing reached the playing threshold. Either no piano was played, the input")
            lines.append("         device is wrong, or sensitivity needs raising in Settings.")
        } else if medianPeriodicity > 0.5 {
            lines.append("VERDICT: tonal, sustained audio detected — the detector is behaving as designed.")
        } else {
            lines.append("VERDICT: confidence cleared the threshold but periodicity is low; check whether the")
            lines.append("         microphone is clipping or picking up mostly room noise.")
        }
        return lines.joined(separator: "\n")
    }
}

func runCapture(options: Options, collectSessions: Bool) -> Int32 {
    let manager = AudioDeviceManager()

    // Resolve the requested input device, if any.
    var inputUID: String?
    if let match = options.inputMatch {
        let candidates = manager.inputDevices()
        guard let device = candidates.first(where: { $0.uid == match })
            ?? candidates.first(where: { $0.name.localizedCaseInsensitiveContains(match) }) else {
            print("No input device matches '\(match)'. Available:")
            for candidate in candidates { print("  \(candidate.name)  [\(candidate.uid)]") }
            return 2
        }
        inputUID = device.uid
        print("Using input: \(device.name)")
    } else if let device = manager.defaultInputDevice() {
        print("Using system default input: \(device.name)")
    }

    let engine = AudioEngine(devices: manager)
    let configuration = DetectorConfiguration.default
    let detector = BasicPianoDetector(configuration: configuration, sampleRate: 44_100)
    let statistics = CaptureStatistics()

    // Session mode additionally drives the real state machine, so the *timing* of session
    // boundaries can be observed with real playing rather than synthetic frames.
    let machine = collectSessions
        ? PlayingStateMachine(configuration: configuration)
        : nil

    let done = DispatchSemaphore(value: 0)
    let start = Date()
    let updateQueue = DispatchQueue(label: "analyzer.print")

    engine.onFrame = { frame in
        let result = detector.process(frame: frame)
        statistics.record(result, onset: result.onset)
        if let machine, let transition = machine.process(result) {
            let elapsed = Date().timeIntervalSince(start)
            print(String(format: "  [%@] %6.2f s  %@", "session", elapsed, String(describing: transition)))
        }
        if options.verbose {
            Log.isVerbose = true
        }
    }

    engine.onStateChange = { state in
        print("  audio state: \(state.shortDescription)")
    }

    if let inputUID, let device = manager.device(withUID: inputUID) {
        engine.configure(inputDeviceUID: device.uid, outputDeviceUID: nil, monitoringEnabled: false, monitoringGain: 0)
    }
    engine.start()

    // Ask for microphone permission explicitly; the CLI has no Info.plist of its own.
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 30)
    case .denied, .restricted:
        print("Microphone access is denied for this process. Grant it in System Settings → Privacy & Security → Microphone, then re-run.")
        return 3
    default:
        break
    }

    printHeader(collectSessions ? "Live capture + session state machine" : "Live capture")
    print("Listening for \(f(Float(options.seconds), 0)) s. Play the piano now; include some silence and some speech to check rejection.")
    print("")

    // Progress line once per second.
    var lastPrinted = 0
    let timer = DispatchSource.makeTimerSource(queue: updateQueue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let elapsed = Int(Date().timeIntervalSince(start))
        guard elapsed != lastPrinted else { return }
        lastPrinted = elapsed
        let snapshot = statistics
        let line = String(format: "  t=%3ds  frames=%5d  conf=%.2f  floor=%6.1f dB", elapsed, snapshot.frames, snapshot.peakConfidence, snapshot.noiseFloorDB)
        print(line)
    }
    timer.resume()

    DispatchQueue.global().asyncAfter(deadline: .now() + options.seconds) {
        timer.cancel()
        engine.stop()
        done.signal()
    }

    _ = done.wait(timeout: .now() + options.seconds + 10)
    print(statistics.summary(seconds: options.seconds))
    return 0
}

// MARK: - latency

/// Reports what the monitoring path actually costs, with and without the low-latency buffer.
///
/// Measured rather than assumed: the requested buffer size is not always the achieved one, and the
/// buffer is only part of the round trip — the driver latency and the HAL safety offset contribute
/// too. On this machine the output safety offset alone was 48 frames.
func runLatency(options: Options) -> Int32 {
    let manager = AudioDeviceManager()
    printHeader("Monitoring latency")

    let input: AudioDevice?
    if let match = options.inputMatch {
        input = manager.inputDevices().first {
            $0.uid == match || $0.name.localizedCaseInsensitiveContains(match)
        }
        guard input != nil else {
            print("No input device matches '\(match)'. Run `devices` to list them.")
            return 2
        }
    } else {
        input = manager.defaultInputDevice()
    }
    let output = manager.defaultOutputDevice()

    guard let input else {
        print("No input device available.")
        return 2
    }

    print("input : \(input.name)")
    print("output: \(output?.name ?? "system default")")
    print("")

    func describe(_ device: AudioDevice, _ role: String, scope: AudioObjectPropertyScope) {
        let rate = device.nominalSampleRate > 0 ? device.nominalSampleRate : 48_000
        let current = manager.bufferFrameSize(of: device.id)
        let range = manager.bufferFrameSizeRange(of: device.id)
        let latency = manager.deviceLatency(of: device.id, scope: scope)
        let safety = manager.safetyOffset(of: device.id, scope: scope)
        print("  \(role): \(device.name)")
        print("     buffer range  : \(range.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "unknown") frames")
        print("     current buffer: \(current.map(String.init) ?? "?") frames")
        print("     driver latency: \(latency) frames, safety offset: \(safety) frames")
        if let current {
            print(String(format: "     buffer cost   : %.2f ms", Double(current) / rate * 1000))
        }
    }

    print("Before (as the device is now):")
    describe(input, "input ", scope: kAudioObjectPropertyScopeInput)
    if let output { describe(output, "output", scope: kAudioObjectPropertyScopeOutput) }
    print("")

    // Apply each profile and report what the hardware ends up at. This is destructive to the current
    // buffer setting, so the original values are restored afterwards.
    let originalInput = manager.bufferFrameSize(of: input.id)
    let originalOutput = output.flatMap { manager.bufferFrameSize(of: $0.id) }

    print("After applying each latency profile:")
    for profile in LatencyProfile.allCases {
        var notes: [String] = []
        let inFrames = manager.setBufferFrameSize(profile.targetBufferFrames, on: input.id)
        let outFrames = output.flatMap { manager.setBufferFrameSize(profile.targetBufferFrames, on: $0.id) }

        let inRate = input.nominalSampleRate > 0 ? input.nominalSampleRate : 48_000
        let outRate = (output?.nominalSampleRate ?? 0) > 0 ? (output?.nominalSampleRate ?? 48_000) : 48_000
        let inBuffer = Double(inFrames ?? 0) / inRate * 1000
        let outBuffer = Double(outFrames ?? 0) / outRate * 1000
        let inExtra = Double(manager.deviceLatency(of: input.id, scope: kAudioObjectPropertyScopeInput)
            + manager.safetyOffset(of: input.id, scope: kAudioObjectPropertyScopeInput)) / inRate * 1000
        var outExtra: Double = 0
        if let output {
            outExtra = Double(manager.deviceLatency(of: output.id, scope: kAudioObjectPropertyScopeOutput)
                + manager.safetyOffset(of: output.id, scope: kAudioObjectPropertyScopeOutput)) / outRate * 1000
        }
        if inFrames != profile.targetBufferFrames { notes.append("input clamped") }
        if let outFrames, outFrames != profile.targetBufferFrames { notes.append("output clamped") }

        print(String(format: "  %-8@ request %4d frames -> in %@/out %@ frames, buffers %.1f + %.1f ms, drivers %.1f + %.1f ms  =  %.1f ms round trip%@",
                     profile.rawValue as NSString,
                     profile.targetBufferFrames,
                     (inFrames.map(String.init) ?? "?") as NSString,
                     (outFrames.map(String.init) ?? "?") as NSString,
                     inBuffer, outBuffer, inExtra, outExtra,
                     inBuffer + outBuffer + inExtra + outExtra,
                     notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"))
    }

    // Restore.
    if let originalInput { manager.setBufferFrameSize(originalInput, on: input.id) }
    if let output, let originalOutput { manager.setBufferFrameSize(originalOutput, on: output.id) }

    print("")
    print("Buffers restored to their original values.")
    print("The app's own measured figure (including the engine's report) is on the Dashboard under")
    print("\"Monitor latency\", and in GET /api/diagnostics as roundTripLatencyMilliseconds.")
    return 0
}

// MARK: - selftest

/// Runs the whole analysis chain over the shared synthetic signals.
///
/// This is the hardware-free half of validation: it proves the detector and tempo analyzer still
/// behave as designed on this machine, so a bad result from `listen` can be attributed to the
/// microphone or the room rather than to the code.
func runSelfTest() -> Int32 {
    printHeader("Self-test (no hardware required)")

    var failures = 0
    func check(_ label: String, _ actual: Float, _ expected: String, _ passed: Bool) {
        let mark = passed ? "PASS" : "FAIL"
        if !passed { failures += 1 }
        print(String(format: "  [%@] %-28s %8.3f   (expected %@)", mark, (label as NSString).utf8String!, actual, expected))
    }

    /// Runs a signal through the detector and reports peak confidence and playing fraction.
    func analyse(_ samples: [Float]) -> (peak: Float, playingFraction: Float, onsets: Int) {
        let detector = BasicPianoDetector(configuration: .default, sampleRate: SyntheticSignal.sampleRate)
        var peak: Float = 0
        var playing = 0
        var total = 0
        for frame in SyntheticSignal.frames(from: samples) {
            let result = detector.process(frame: frame)
            peak = max(peak, result.confidence)
            if result.isPlaying { playing += 1 }
            total += 1
        }
        return (peak, total == 0 ? 0 : Float(playing) / Float(total), detector.onsetCountInWindow)
    }

    let threshold = DetectorConfiguration.default.enterPlayingConfidence

    // --- Detector -----------------------------------------------------------------------------
    print("\n  Piano detection")
    let silence = analyse(SyntheticSignal.silence(seconds: 4))
    check("silence", silence.peak, "< \(f(threshold, 2))", silence.peak < threshold)

    let noise = analyse(SyntheticSignal.silence(seconds: 4, levelDB: -55, seed: 42))
    check("ambient noise", noise.peak, "< \(f(threshold, 2))", noise.peak < threshold)

    let piano = analyse(SyntheticSignal.pianoNotes(seconds: 6))
    check("continuous playing", piano.peak, ">= \(f(threshold, 2))", piano.peak >= threshold)
    check("playing fraction", piano.playingFraction, "> 0.75", piano.playingFraction > 0.75)

    let single = analyse(SyntheticSignal.pianoNotes(seconds: 6, notesPerSecond: 1 / 1.5, gapFraction: 0.5))
    check("isolated notes", single.peak, ">= \(f(threshold, 2))", single.peak >= threshold)

    print("\n  Rejection")
    let metronome = analyse(SyntheticSignal.metronome(seconds: 6, bpm: 100))
    check("metronome fraction", metronome.playingFraction, "< 0.25", metronome.playingFraction < 0.25)

    let speech = analyse(SyntheticSignal.speech(seconds: 8))
    check("speech fraction", speech.playingFraction, "< 0.5", speech.playingFraction < 0.5)

    let combined = analyse(SyntheticSignal.mix(
        SyntheticSignal.pianoNotes(seconds: 6, notesPerSecond: 2),
        SyntheticSignal.metronome(seconds: 6, bpm: 100)
    ))
    check("piano + metronome", combined.playingFraction, "> 0.5", combined.playingFraction > 0.5)

    // --- Tempo --------------------------------------------------------------------------------
    print("\n  Tempo measurement")
    for bpm in [60.0, 80.0, 96.0, 100.0, 120.0] {
        var configuration = TempoConfiguration.default
        configuration.useSpectralClickGate = false
        let analyzer = TempoAnalyzer(configuration: configuration, sampleRate: SyntheticSignal.sampleRate)
        for frame in SyntheticSignal.frames(from: SyntheticSignal.metronome(seconds: 20, bpm: bpm)) {
            analyzer.process(frame: frame)
        }
        let measured = analyzer.snapshot().bpm
        let error = measured.map { abs($0 - bpm) } ?? .infinity
        check(String(format: "%.0f BPM", bpm), Float(measured ?? 0), String(format: "%.1f +/- 1.5", bpm), error < 1.5)
    }

    // --- Ring buffer --------------------------------------------------------------------------
    print("\n  Realtime plumbing")
    let ring = AudioRingBuffer(slotCount: 3, capacity: 4_096)
    let buffer = [Float](repeating: 0.25, count: 1_024)
    for index in 0..<200 {
        buffer.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, frameCount: 1_024, timestamp: Double(index))
        }
        var out = [Float](repeating: 0, count: 4_096)
        _ = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, capacity: 4_096) }
    }
    check("ring buffer drops", Float(ring.droppedBufferCount), "== 0", ring.droppedBufferCount == 0)

    print("")
    if failures == 0 {
        print("All self-tests passed. The analysis chain is behaving on this machine.")
        print("If `listen` still detects nothing, the problem is the input device or the room, not the code.")
    } else {
        print("\(failures) self-test(s) FAILED — the analysis chain is not behaving as designed.")
    }
    return failures == 0 ? 0 : 1
}

// MARK: - Entry point

switch options.command {
case "devices":
    runDevices()
    exit(0)
case "selftest":
    exit(runSelfTest())
case "latency":
    exit(runLatency(options: options))
case "listen":
    exit(runCapture(options: options, collectSessions: false))
case "session":
    exit(runCapture(options: options, collectSessions: true))
default:
    print("""
    PianoMonitorAnalyzer — hardware bench for the audio pipeline.

      devices                        list Core Audio devices and their UIDs
      selftest                       run the analysis chain over synthetic signals (no hardware)
      latency [--input NAME|UID]     measure the monitoring round trip and per-profile buffer sizes
      listen  [--seconds N] [--input NAME|UID] [--verbose]
                                     analyse live input and print detector statistics
      session [--seconds N] [--input NAME|UID]
                                     additionally run the practice state machine and log transitions

    Notes:
      * The first run prompts for microphone access.
      * `--input` accepts a device name substring or an exact UID from `devices`.
      * Nothing is recorded to disk; this tool only prints statistics.
    """)
    exit(0)
}
