import Foundation

/// Runs a possibly-blocking operation on another thread with a hard deadline.
///
/// Exists because some CoreAudio calls can block indefinitely — a wedged HAL, an IO unit waiting on
/// hardware that never answers, a driver still negotiating. Calling one of those directly on the
/// analysis queue would leave the engine half-started forever with no retry, and calling it on the
/// main actor would freeze the whole app, including the HTTP API.
///
/// Deliberately does **not** try to cancel or interrupt the operation: there is no safe way to
/// interrupt a thread blocked inside CoreAudio. It reports the timeout and lets the caller decide,
/// usually by marking the failure and relying on its own retry.
public enum BoundedOperation {

    public enum Outcome: Equatable {
        case finished
        case failed(String)
        /// The deadline passed; the work may still be running on its own thread.
        case timedOut
    }

    /// Runs `work` on a background queue and waits at most `timeout` for it.
    ///
    /// - Parameter work: Must be safe to run on a non-caller thread.
    public static func run(
        timeout: TimeInterval,
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping @Sendable () throws -> Void
    ) -> Outcome {
        let finished = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        DispatchQueue.global(qos: qos).async {
            do {
                try work()
                box.set(.finished)
            } catch {
                box.set(.failed(error.localizedDescription))
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            return .timedOut
        }
        return box.outcome
    }
}

/// Thread-safe hand-off of the operation's result.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: BoundedOperation.Outcome = .timedOut

    func set(_ outcome: BoundedOperation.Outcome) {
        lock.lock(); defer { lock.unlock() }
        storage = outcome
    }

    var outcome: BoundedOperation.Outcome {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
