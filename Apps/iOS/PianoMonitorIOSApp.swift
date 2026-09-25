import PianoMonitorIOSUI
import SwiftUI

/// iOS entry point. A thin shell around `IOSRootView`; all state lives in the client model.
@main
struct PianoMonitorIOSApp: App {

    @StateObject private var model = PianoMonitorClientModel()

    var body: some Scene {
        WindowGroup {
            IOSRootView(model: model)
        }
    }
}
