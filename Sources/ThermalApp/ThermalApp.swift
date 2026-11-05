import AppKit
import SMCKit
import SwiftUI

@main
struct ThermalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(monitor)
                .task { monitor.start() }
        } label: {
            MenuBarLabel(text: monitor.menuBarText)
                .task { monitor.start() }   // start sampling at launch, not on first open
        }
        .menuBarExtraStyle(.window)

        Window("Thermal History", id: "history") {
            HistoryView()
                .environment(monitor)
        }
        .defaultSize(width: 860, height: 640)

        Window("Raw SMC Keys", id: "raw-smc") {
            RawSMCView()
                .environment(monitor)
        }
        .defaultSize(width: 720, height: 600)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only (also set via LSUIElement in Info.plist; this covers `swift run`).
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Menu bar readout: battery temperature · hottest die · fan speed (only when spinning).
/// Reads only `menuBarText`, so the status item redraws only when the rounded values change.
struct MenuBarLabel: View {
    let text: String

    var body: some View {
        if text.isEmpty {
            Image(systemName: "thermometer.medium")
        } else {
            Text(text).monospacedDigit()
        }
    }
}
