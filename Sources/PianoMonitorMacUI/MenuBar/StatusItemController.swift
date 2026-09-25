import AppKit
import PianoMonitorKit
import SwiftUI

/// Owns the `NSStatusItem` and the popover.
///
/// SwiftUI's `MenuBarExtra` is not usable here: the deployment target includes Catalina, and this
/// app needs precise control over activation policy (no Dock icon) and popover behaviour. Using
/// `NSStatusItem` directly is the reliable choice, exactly as the spec allows.
@MainActor
public final class StatusItemController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let runtime: PianoMonitorAppRuntime
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private weak var windowController: MainWindowController?

    public init(runtime: PianoMonitorAppRuntime, windowController: MainWindowController) {
        self.runtime = runtime
        self.windowController = windowController
        // `.variableLength` lets the item grow when the playing duration is shown next to the icon.
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configurePopover()
        updateButton(for: runtime.status)
    }

    deinit {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = StatusItemController.icon(playing: false)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "PianoMonitor"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(
                runtime: runtime,
                openWindow: { [weak self] destination in
                    self?.closePopover()
                    self?.windowController?.show(destination)
                },
                quit: { NSApp.terminate(nil) }
            )
        )
    }

    private static func icon(playing: Bool) -> NSImage? {
        // A piano glyph keeps the item recognisable; the filled variant signals activity without
        // needing a colour (menu bar icons are templates and adapt to light/dark automatically).
        let symbolName = playing ? "pianokeys" : "pianokeys.inverse"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PianoMonitor")
        image?.isTemplate = true
        return image
    }

    // MARK: - Status updates

    /// Refreshes the menu bar item. Called from the throttled status publisher, so this runs at most
    /// a few times per second.
    public func updateButton(for status: LiveStatus) {
        guard let button = statusItem.button else { return }
        button.image = StatusItemController.icon(playing: status.state == .playing)

        // Title carries only the *live session* duration, because that is the number that changes.
        // Showing today's total would tempt a per-second UI update for no benefit.
        if status.state == .playing, status.metrics.currentSessionActiveDuration > 0 {
            button.title = " " + DurationFormatter.short(status.metrics.currentSessionActiveDuration)
        } else if status.connection.isDegraded {
            button.title = " ⚠"
        } else {
            button.title = ""
        }
        button.toolTip = tooltip(for: status)
    }

    private func tooltip(for status: LiveStatus) -> String {
        var lines = ["PianoMonitor", status.connection.shortDescription]
        lines.append("Today: \(DurationFormatter.short(status.todayActiveDuration))")
        if let input = status.inputDeviceName { lines.append("Input: \(input)") }
        if let output = status.outputDeviceName { lines.append("Output: \(output)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // The popover briefly needs the waveform and a slightly higher refresh rate.
        runtime.setAnalysisMode(.balanced)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Close when the user clicks elsewhere. A global monitor is required because the app is an
        // accessory (no key window to resign).
        if let event = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }) {
            globalEventMonitor = event
        }
    }

    public func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    public func popoverDidClose(_ notification: Notification) {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        // Back to the cheap profile; the tempo analyzer window raises it again if it is open.
        runtime.setAnalysisMode(windowController?.preferredAnalysisMode ?? .eco)
    }
}
