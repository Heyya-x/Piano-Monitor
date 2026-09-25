import AppKit
import PianoMonitorKit
import SwiftUI

/// Hosts the main window and tracks which screen is visible so the app's analysis profile can
/// follow it. Only the Tempo Analyzer asks for the expensive profile.
@MainActor
public final class MainWindowController {

    private var window: NSWindow?
    private let runtime: PianoMonitorAppRuntime
    private var selected: WindowDestination = .dashboard

    public init(runtime: PianoMonitorAppRuntime) {
        self.runtime = runtime
    }

    /// The profile the app should fall back to when the popover closes.
    public var preferredAnalysisMode: AnalysisMode {
        selected == .tempo ? .analysis : .eco
    }

    public func show(_ destination: WindowDestination) {
        selected = destination

        if window == nil {
            let hosting = NSHostingController(rootView: MainWindowView(runtime: runtime, selection: destination))
            let window = NSWindow(contentViewController: hosting)
            window.title = "PianoMonitor"
            window.setContentSize(NSSize(width: 780, height: 560))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        } else if let hosting = window?.contentViewController as? NSHostingController<MainWindowView> {
            hosting.rootView = MainWindowView(runtime: runtime, selection: destination)
        }

        // The app is an accessory (no Dock icon), so it must be activated explicitly or the window
        // opens behind whatever the user is doing.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.close()
    }
}

/// The main window's tab structure.
public struct MainWindowView: View {

    @ObservedObject private var runtime: PianoMonitorAppRuntime
    @State private var selection: WindowDestination

    public init(runtime: PianoMonitorAppRuntime, selection: WindowDestination) {
        self.runtime = runtime
        _selection = State(initialValue: selection)
    }

    public var body: some View {
        TabView(selection: $selection) {
            DashboardView(runtime: runtime)
                .tabItem { Label("Dashboard", systemImage: WindowDestination.dashboard.systemImage) }
                .tag(WindowDestination.dashboard)

            TempoAnalyzerView(runtime: runtime)
                .tabItem { Label("Tempo", systemImage: WindowDestination.tempo.systemImage) }
                .tag(WindowDestination.tempo)

            HistoryView(runtime: runtime)
                .tabItem { Label("History", systemImage: WindowDestination.history.systemImage) }
                .tag(WindowDestination.history)

            SettingsView(runtime: runtime)
                .tabItem { Label("Settings", systemImage: WindowDestination.settings.systemImage) }
                .tag(WindowDestination.settings)
        }
        .padding(.top, 4)
        .frame(minWidth: 700, minHeight: 500)
        // Keep the analysis profile in step with whichever tab is showing.
        .onChange(of: selection) { _, newValue in
            runtime.setAnalysisMode(newValue == .tempo ? .analysis : .eco)
        }
        .onAppear {
            runtime.setAnalysisMode(selection == .tempo ? .analysis : .eco)
        }
    }
}
