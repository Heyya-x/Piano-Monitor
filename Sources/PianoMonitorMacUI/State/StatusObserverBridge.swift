import Foundation
import PianoMonitorKit

extension PianoMonitorAppRuntime {
    /// Convenience wrapper so AppKit code can observe throttled status without importing SwiftUI
    /// types directly.
    @discardableResult
    public func addStatusObserver(_ handler: @escaping @MainActor (LiveStatus) -> Void) -> UUID? {
        guard let service else { return nil }
        return service.addObserver { status in
            Task { @MainActor in handler(status) }
        }
    }
}
