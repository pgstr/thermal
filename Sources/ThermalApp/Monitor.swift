import AppKit
import Foundation
import Observation
import os
import SMCKit

/// Samples the sensors once per second, publishes the latest snapshot to the UI and records history.
@MainActor @Observable
final class Monitor {
    /// Newest snapshot. Not observed: views read `shown` instead, which only changes while the
    /// popover is open (a hidden MenuBarExtra window otherwise re-lays out every second).
    @ObservationIgnored private(set) var latest: Snapshot?
    /// Snapshot published to the popover; updated only while it is visible.
    private(set) var shown: Snapshot?
    @ObservationIgnored private var popoverVisible = false
    /// Menu bar text, only reassigned when it actually changes (avoids a status-item redraw per second).
    private(set) var menuBarText = ""
    private(set) var smcAvailable = true
    private(set) var fandyRunning = false

    let reader = SensorReader()
    let history = HistoryStore(url: HistoryStore.defaultURL())
    let fans = FanController()
    let loginItem = LoginItem()
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var label = MenuBarLabelModel()

    func start() {
        guard task == nil else { return }
        observeSleep()
        task = Task { [weak self] in
            guard let self else { return }
            self.smcAvailable = await self.reader.smcAvailable
            while !Task.isCancelled {
                let started = Date()
                let s = await self.reader.snapshot()
                self.latest = s
                if self.popoverVisible { self.shown = s }
                if let text = self.label.update(with: s, now: s.date) { self.menuBarText = text }
                await self.history.record(s)
                if self.tick % 10 == 0 { self.fandyRunning = Self.isAppRunning(named: "Fandy") }
                await self.fans.update(with: s, fandyRunning: self.fandyRunning)
                self.tick += 1
                // Align to ~1 Hz regardless of how long the read took.
                let wait = max(0.2, 1 - Date().timeIntervalSince(started))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        await fans.suspend()
        await history.flush()
    }

    /// The helper also hands back before sleep; this keeps the app from re-taking the fans
    /// until it has fresh readings after wake.
    private func observeSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.fans.suspend() }
        })
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fans.resume() }
        })
    }

    @ObservationIgnored private let log = Logger(subsystem: "dev.streller.thermal", category: "monitor")

    func popoverDidAppear() {
        log.debug("popover appeared")
        popoverVisible = true
        shown = latest
    }

    func popoverDidDisappear() {
        log.debug("popover disappeared")
        popoverVisible = false
    }

    /// Who owns the fans right now, as far as we can tell.
    var fanOwner: String {
        guard let s = shown else { return "–" }
        if !s.fans.contains(where: \.manual) { return "Apple (automatic)" }
        if case .active = fans.state { return "Thermal" }
        return fandyRunning ? "Manual (Fandy)" : "Manual (other app)"
    }

    /// Fandy's helper daemon keeps running after the app quits, but only the app drives the fans.
    private static func isAppRunning(named name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }
}

/// Decides when the menu bar text changes. Every status-item update costs ~20 ms of layout, and the
/// hottest die flickers between neighbouring degrees almost every second, so the die value is
/// smoothed and the label only changes on a meaningful move (or after a while for small drifts).
struct MenuBarLabelModel {
    static let dieStep = 2.0            // °C move that updates immediately
    static let minInterval: TimeInterval = 15

    private(set) var text = ""
    private var smoothedDie: Double?
    private var shownDie: Double?
    private var shownBattery: Int?
    private var shownFanSpinning = false
    private var lastUpdate = Date.distantPast

    /// Returns the new text when the label should change, otherwise nil.
    mutating func update(with s: Snapshot, now: Date) -> String? {
        if let d = s.hottestDie { smoothedDie = smoothedDie.map { $0 + 0.3 * (d - $0) } ?? d }
        let battery = s.batteryTemperature.map { Int($0.rounded()) }

        let urgent = text.isEmpty
            || battery != shownBattery
            || s.fansSpinning != shownFanSpinning
            || abs((smoothedDie ?? 0) - (shownDie ?? 0)) >= Self.dieStep
        let candidate = Self.format(battery: battery, die: smoothedDie, s: s)
        guard candidate != text, urgent || now.timeIntervalSince(lastUpdate) >= Self.minInterval else { return nil }

        text = candidate
        shownDie = smoothedDie
        shownBattery = battery
        shownFanSpinning = s.fansSpinning
        lastUpdate = now
        return text
    }

    static func format(battery: Int?, die: Double?, s: Snapshot) -> String {
        var parts: [String] = []
        if let battery { parts.append("\(battery)°") }
        if let die { parts.append("\(Int(die.rounded()))°") }
        if s.fansSpinning { parts.append(String(format: "%.1fk", s.averageFanRPM / 1000)) }
        return parts.joined(separator: " ")
    }
}
