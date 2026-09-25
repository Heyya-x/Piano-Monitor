import CoreAudio
import XCTest
@testable import PianoMonitorKit

/// Regression tests for `AudioDeviceManager`'s change notification.
///
/// The original implementation asked its own serial queue for the handler list *from inside* a block
/// already running on that queue:
///
/// ```swift
/// let handlers = self.queue.sync { Array(self.changeHandlers.values) }   // EXC_BREAKPOINT
/// ```
///
/// A synchronous dispatch onto the queue that is currently executing traps in libdispatch. Because
/// CoreAudio property listeners are registered on that queue, the crash happened on the first device
/// change — plugging in the piano was enough.
final class AudioDeviceManagerTests: XCTestCase {

    /// The exact shape of the crash: run the notification on the manager's own queue.
    func testNotificationOnTheManagersOwnQueueDoesNotDeadlock() {
        let manager = AudioDeviceManager()
        let delivered = expectation(description: "observer called")
        delivered.assertForOverFulfill = false
        manager.addObserver { _ in delivered.fulfill() }

        // This is what the coalescing work item does. Before the fix it trapped here.
        let finished = expectation(description: "queue drained")
        manager.queue.async {
            manager.performChangeNotification()
            finished.fulfill()
        }

        // A regression hangs rather than fails, so the waiter has a deadline.
        wait(for: [finished, delivered], timeout: 5)
    }

    /// Two notifications in quick succession must both complete; a deadlock would hang the second.
    func testRepeatedNotificationsAllComplete() {
        let manager = AudioDeviceManager()
        let delivered = expectation(description: "observer called")
        delivered.assertForOverFulfill = false
        manager.addObserver { _ in delivered.fulfill() }

        let finished = expectation(description: "all three drained")
        finished.expectedFulfillmentCount = 3
        manager.queue.async {
            for _ in 0..<3 {
                manager.performChangeNotification()
                finished.fulfill()
            }
        }

        wait(for: [finished, delivered], timeout: 5)
    }

    /// Observer bookkeeping must be correct, since the notification path now reads it directly.
    func testObserversAreAddedAndRemoved() {
        let manager = AudioDeviceManager()
        let token = manager.addObserver { _ in }

        let firstList = expectation(description: "first notification")
        firstList.assertForOverFulfill = false
        manager.queue.async { manager.performChangeNotification() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { firstList.fulfill() }
        wait(for: [firstList], timeout: 5)

        manager.removeObserver(token)

        // After removal the notification must not reach anyone. If `removeObserver` had failed, the
        // callback below would still fire; the assertion is that the counter stays put.
        let counter = CallCounter()
        let strayToken = manager.addObserver { _ in counter.increment() }
        manager.removeObserver(strayToken)
        let settled = expectation(description: "settled")
        manager.queue.async { manager.performChangeNotification() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(counter.value, 0, "a removed observer must not be called")
    }

    /// Listener blocks have to be retained verbatim so `AudioObjectRemovePropertyListenerBlock` can
    /// match them; a fresh closure removes nothing and leaves a dangling listener behind.
    func testListenersAreInstalledAndRemovedWithoutCrashing() {
        // Installing real CoreAudio listeners is safe (and is what the app does). What matters is
        // that teardown completes: `deinit` blocks on the queue, so a listener that cannot be removed
        // would leave work scheduled against a dead object.
        let manager = AudioDeviceManager()
        manager.addObserver { _ in }
        manager.queue.sync { }   // drain anything the install queued
        XCTAssertEqual(manager.installedListenerCountForTesting, 3, "devices + default in + default out")
    }

    /// Device enumeration must not trap, including on a machine with unusual aggregate/virtual
    /// devices — which is exactly what this Mac has.
    func testEnumerationSurvivesThisMachinesDeviceSet() {
        let manager = AudioDeviceManager()
        let all = manager.allDevices()
        XCTAssertFalse(all.isEmpty, "at least the built-in output should be present")
        for device in all {
            XCTAssertFalse(device.uid.isEmpty, "every device needs a UID; settings persist it")
            XCTAssertFalse(device.name.isEmpty)
        }
        XCTAssertEqual(Set(all.map(\.uid)).count, all.count, "UIDs must be unique")
    }
}

/// Small thread-safe counter so a stray main-queue callback is observable from the test.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Latency measurement and buffer control.
///
/// These touch real hardware properties, so they assert the contract (sane values, honest clamping,
/// restore-on-finish) rather than exact figures that would differ per machine.
final class LatencyControlTests: XCTestCase {

    private func firstInput(_ manager: AudioDeviceManager) throws -> AudioDevice {
        try XCTUnwrap(manager.inputDevices().first, "no input device on this machine")
    }

    private func firstOutput(_ manager: AudioDeviceManager) throws -> AudioDevice {
        try XCTUnwrap(manager.outputDevices().first, "no output device on this machine")
    }

    /// The device must report a usable buffer range, otherwise the latency profile is guesswork.
    func testBufferRangeIsReported() throws {
        let manager = AudioDeviceManager()
        let output = try firstOutput(manager)
        let range = try XCTUnwrap(manager.bufferFrameSizeRange(of: output.id))
        XCTAssertGreaterThan(range.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(range.upperBound, range.lowerBound)
    }

    /// Requesting a small buffer must actually produce a small buffer, and the achieved value must be
    /// read back rather than assumed.
    func testSmallBufferIsAppliedAndCanBeRestored() throws {
        let manager = AudioDeviceManager()
        let output = try firstOutput(manager)
        let original = try XCTUnwrap(manager.bufferFrameSize(of: output.id))
        defer { manager.setBufferFrameSize(original, on: output.id) }

        let range = try XCTUnwrap(manager.bufferFrameSizeRange(of: output.id))
        // A size the device definitely supports, below the usual 512-frame default.
        let target = max(range.lowerBound, min(64, range.upperBound))
        let achieved = try XCTUnwrap(manager.setBufferFrameSize(target, on: output.id))

        XCTAssertLessThanOrEqual(achieved, original, "the buffer should shrink or stay put, never grow")
        XCTAssertGreaterThanOrEqual(achieved, range.lowerBound, "the device must not accept less than its minimum")

        let restored = try XCTUnwrap(manager.setBufferFrameSize(original, on: output.id))
        XCTAssertEqual(restored, original, "the original buffer size must be restorable")
    }

    /// An absurd request must be clamped to the device's range instead of being rejected outright.
    func testOutOfRangeRequestIsClamped() throws {
        let manager = AudioDeviceManager()
        let output = try firstOutput(manager)
        let original = try XCTUnwrap(manager.bufferFrameSize(of: output.id))
        defer { manager.setBufferFrameSize(original, on: output.id) }
        let range = try XCTUnwrap(manager.bufferFrameSizeRange(of: output.id))

        let achieved = try XCTUnwrap(manager.setBufferFrameSize(range.upperBound * 4, on: output.id))
        XCTAssertLessThanOrEqual(achieved, range.upperBound)
        XCTAssertGreaterThanOrEqual(achieved, range.lowerBound)
    }

    /// Driver latency and safety offset are real terms in the round trip and must be readable.
    func testDriverLatencyTermsAreReadable() throws {
        let manager = AudioDeviceManager()
        let output = try firstOutput(manager)
        let input = try firstInput(manager)

        // Zero is a legitimate value for some virtual devices, so only non-negativity is asserted.
        XCTAssertGreaterThanOrEqual(manager.deviceLatency(of: output.id, scope: kAudioObjectPropertyScopeOutput), 0)
        XCTAssertGreaterThanOrEqual(manager.safetyOffset(of: output.id, scope: kAudioObjectPropertyScopeOutput), 0)
        XCTAssertGreaterThanOrEqual(manager.deviceLatency(of: input.id, scope: kAudioObjectPropertyScopeInput), 0)
    }

    /// The profile targets must be ordered from lowest latency to highest, since the UI presents them
    /// that way and the default is the smallest.
    func testProfilesAreOrderedByLatency() {
        XCTAssertLessThan(LatencyProfile.minimal.targetBufferFrames, LatencyProfile.low.targetBufferFrames)
        XCTAssertLessThan(LatencyProfile.low.targetBufferFrames, LatencyProfile.safe.targetBufferFrames)
        XCTAssertEqual(LatencyProfile.allCases.first, .minimal)
    }

    /// The round-trip estimate must include the driver terms, not just the buffers — otherwise the
    /// report looks better than the experience.
    func testRoundTripEstimateIncludesDriverLatency() {
        var report = LatencyReport()
        report.inputBufferMilliseconds = 0.7
        report.outputBufferMilliseconds = 0.7
        report.inputDeviceMilliseconds = 3.1
        report.outputDeviceMilliseconds = 2.2
        let total = try? XCTUnwrap(report.estimatedRoundTripMilliseconds)
        XCTAssertEqual(total ?? 0, 6.7, accuracy: 0.01)
    }

    /// When the engine reports its own presentation latency, that figure wins: it comes from the
    /// running audio unit rather than from a sum of HAL values.
    func testPresentationLatencyTakesPrecedenceWhenAvailable() {
        var report = LatencyReport()
        report.inputBufferMilliseconds = 10
        report.outputBufferMilliseconds = 10
        report.inputPresentationMilliseconds = 0.002
        report.outputPresentationMilliseconds = 0.003
        XCTAssertEqual(report.estimatedRoundTripMilliseconds ?? 0, 5.0, accuracy: 0.01)
    }
}
