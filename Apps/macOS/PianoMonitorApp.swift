import AppKit
import PianoMonitorKit
import PianoMonitorMacUI
import SwiftUI

/// The macOS entry point.
///
/// The app is a menu bar accessory: `LSUIElement` keeps it out of the Dock and the app switcher, and
/// the `NSApplicationDelegateAdaptor` installs the status item. SwiftUI is used for all content, but
/// the menu bar item itself is a plain `NSStatusItem`, which is the only reliable approach across
/// the supported macOS range.
@main
struct PianoMonitorApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No `WindowGroup`: the main window is created on demand by `MainWindowController` so that
        // launching the app does not open a window at all. A `Settings` scene is still declared so
        // the standard ⌘, shortcut has somewhere to go.
        Settings {
            EmptyView()
                .frame(width: 0, height: 0)
                .onAppear { appDelegate.show(.settings) }
        }
    }
}

/// Owns the runtime, the status item and the main window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let runtime = PianoMonitorAppRuntime()
    private var windowController: MainWindowController?
    private var statusItemController: StatusItemController?
    private var statusObserver: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory policy: menu bar only, no Dock icon, no app switcher entry. This is set in code
        // as well as in Info.plist so a mis-built bundle still behaves correctly.
        NSApp.setActivationPolicy(.accessory)

        let windowController = MainWindowController(runtime: runtime)
        self.windowController = windowController
        self.statusItemController = StatusItemController(runtime: runtime, windowController: windowController)

        // Mirror throttled status into the menu bar item. This is the only UI update path; it runs
        // at the analysis profile's cadence, which is 1 fps in the background.
        statusObserver = runtime.addStatusObserver { [weak self] status in
            self?.statusItemController?.updateButton(for: status)
        }

        // The audio device list can change at any time; tell the UI so pickers refresh.
        NotificationCenter.default.addObserver(
            forName: .pianoMonitorDevicesChanged,
            object: nil,
            queue: .main
        ) { _ in }

        observeSystemPower()

        Task {
            await runtime.start()
        }
    }

    /// Closes the open session and pauses audio when the machine sleeps, and resumes on wake.
    /// Without this, an overnight lid-close would be recorded as one enormous practice session.
    private func observeSystemPower() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.runtime.service?.handleSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.runtime.service?.handleWake() }
        }
    }

    func show(_ destination: WindowDestination) {
        windowController?.show(destination)
    }

    /// Closing the window must not quit the app: it lives in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any open session synchronously enough that practice time is not lost on quit.
        if let observer = statusObserver {
            runtime.service?.removeObserver(observer)
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await runtime.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}
