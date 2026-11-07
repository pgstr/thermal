import SMCKit
import SwiftUI

// Drop-in replacement for Sources/ThermalApp/PopoverView.swift (redesign 2a/2b).
// Uses only existing APIs: Monitor, FanController, HistoryStore, Snapshot, TemperatureStyle.

struct PopoverView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(open: open, quit: quit)
                .padding(.horizontal, 16).padding(.top, 14)

            if !monitor.smcAvailable {
                Label("Cannot open the SMC. Sensor readings are unavailable.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.top, 8)
            }

            if let s = monitor.shown {
                BatteryHero(snapshot: s, history: monitor.history)
                    .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 4)
                CoolChargingRow(fans: monitor.fans)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                Divider().padding(.horizontal, 16)
                SensorList(snapshot: s, fanText: fanText(s))
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 10)
            } else {
                ProgressView("Reading sensors…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity).padding(24)
            }
        }
        .frame(width: 300)
        .onAppear { monitor.popoverDidAppear() }
        .onDisappear { monitor.popoverDidDisappear() }
    }

    private func fanText(_ s: Snapshot) -> String {
        let owner: String
        switch monitor.fanOwner {
        case "Apple (automatic)": owner = "Apple"
        case "Manual (Fandy)": owner = "Fandy"
        case "Manual (other app)": owner = "Other app"
        default: owner = monitor.fanOwner
        }
        guard s.fansSpinning else { return "\(owner) · off" }
        return "\(owner) · \(Int(s.averageFanRPM).formatted()) rpm"
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }

    private func quit() {
        Task {
            await monitor.stop()
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Header

private struct Header: View {
    let open: (String) -> Void
    let quit: () -> Void

    var body: some View {
        HStack {
            Text("Battery").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("History…") { open("history") }
                Button("Raw SMC…") { open("raw-smc") }
                Divider()
                Button("Quit") { quit() }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Battery hero

private struct BatteryHero: View {
    let snapshot: Snapshot
    let history: HistoryStore
    @State private var expanded = false
    @State private var points: [Double] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(heroTemp)
                            .font(.system(size: 44, weight: .light))
                            .tracking(-1.5)
                            .monospacedDigit()
                            .foregroundStyle(TemperatureStyle.battery(snapshot.batteryTemperature))
                        Text(subtitle).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Sparkline(values: points)
                        .frame(width: 96, height: 36)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let b = snapshot.battery {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Adapter", b.adapterWatts.map { "\($0) W" } ?? "–")
                    row("Health", b.health.map { String(format: "%.1f%%", $0) } ?? "–")
                    row("Cycles", "\(b.cycleCount)")
                    if let lo = points.min(), let hi = points.max() {
                        row("Last hour", String(format: "%.1f° – %.1f°", lo, hi))
                    }
                }
                .font(.caption)
                .transition(.opacity)
            }
        }
        .task {
            // Last hour of battery temperature; refresh every 30 s while the popover is open.
            while !Task.isCancelled {
                let s = await history.series([Metric.batteryTemp.rawValue], range: .hour)
                points = s.map(\.value)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var heroTemp: String {
        snapshot.batteryTemperature.map { String(format: "%.1f°", $0) } ?? "–"
    }

    private var subtitle: String {
        guard let b = snapshot.battery else { return "No battery data" }
        let watts = abs(b.batteryWatts)
        switch b.chargeState {
        case "Charging": return "\(b.percent)% · Charging at \(Int(watts.rounded())) W"
        case "On battery": return "\(b.percent)% · Using \(Int(watts.rounded())) W"
        default: return "\(b.percent)% · \(b.chargeState)"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let lo = values.min(), let hi = values.max() {
                let range = max(hi - lo, 0.6)
                let mid = (hi + lo) / 2
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                            y: geo.size.height * (0.5 - CGFloat((v - mid) / range)))
                }
                Path { p in p.addLines(pts) }
                    .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                Circle().fill(.tint).frame(width: 5, height: 5).position(pts.last!)
            }
        }
        .tint(.cyan)
        .accessibilityLabel("Battery temperature, last hour")
    }
}

// MARK: - Cool charging

private struct CoolChargingRow: View {
    @Bindable var fans: FanController
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Button { withAnimation(.snappy(duration: 0.2)) { showSettings.toggle() } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Cool charging").fontWeight(.medium)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showSettings ? 90 : 0))
                        }
                        status.font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Toggle("Cool charging", isOn: $fans.coolChargingEnabled)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }

            if showSettings {
                settings.font(.caption).transition(.opacity)
            }
        }
        .onAppear { fans.helper.refresh() }
    }

    @ViewBuilder private var status: some View {
        if !fans.coolChargingEnabled {
            Text("Off").foregroundStyle(.secondary)
        } else if !fans.helper.isEnabled {
            Text("Fan control not enabled").foregroundStyle(.orange)
        } else {
            switch fans.state {
            case .active(let rpm, let reason):
                Text("\(reason) · \(rpm.formatted()) rpm").foregroundStyle(.teal)
            case .blocked(let why):
                Text(why).foregroundStyle(.orange)
            case .idle:
                if fans.cantReach {
                    Text("Can't reach target: room too warm or heavy load").foregroundStyle(.orange)
                } else if fans.coolChargingApplies {
                    Text(String(format: "Battery is cool · below %g°", fans.effectiveTarget)).foregroundStyle(.secondary)
                } else {
                    Text("Idle · not charging").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !fans.helper.isEnabled {
                HStack {
                    Text(fans.helper.statusText).foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable…") { fans.helper.enable() }.controlSize(.small)
                }
            }
            HStack {
                Text("Target").foregroundStyle(.secondary)
                Spacer()
                if let a = fans.alDente, a.heatProtection {
                    Text(String(format: "%g °C", a.maxTemperature)).monospacedDigit()
                        .help("Set by AlDente's heat protection")
                } else {
                    Text(String(format: "%.1f °C", fans.target)).monospacedDigit()
                    Stepper("Target", value: $fans.target, in: 25...32, step: 0.5)
                        .labelsHidden().controlSize(.mini)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max fan speed").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(fans.cap).formatted()) rpm").monospacedDigit()
                }
                Slider(value: $fans.cap, in: 3000...7500, step: 250).controlSize(.mini)
            }
        }
    }
}

// MARK: - Temperatures

private struct SensorList: View {
    let snapshot: Snapshot
    let fanText: String
    @State private var expanded: Set<SensorGroup> = []

    private var groups: [SensorGroup] {
        SensorGroup.allCases.filter { $0 != .battery && !snapshot.sensors(in: $0).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.self) { g in
                let open = expanded.contains(g)
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if open { expanded.remove(g) } else { expanded.insert(g) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 8)
                        Text(g.title)
                        Spacer()
                        Text(temp(snapshot.max(g))).monospacedDigit()
                            .foregroundStyle(TemperatureStyle.die(snapshot.max(g)))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())

                if open {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(snapshot.sensors(in: g)) { r in
                            HStack {
                                Text(r.name)
                                Spacer()
                                Text(temp(r.celsius)).monospacedDigit()
                            }
                        }
                        if g == .soc {
                            Text("CPU and GPU dies are not mapped yet.")
                                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 22).padding(.trailing, 8).padding(.bottom, 6)
                    .transition(.opacity)
                }
            }
            HStack {
                Text("Fans")
                Spacer()
                Text(fanText).monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 22).padding(.trailing, 8).padding(.vertical, 6)
        }
    }
}

private struct RowButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(.primary.opacity(configuration.isPressed ? 0.12 : hover ? 0.07 : 0)))
            .onHover { hover = $0 }
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
