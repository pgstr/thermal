import Charts
import SMCKit
import SwiftUI

struct HistoryView: View {
    @Environment(Monitor.self) private var monitor
    @State private var range: HistoryRange = .hour
    @State private var temps: [HistoryPoint] = []
    @State private var fans: [HistoryPoint] = []
    @State private var charge: [HistoryPoint] = []
    @State private var charging: [HistoryPoint] = []
    @State private var stats = ""

    private let tempMetrics: [Metric] = [.batteryTemp, .dieMax, .storageTemp]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Spacer()
                Text(stats).font(.caption).foregroundStyle(.secondary)
            }

            chartBox("Temperatures (°C)") {
                Chart {
                    chargingBands
                    ForEach(temps) { p in
                        LineMark(x: .value("Time", p.date), y: .value("°C", p.value))
                            .foregroundStyle(by: .value("Series", title(p.metric)))
                            .interpolationMethod(.monotone)
                    }
                    RuleMark(y: .value("Battery target", 30))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.orange.opacity(0.6))
                        .annotation(position: .top, alignment: .leading) {
                            Text("battery 30 °C").font(.caption2).foregroundStyle(.orange)
                        }
                }
                .chartForegroundStyleScale(["Battery": .green, "Hottest die": .red, "Storage": .blue])
            }

            chartBox("Fans (rpm)") {
                Chart(fans) { p in
                    AreaMark(x: .value("Time", p.date), y: .value("rpm", p.value))
                        .foregroundStyle(.teal.opacity(0.35))
                    LineMark(x: .value("Time", p.date), y: .value("rpm", p.value))
                        .foregroundStyle(.teal)
                }
            }

            chartBox("Charge (%) · shaded = charging") {
                Chart {
                    chargingBands
                    ForEach(charge) { p in
                        LineMark(x: .value("Time", p.date), y: .value("%", p.value)).foregroundStyle(.green)
                    }
                }
                .chartYScale(domain: 0...100)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
        .task(id: range) {
            // Refresh while the window is open: every 5 s for 1 h, every 60 s otherwise.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(range == .hour ? 5 : 60))
            }
        }
    }

    @ChartContentBuilder
    private var chargingBands: some ChartContent {
        ForEach(charging.filter { $0.value >= 0.5 }) { p in
            RectangleMark(
                xStart: .value("Start", p.date),
                xEnd: .value("End", p.date.addingTimeInterval(TimeInterval(range.bucket))))
                .foregroundStyle(.green.opacity(0.08))
        }
    }

    private func chartBox(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content().frame(minHeight: 120)
        }
    }

    private func title(_ key: String) -> String { Metric(rawValue: key)?.title ?? key }

    private func load() async {
        let h = monitor.history
        temps = await h.series(tempMetrics.map(\.rawValue), range: range)
        fans = await h.series([Metric.fanRPM.rawValue], range: range)
        charge = await h.series([Metric.batteryPercent.rawValue], range: range)
        charging = await h.series([Metric.charging.rawValue], range: range)
        let s = await h.stats()
        stats = "\(s.rawRows) raw · \(s.minuteRows) minute rows · \(ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file))"
    }
}
