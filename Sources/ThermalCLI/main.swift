import Foundation
import SMCKit

// `thermal` — prints one snapshot (or one per second with `--watch`), using the same SMCKit
// code as the app. Read-only.

func fmt(_ v: Double?, _ unit: String = "°C") -> String { v.map { String(format: "%.1f%@", $0, unit) } ?? "–" }

func printSnapshot(_ s: Snapshot) {
    print("== \(s.date.formatted(date: .omitted, time: .standard)) ==")
    if let b = s.battery {
        print(String(format: "Battery  %d%%  %@  %.1f W  temp %@  cycles %d  health %.1f%%",
                     b.percent, b.chargeState, b.batteryWatts, fmt(s.batteryTemperature), b.cycleCount, b.health ?? 0))
    }
    for f in s.fans {
        print(String(format: "Fan %d    %4.0f rpm (target %4.0f, %4.0f–%4.0f)  %@  %@",
                     f.id, f.actualRPM, f.targetRPM, f.minRPM, f.maxRPM, f.manual ? "MANUAL" : "auto", "\(f.state)"))
    }
    for g in SensorGroup.allCases {
        let list = s.sensors(in: g)
        guard !list.isEmpty else { continue }
        print("\(g.title.padding(toLength: 9, withPad: " ", startingAt: 0)) max \(fmt(s.max(g)))  avg \(fmt(s.average(g)))  (\(list.count) sensors)")
        if CommandLine.arguments.contains("-v") {
            for r in list { print("    \(r.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(fmt(r.celsius))   \(r.id)") }
        }
    }
}

let reader = SensorReader()
guard await reader.smcAvailable else {
    FileHandle.standardError.write("cannot open AppleSMC\n".data(using: .utf8)!)
    exit(1)
}

if CommandLine.arguments.contains("--bench") {
    _ = await reader.snapshot()   // first call also prunes unused HID services
    let n = 20, start = Date()
    for _ in 0..<n { _ = await reader.snapshot() }
    print(String(format: "steady-state snapshot: %.1f ms", Date().timeIntervalSince(start) * 1000 / Double(n)))
} else if CommandLine.arguments.contains("--watch") {
    while true {
        printSnapshot(await reader.snapshot())
        try await Task.sleep(for: .seconds(1))
    }
} else {
    let start = Date()
    let s = await reader.snapshot()
    printSnapshot(s)
    print(String(format: "(snapshot took %.1f ms)", Date().timeIntervalSince(start) * 1000))
}
