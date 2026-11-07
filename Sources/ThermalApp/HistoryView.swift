import Charts
import SMCKit
import SwiftUI

/// History window, styled like the popover: battery temperature first (cyan), everything else
/// muted; charging as a thin strip; gaps shown as gaps; hover for values; battery health over time.
struct HistoryView: View {
    @Environment(Monitor.self) private var monitor
    @State private var range: HistoryRange = .day
    @State private var battery: [HistoryPoint] = []
    @State private var die: [HistoryPoint] = []
    @State private var band: [HistoryBand] = []
    @State private var charge: [HistoryPoint] = []
    @State private var charging: [HistoryPoint] = []
    @State private var fans: [HistoryPoint] = []
    @State private var health: [BatteryHealthPoint] = []
    @State private var stats: HistoryStore.Stats?
    @State private var selection: Date?
    @State private var showDie = true
    @State private var end = Date()

    private var start: Date { end.addingTimeInterval(-range.seconds) }
    private var domain: ClosedRange<Date> { start...end }
    /// Points further apart than this are drawn as separate segments (Thermal wasn't running).
    private var maxGap: TimeInterval { TimeInterval(max(range.bucket, range == .year ? 3600 : 60)) * 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            temperatureChart
            chargingStrip
            VStack(alignment: .leading, spacing: 14) {
                chargeChart
                fanStrip
            }
            Divider()
            healthRow
            footer
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 600)
        .task(id: range) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(range == .hour ? 5 : 60))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selection == nil ? "Battery" : selectedTimeText)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(headline)
                    .font(.system(size: 40, weight: .light)).tracking(-1.2).monospacedDigit()
                    .contentTransition(.numericText())
                Text(subline).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var headline: String {
        if let sel = selectedBattery { return String(format: "%.1f°", sel.value) }
        return battery.last.map { String(format: "%.1f°", $0.value) } ?? "–"
    }

    private var subline: String {
        if let d = selectedDie { return String(format: "Hottest die %.0f°", d.value) }
        guard let lo = (band.map(\.low).min() ?? battery.map(\.value).min()),
              let hi = (band.map(\.high).max() ?? battery.map(\.value).max()) else { return "No data in this range yet" }
        var parts = [String(format: "%.1f° – %.1f°", lo, hi)]
        if let c = chargingDuration, c > 60 { parts.append("charging \(Self.duration(c))") }
        return parts.joined(separator: " · ")
    }

    private var selectedTimeText: String {
        guard let s = selection else { return "" }
        return s.formatted(range.seconds <= 86_400 ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).day().hour().minute())
    }

    // MARK: Temperature

    private var temperatureChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                if range != .hour {
                    ForEach(band) { b in
                        AreaMark(x: .value("Time", b.date), yStart: .value("Low", b.low), yEnd: .value("High", b.high))
                            .foregroundStyle(Color.cyan.opacity(0.12))
                            .interpolationMethod(.monotone)
                    }
                }
                if showDie {
                    ForEach(segmented(die)) { p in
                        LineMark(x: .value("Time", p.date), y: .value("°C", p.value), series: .value("Series", "die\(p.segment)"))
                            .foregroundStyle(Color.gray.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .interpolationMethod(.monotone)
                    }
                }
                ForEach(segmented(battery)) { p in
                    LineMark(x: .value("Time", p.date), y: .value("°C", p.value), series: .value("Series", "bat\(p.segment)"))
                        .foregroundStyle(Color.cyan)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let sel = selectedBattery {
                    RuleMark(x: .value("Selected", sel.date)).foregroundStyle(Color.secondary.opacity(0.4))
                    PointMark(x: .value("Time", sel.date), y: .value("°C", sel.value))
                        .foregroundStyle(Color.cyan).symbolSize(40)
                }
            }
            .chartXScale(domain: domain)
            .chartXSelection(value: $selection)
            .chartXAxis { timeAxis }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°") } }
                }
            }
            .frame(minHeight: 220)

            HStack(spacing: 14) {
                legend("Battery", color: .cyan, on: true)
                Button { showDie.toggle() } label: { legend("Hottest die", color: .gray, on: showDie) }
                    .buttonStyle(.plain)
            }
            .font(.caption)
        }
    }

    /// Thin strip under the temperature chart: green where the Mac was charging.
    private var chargingStrip: some View {
        HStack(spacing: 8) {
            Chart(charging.filter { $0.value >= 0.5 }) { p in
                RectangleMark(xStart: .value("Start", p.date),
                              xEnd: .value("End", p.date.addingTimeInterval(TimeInterval(range.bucket))),
                              yStart: .value("", 0), yEnd: .value("", 1))
                    .foregroundStyle(Color.green.opacity(0.7))
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 5)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 2))
            Text("Charging").font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
    }

    // MARK: Charge and fans

    private var chargeChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Charge", value: charge.last.map { "\(Int($0.value.rounded()))%" })
            Chart(segmented(charge)) { p in
                AreaMark(x: .value("Time", p.date), y: .value("%", p.value), series: .value("Series", "c\(p.segment)"))
                    .foregroundStyle(LinearGradient(colors: [Color.green.opacity(0.18), Color.green.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.date), y: .value("%", p.value), series: .value("Series", "c\(p.segment)"))
                    .foregroundStyle(Color.green.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { v in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel { if let d = v.as(Int.self) { Text("\(d)%") } }
                }
            }
            .frame(height: 70)
        }
    }

    private var fanStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Fans", value: fanSummary)
            if (fans.map(\.value).max() ?? 0) > 0 {
                Chart(segmented(fans)) { p in
                    AreaMark(x: .value("Time", p.date), y: .value("rpm", p.value), series: .value("Series", "f\(p.segment)"))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                }
                .chartXScale(domain: domain)
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 22)
            }
        }
    }

    private var fanSummary: String {
        guard let peak = fans.map(\.value).max() else { return "–" }
        if peak <= 0 { return "Off the whole time" }
        let spinning = fans.filter { $0.value > 0 }.count
        return "Peak \(Int(peak).formatted()) rpm · on \(Int(Double(spinning) / Double(max(fans.count, 1)) * 100))% of the time"
    }

    // MARK: Battery health

    private var healthRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Battery health").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(health.last.map { String(format: "%.1f%%", $0.health) } ?? "–")
                    .font(.system(size: 28, weight: .light)).monospacedDigit()
                Text(healthSubline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if health.count > 1 {
                Chart(health) { h in
                    LineMark(x: .value("Day", h.day), y: .value("%", h.health))
                        .foregroundStyle(Color.cyan)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: healthDomain)
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(width: 220, height: 44)
            } else {
                Text("Trend appears after a few days").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var healthSubline: String {
        guard let h = health.last else { return "Recorded once a day" }
        var parts: [String] = []
        if let m = h.maximumCapacity { parts.append("macOS shows \(m)%") }
        parts.append("\(h.cycles) cycles")
        if let first = health.first { parts.append("tracked since \(first.day.formatted(.dateTime.day().month(.abbreviated).year()))") }
        return parts.joined(separator: " · ")
    }

    private var healthDomain: ClosedRange<Double> {
        let v = health.map(\.health)
        let lo = (v.min() ?? 95) - 1, hi = (v.max() ?? 100) + 1
        return lo...hi
    }

    private var footer: some View {
        Text(footerText).font(.caption2).foregroundStyle(.tertiary)
    }

    private var footerText: String {
        guard let s = stats else { return "" }
        var t = "History " + ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file)
        if let since = s.since { t += " · since " + since.formatted(.dateTime.day().month(.abbreviated).year()) }
        return t + " · 5 s for 48 h, 1 min for 30 days, hourly forever"
    }

    // MARK: Helpers

    private struct Segmented: Identifiable {
        let date: Date, value: Double, segment: Int
        var id: TimeInterval { date.timeIntervalSince1970 }
    }

    private func segmented(_ points: [HistoryPoint]) -> [Segmented] {
        var seg = 0
        var prev: Date?
        return points.map { p in
            if let prev, p.date.timeIntervalSince(prev) > maxGap { seg += 1 }
            prev = p.date
            return Segmented(date: p.date, value: p.value, segment: seg)
        }
    }

    private func nearest(_ points: [HistoryPoint], to date: Date?) -> HistoryPoint? {
        guard let date else { return nil }
        return points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            .flatMap { abs($0.date.timeIntervalSince(date)) <= maxGap ? $0 : nil }
    }

    private var selectedBattery: HistoryPoint? { nearest(battery, to: selection) }
    private var selectedDie: HistoryPoint? { showDie ? nearest(die, to: selection) : nil }

    /// Seconds spent charging in the range (bucket averages are fractions of time charging).
    private var chargingDuration: TimeInterval? {
        charging.isEmpty ? nil : charging.map(\.value).reduce(0, +) * TimeInterval(range.bucket)
    }

    private static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    @AxisContentBuilder private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
            switch range {
            case .hour, .day: AxisValueLabel(format: .dateTime.hour().minute())
            case .week: AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            case .month, .year: AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
    }

    private func legend(_ title: String, color: Color, on: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(on ? color : Color.secondary.opacity(0.3)).frame(width: 12, height: 3)
            Text(title).foregroundStyle(on ? .secondary : .tertiary)
        }
    }

    private func row(_ title: String, value: String?) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "–").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func load() async {
        let h = monitor.history
        end = Date()
        battery = await h.series([Metric.batteryTemp.rawValue], range: range, now: end)
        die = await h.series([Metric.dieMax.rawValue], range: range, now: end)
        band = await h.batteryBand(range: range, now: end)
        charge = await h.series([Metric.batteryPercent.rawValue], range: range, now: end)
        charging = await h.series([Metric.charging.rawValue], range: range, now: end)
        fans = await h.series([Metric.fanRPM.rawValue], range: range, now: end)
        health = await h.batteryHealth()
        stats = await h.stats()
    }
}
