import Foundation
@testable import PianoMonitorKit

/// The synthetic signal generators now live in the Kit (`SyntheticSignal`) so the analyzer CLI and
/// the tests exercise identical reference signals. This alias keeps the test bodies readable.
typealias TestSignals = SyntheticSignal
