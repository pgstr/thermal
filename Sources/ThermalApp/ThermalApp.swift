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
        .defaultSize(width: 880, height: 780)
        .windowResizability(.contentMinSize)   // never smaller than the content: nothing gets cut off

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

/// Menu bar readout, plain text: battery °C, hottest die °C, fan speed in k rpm (only when spinning), e.g. "28° 60° 2.3k".
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
