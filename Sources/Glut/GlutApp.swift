import SwiftUI
import AppKit
import Combine
import GlutCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var observation: AnyCancellable?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = Monitor()
        self.monitor = monitor
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Temperature")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Glut")
        }
        let height = min(680, max(420, (NSScreen.main?.visibleFrame.height ?? 800) - 64))
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            MenuPanel().environmentObject(monitor).frame(width: 400, height: height))
        popover.contentSize = NSSize(width: 400, height: height)
        observation = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }
        updateTitle()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
    }

    private func updateTitle() {
        guard let monitor else { return }
        statusItem?.button?.title = " " + monitor.temperature(monitor.menuValue)
        statusItem?.button?.toolTip = "Glut · \(monitor.menuSensor == "cpu" || monitor.menuSensor == "gpu" ? "10-second component average" : "Live sensor temperature")"
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stopLogging()
        monitor?.releaseControl()
    }
}

@main struct GlutLauncher {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--snapshot") {
            do {
                let telemetry = try Telemetry()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                print(String(decoding: try encoder.encode(telemetry.sample()), as: UTF8.self))
                exit(0)
            } catch { fputs("Glut: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
