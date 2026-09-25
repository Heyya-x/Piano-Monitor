import AVFoundation
import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// Lock-free triple-buffer hand-off between the realtime audio thread and the analysis queue.
///
/// Why not a lock? The Core Audio tap thread must never block. A `DispatchQueue.sync`, an
/// `NSLock`, or even a heap allocation there risks a dropout — an audible click at best, an
/// engine teardown at worst. So the writer only ever:
///   1. claims a slot in the `free` state (a CAS, no waiting),
///   2. `memcpy`s the samples into a pre-allocated buffer,
///   3. flips the slot to `ready` and atomically publishes it.
///
/// Ownership is strict so no spin loop is ever needed: the **writer** only claims a slot it
/// observes as `free`, and the **reader** only claims the published slot and returns it to
/// `free`. A slot therefore never has two owners.
///
/// If the reader falls behind, the writer silently skips that audio. For a level meter and an
/// onset detector the newest audio matters far more than every sample, and dropping frames is
/// strictly better than stalling the render thread.
public final class AudioRingBuffer: @unchecked Sendable {

    private enum SlotState {
        static let free: Int32 = 0
        static let ready: Int32 = 1
    }

    public struct Frame {
        public let frames: Int
        public let timestamp: Double
    }

    private let capacity: Int
    private let samples: [UnsafeMutablePointer<Float>]
    private let states: [UnsafeMutablePointer<Int32>]
    private var slotFrames: [Int]
    private var slotTimestamps: [Double]
    private let readyIndex: AtomicInt
    private let droppedWrites = AtomicInt(0)
    private let writtenBuffers = AtomicInt(0)
    private let writtenFrameTotal = AtomicInt(0)
    private let readBuffers = AtomicInt(0)

    public init(slotCount: Int = 3, capacity: Int = 16_384) {
        precondition(slotCount >= 2, "double buffering needs at least 2 slots")
        self.capacity = capacity
        self.samples = (0..<slotCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
        self.states = (0..<slotCount).map { _ in
            let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            pointer.initialize(to: SlotState.free)
            return pointer
        }
        self.slotFrames = Array(repeating: 0, count: slotCount)
        self.slotTimestamps = Array(repeating: 0, count: slotCount)
        self.readyIndex = AtomicInt(-1)
    }

    deinit {
        for buffer in samples { buffer.deallocate() }
        for state in states { state.deallocate() }
        readyIndex.deallocate()
        droppedWrites.deallocate()
        writtenBuffers.deallocate()
        writtenFrameTotal.deallocate()
        readBuffers.deallocate()
    }

    private var slotCount: Int { samples.count }

    /// Realtime-thread safe. Called from the `AVAudioNode` tap block: allocates nothing, never blocks.
    public func write(_ source: UnsafePointer<Float>, frameCount: Int, timestamp: Double) {
        let count = min(frameCount, capacity)
        guard count > 0 else { return }

        var target = -1
        for index in 0..<slotCount where states[index].pointee == SlotState.free {
            if OSAtomicCompareAndSwap32Barrier(SlotState.free, SlotState.ready, states[index]) {
                target = index
                break
            }
        }
        guard target >= 0 else {
            // Reader is behind; skip this buffer rather than blocking the audio thread.
            droppedWrites.increment()
            return
        }

        samples[target].update(from: source, count: count)
        slotFrames[target] = count
        slotTimestamps[target] = timestamp
        writtenBuffers.increment()
        writtenFrameTotal.increment()

        let previous = readyIndex.exchange(target)
        if previous >= 0, previous != target {
            // The reader had not yet consumed the older slot: retire it on its behalf.
            states[previous].pointee = SlotState.free
            droppedWrites.increment()
        }
    }

    /// Analysis-thread read. Copies into caller-owned storage.
    /// Returns `nil` when no new audio has arrived since the previous successful read.
    public func read(into destination: UnsafeMutablePointer<Float>, capacity destinationCapacity: Int) -> Frame? {
        let ready = readyIndex.exchange(-1)
        guard ready >= 0, ready < slotCount else { return nil }
        let count = min(slotFrames[ready], destinationCapacity)
        destination.update(from: samples[ready], count: count)
        let timestamp = slotTimestamps[ready]
        states[ready].pointee = SlotState.free
        readBuffers.increment()
        return Frame(frames: count, timestamp: timestamp)
    }

    /// Number of buffers discarded because the analysis queue was too slow.
    public var droppedBufferCount: Int { droppedWrites.value }
    /// Number of buffers successfully published by the audio thread.
    public var totalWrittenBuffers: Int { writtenBuffers.value }
    /// Number of audio frames successfully published by the audio thread.
    public var totalWrittenFrames: Int { writtenFrameTotal.value * 1_024 }
    public var totalReadBuffers: Int { readBuffers.value }
}

#endif
