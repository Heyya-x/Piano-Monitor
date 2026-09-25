import Foundation

/// Heap-allocated 32-bit atomic with acquire/release barriers.
///
/// Deliberately not `Synchronization.Atomic` (macOS 15+) because PianoMonitor still ships to
/// Catalina, and deliberately not `os_unfair_lock` because the audio thread must never block.
public struct AtomicInt: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Int32>

    public init(_ value: Int) {
        storage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        storage.initialize(to: Int32(value))
    }

    public func deallocate() {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    public var value: Int {
        Int(storage.pointee)
    }

    public func store(_ newValue: Int) {
        // Barrier form: publishing a filled buffer must not be reordered before the memcpy.
        OSAtomicCompareAndSwap32Barrier(Int32(truncatingIfNeeded: storage.pointee), Int32(newValue), storage)
    }

    /// Atomic swap, returning the previous value.
    public func exchange(_ newValue: Int) -> Int {
        var current = storage.pointee
        while !OSAtomicCompareAndSwap32Barrier(current, Int32(newValue), storage) {
            current = storage.pointee
        }
        return Int(current)
    }

    public func compareExchange(expected: Int, desired: Int) -> Bool {
        OSAtomicCompareAndSwap32Barrier(Int32(expected), Int32(desired), storage)
    }

    public func increment() {
        OSAtomicIncrement32Barrier(storage)
    }
}
