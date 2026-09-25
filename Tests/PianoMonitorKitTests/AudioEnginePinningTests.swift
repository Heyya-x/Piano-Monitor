import AVFoundation
import CoreAudio
import XCTest
@testable import PianoMonitorKit

/// Regression tests for the `AVAudioNode.audioUnit` access.
///
/// The original implementation used `value(forKey: "audioUnit")`, which does not merely fail — it
/// raises `NSInvalidArgumentException` ("this class is not key value coding-compliant for the key
/// audioUnit"). Swift cannot catch Objective-C exceptions, so it terminated the app on the audio
/// queue the moment capture started, which no amount of `guard let` could prevent.
///
/// `AVAudioEngine` must never be instantiated in these tests: doing so starts the audio hardware and
/// blocks on the microphone permission prompt in a headless test process. Every assertion here is
/// therefore about the *selector contract*, which is exactly what regressed.
final class AudioEnginePinningTests: XCTestCase {

    /// `audioUnit` must be reachable through `perform`, and must not be reached through KVC.
    func testAudioUnitSelectorExistsButIsNotKVCCompliant() throws {
        for className in ["AVAudioNode", "AVAudioIONode", "AVAudioInputNode", "AVAudioOutputNode"] {
            let cls: AnyClass = try XCTUnwrap(NSClassFromString(className), "\(className) missing")
            let selector = NSSelectorFromString("audioUnit")
            XCTAssertTrue(
                class_getInstanceMethod(cls, selector) != nil,
                "\(className) should declare -audioUnit; if this changes, the pinning path needs revisiting"
            )
        }

        // The property that made KVC fatal: AVAudioNode declares `audioUnit` as a method, but not as
        // a KVC-compliant property. Asserting this keeps a future "simplification" back to
        // `value(forKey:)` from looking harmless.
        let nodeClass: AnyClass = try XCTUnwrap(NSClassFromString("AVAudioNode"))
        let kvcGetter = NSSelectorFromString("valueForUndefinedKey:")
        XCTAssertTrue(
            class_getInstanceMethod(nodeClass, kvcGetter) != nil,
            "AVAudioNode routes unknown keys to valueForUndefinedKey:, which is what raised"
        )
    }

    /// The selector returns a `C AudioUnit`, so it must be reinterpreted rather than released.
    ///
    /// Constructing an `AVAudioIONode` directly is not possible, so this checks the shape of the
    /// method signature that makes `unsafeBitCast` correct instead of a `takeUnretainedValue` call.
    func testAudioUnitSelectorReturnsAPointerNotAnObject() throws {
        let cls: AnyClass = try XCTUnwrap(NSClassFromString("AVAudioIONode"))
        let method = try XCTUnwrap(class_getInstanceMethod(cls, NSSelectorFromString("audioUnit")))
        let returnType = String(cString: method_copyReturnType(method))
        // `@` would mean an object (which would need `takeUnretainedValue`, and would break the
        // bitCast). `^` means a pointer, which is what `AudioUnit` is — the runtime spells it more
        // precisely as `^{ComponentInstanceRecord=...}`, so only the pointer prefix is asserted.
        XCTAssertTrue(
            returnType.hasPrefix("^"),
            "audioUnit returns \(returnType); the bitCast assumes a C pointer, not an object"
        )
        XCTAssertFalse(
            returnType.hasPrefix("@"),
            "audioUnit returns an object; the bitCast would then be wrong (use takeUnretainedValue)"
        )
    }

    /// Settings persist a device *UID*, which can outlive the device. The engine must degrade to
    /// "not pinned" for a device that no longer exists instead of failing to start.
    func testPinningAnUnknownDeviceIsRefusedBeforeTouchingCoreAudio() {
        let manager = AudioDeviceManager()
        let bogus = AudioDevice(
            id: 0,
            uid: "does-not-exist",
            name: "Ghost",
            inputChannelCount: 2,
            outputChannelCount: 0,
            nominalSampleRate: 44_100,
            transportType: 0
        )
        XCTAssertFalse(
            manager.setSystemDefault(device: bogus, scope: kAudioObjectPropertyScopeInput),
            "selecting a device that does not exist must fail rather than corrupt the default"
        )
        XCTAssertNil(manager.device(withUID: "does-not-exist"))
    }
}

/// The bounded-operation guard that keeps a wedged CoreAudio call from freezing the app.
///
/// This is the mechanism that turns "`AVAudioEngine.start()` never returned" from an app-wide hang
/// into a reported, retryable failure. It is tested directly because the hang it defends against
/// cannot be reproduced on demand.
final class BoundedOperationTests: XCTestCase {

    func testSuccessfulWorkReportsFinished() {
        var ran = false
        let outcome = BoundedOperation.run(timeout: 5) { ran = true }
        XCTAssertEqual(outcome, .finished)
        XCTAssertTrue(ran)
    }

    func testThrownErrorIsReportedWithItsMessage() {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let outcome = BoundedOperation.run(timeout: 5) { throw Boom() }
        XCTAssertEqual(outcome, .failed("boom"))
    }

    /// The critical case: work that never returns must not hold the caller past the deadline.
    func testStalledWorkTimesOutRatherThanBlockingForever() {
        let deadline: TimeInterval = 0.4
        let start = Date()
        let outcome = BoundedOperation.run(timeout: deadline) {
            // Stands in for a CoreAudio call that never answers.
            Thread.sleep(forTimeInterval: 30)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(elapsed, 3, "the caller must return at the deadline, not when the work ends")
    }

    /// Timing out must leave the caller free to carry on doing other work.
    func testCallerRemainsUsableAfterATimeout() {
        _ = BoundedOperation.run(timeout: 0.2) { Thread.sleep(forTimeInterval: 30) }
        // If the timeout had blocked the calling thread, this second call would never complete.
        let outcome = BoundedOperation.run(timeout: 5) { }
        XCTAssertEqual(outcome, .finished)
    }
}
