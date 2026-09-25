import PianoMonitorKit
import SwiftUI

/// The iOS app's tab structure: Home, History, Sessions, Settings.
///
/// It is intentionally a *viewer*: there is no audio capture, no analysis, and no way to change
/// anything on the Mac. The only network traffic is `GET`.
public struct IOSRootView: View {

    @ObservedObject private var model: PianoMonitorClientModel

    public init(model: PianoMonitorClientModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            NavigationStack {
                IOSHomeView(model: model)
                    .navigationTitle("PianoMonitor")
                    .safeAreaInset(edge: .top) { banner }
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                IOSHistoryView(model: model)
                    .navigationTitle("History")
                    .safeAreaInset(edge: .top) { banner }
            }
            .tabItem { Label("History", systemImage: "chart.bar") }

            NavigationStack {
                IOSSessionsView(model: model)
                    .navigationTitle("Sessions")
                    .safeAreaInset(edge: .top) { banner }
            }
            .tabItem { Label("Sessions", systemImage: "list.bullet") }

            NavigationStack {
                IOSSettingsView(model: model)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }

    private var banner: some View {
        ConnectionBanner(
            connection: model.connection,
            lastUpdated: model.lastUpdated,
            isOfflineCache: model.isOfflineCache
        ) {
            Task { await model.refresh() }
        }
    }
}
