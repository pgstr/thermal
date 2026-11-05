import SMCKit
import SwiftUI

struct PopoverView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !monitor.smcAvailable {
                Label("Cannot open the SMC. Sensor readings are unavailable.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let s = monitor.shown {
                BatterySection(snapshot: s)
                Divider()
                CoolChargingSection(fans: monitor.fans)
                Divider()
                FanSection(fans: s.fans, owner: monitor.fanOwner)
                Divider()
                SensorGroupsSection(snapshot: s)
            } else {
                ProgressView("Reading sensors…").frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("History…") { open("history") }
                Button("Raw SMC…") { open("raw-smc") }
                Spacer()
                Button("Quit") {
                    Task {
                        await monitor.stop()
                        NSApp.terminate(nil)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { monitor.popoverDidAppear() }
        .onDisappear { monitor.popoverDidDisappear() }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

// MARK: - Sections

private struct BatterySection: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Battery", systemImage: batterySymbol).font(.headline)
                Spacer()
                Text(temp(snapshot.batteryTemperature)).font(.title3.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(TemperatureStyle.battery(snapshot.batteryTemperature))
            }
            if let b = snapshot.battery {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("State", "\(b.percent)% · \(b.chargeState)")
                    row("Power", String(format: "%+.1f W%@", b.batteryWatts, b.adapterWatts.map { " · \($0) W adapter" } ?? ""))
                    row("Health", b.health.map { String(format: "%.1f%% · %d cycles", $0, b.cycleCount) } ?? "–")
                }
                .font(.callout)
            }
        }
    }

    private var batterySymbol: String {
        guard let b = snapshot.battery else { return "battery.0percent" }
        if b.isCharging { return "battery.100percent.bolt" }
        return b.percent > 60 ? "battery.75percent" : b.percent > 30 ? "battery.50percent" : "battery.25percent"
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit()
        }
    }
}

private struct FanSection: View {
    let fans: [FanStatus]
    let owner: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Fans", systemImage: "fan").font(.headline)
                Spacer()
                Text(owner).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(fans) { f in
                HStack {
                    Text("Fan \(f.id + 1)").foregroundStyle(.secondary)
                    Spacer()
                    Text(f.actualRPM > 0 ? "\(Int(f.actualRPM)) rpm" : "off").monospacedDigit()
                    if f.manual, f.targetRPM > 0 {
                        Text("→ \(Int(f.targetRPM))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.callout)
            }
        }
    }
}

private struct SensorGroupsSection: View {
    let snapshot: Snapshot
    @State private var expanded: Set<SensorGroup> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Temperatures", systemImage: "thermometer.medium").font(.headline)
            ForEach(SensorGroup.allCases.filter { $0 != .battery && !snapshot.sensors(in: $0).isEmpty }, id: \.self) { g in
                DisclosureGroup(isExpanded: binding(g)) {
                    ForEach(snapshot.sensors(in: g)) { r in
                        HStack {
                            Text(r.name).foregroundStyle(.secondary)
                            Spacer()
                            Text(temp(r.celsius)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                } label: {
                    HStack {
                        Text(g.title)
                        Spacer()
                        if snapshot.sensors(in: g).count > 1 {
                            Text("avg \(temp(snapshot.average(g)))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Text(temp(snapshot.max(g))).monospacedDigit()
                            .foregroundStyle(TemperatureStyle.die(snapshot.max(g)))
                    }
                    .font(.callout)
                }
            }
            if snapshot.sensors(in: .soc).count > 0 {
                Text("CPU and GPU dies are not mapped yet; shown together as SoC dies.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func binding(_ g: SensorGroup) -> Binding<Bool> {
        Binding(get: { expanded.contains(g) }, set: { if $0 { expanded.insert(g) } else { expanded.remove(g) } })
    }
}

private struct CoolChargingSection: View {
    @Bindable var fans: FanController
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $fans.coolChargingEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cool charging").font(.headline)
                    Text("Keeps the battery below \(fans.effectiveTarget, specifier: "%g") °C while charging")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if fans.coolChargingEnabled {
                statusLine.font(.caption)
                if !fans.helper.isEnabled {
                    HStack {
                        Text("Fan control: \(fans.helper.statusText)").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Enable…") { fans.helper.enable() }.controlSize(.small)
                    }
                }
                if let a = fans.alDente {
                    Text("AlDente: limit \(a.chargeLimit)% · charges again at \(a.resumeLevel)%\(a.heatProtection ? " · heat protection \(Int(a.maxTemperature)) °C" : "")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let st = fans.alDenteState {
                    Text("AlDente now: \(st.title)").font(.caption2).foregroundStyle(.secondary)
                } else if fans.alDenteShortcutMissing {
                    Text("Create a shortcut named “AlDente State” (AlDente › Get State) for exact control.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                DisclosureGroup("Settings", isExpanded: $showSettings) {
                    if let a = fans.alDente, a.heatProtection {
                        Text("Target: \(a.maxTemperature, specifier: "%g") °C (from AlDente's heat protection)")
                    } else {
                        Stepper(value: $fans.target, in: 25...32, step: 0.5) {
                            Text("Target: \(fans.target, specifier: "%.1f") °C")
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max fan speed: \(Int(fans.cap)) rpm")
                        Slider(value: $fans.cap, in: 3000...7500, step: 250)
                    }
                }
                .font(.caption)
            }
        }
        .onAppear { fans.helper.refresh() }
    }

    @ViewBuilder private var statusLine: some View {
        switch fans.state {
        case .active(let rpm, let reason):
            Label("\(reason) · \(rpm) rpm", systemImage: "fan.fill").foregroundStyle(.teal)
        case .blocked(let why):
            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .idle:
            Label(fans.coolChargingApplies ? "Battery is cool; Apple controls the fans" : "Idle: charging not due (sailing or limit reached)",
                  systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
        if fans.cantReach {
            Label("Can't reach the target here: room too warm or heavy load", systemImage: "thermometer.high")
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Helpers

func temp(_ v: Double?) -> String { v.map { String(format: "%.1f °C", $0) } ?? "–" }

/// Colours follow the spec's targets (§1): battery 30/35 °C, dies 85/95 °C.
enum TemperatureStyle {
    static func battery(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        return v >= 35 ? .red : v >= 30 ? .orange : .primary
    }
    static func die(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        return v >= 95 ? .red : v >= 85 ? .orange : .primary
    }
}
