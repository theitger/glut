import SwiftUI
import AppKit
import GlutCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main struct GlutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor: Monitor

    init() {
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
        _monitor = StateObject(wrappedValue: Monitor())
    }
    var body: some Scene {
        Window("Glut", id: "main") {
            MainView().environmentObject(monitor)
        }
        .defaultSize(width: 1020, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Monitoring") {
                Button("Reset Maximum Temperatures") { monitor.resetMaximums() }
                Button(monitor.logging ? "Stop CSV Logging" : "Start CSV Logging…") {
                    if monitor.logging { monitor.stopLogging() } else { monitor.startLogging() }
                }
                Divider()
                Button("Return Fan Control to macOS") { monitor.setMode(.system) }
            }
        }
        MenuBarExtra {
            MenuPanel().environmentObject(monitor)
        } label: {
            Image(systemName: "thermometer.medium")
            Text(monitor.temperature(monitor.menuValue)).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView().environmentObject(monitor) }
    }
}
