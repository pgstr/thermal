import Foundation

/// Turns raw HID/SMC readings into named, grouped, stable sensors.
public struct SensorCatalog: Sendable {
    /// Plausible temperature range; outside it a channel is unused or uncalibrated
    /// (the M5 Pro's `PMU tdevN` channels report about −9200 °C).
    public static let plausible: ClosedRange<Double> = -40...150

    /// Battery sensors read from the SMC. The HID "gas gauge battery" services duplicate these.
    public static let smcBatteryKeys = ["TB0T", "TB1T", "TB2T"]

    /// Per-sensor overrides (id → group), e.g. from the CPU/GPU mapping test.
    public var overrides: [String: SensorGroup]
    public var hidden: Set<String>

    public init(overrides: [String: SensorGroup] = [:], hidden: Set<String> = []) {
        self.overrides = overrides
        self.hidden = hidden
    }

    /// nil = never show and stop polling (duplicates or channels that are never valid).
    public func defaultGroup(forHIDName name: String) -> SensorGroup? {
        let n = name.lowercased()
        if n.hasPrefix("gas gauge battery") { return nil }   // duplicated by SMC TB*T
        if n.hasPrefix("pmu tdev") { return nil }            // unused, ≈ −9200 °C on M5 Pro
        if n.hasPrefix("pmu tdie") { return .soc }
        if n.contains("nand") { return .storage }
        return .other
    }

    /// Friendly display name, e.g. "PMU tdie3" → "Die 3".
    public func displayName(hidName: String) -> String {
        if hidName.hasPrefix("PMU tdie") { return "Die " + hidName.dropFirst("PMU tdie".count) }
        if hidName.hasPrefix("PMU tcal") { return "PMU calibration" }
        if hidName.hasPrefix("NAND") { return hidName.replacingOccurrences(of: " temp", with: "") }
        return hidName
    }

    /// Builds sensor readings from raw HID temperatures and SMC battery values.
    ///
    /// The M5 Pro exposes each die sensor as three HID services with the same name and the same
    /// `LocationID` (values within ~1 °C of each other), so they cannot be told apart reliably.
    /// They are merged into one sensor per name using the **maximum** (`SensorReader` normally polls
    /// only the first copy to save time). Ids are therefore just the name: stable across launches.
    public func readings(hid: [HIDTemperature], smcBattery: [(key: String, celsius: Double)]) -> [SensorReading] {
        var out: [SensorReading] = []
        for (i, b) in smcBattery.enumerated() where Self.plausible.contains(b.celsius) {
            let id = "smc:\(b.key)"
            if hidden.contains(id) { continue }
            out.append(SensorReading(id: id, name: "Battery \(i + 1)", group: overrides[id] ?? .battery, celsius: b.celsius))
        }
        let byName = Dictionary(grouping: hid.filter { Self.plausible.contains($0.celsius) }, by: \.name)
        for name in byName.keys.sorted(using: KeyPathComparator(\.self, comparator: .localizedStandard)) {
            guard let group = defaultGroup(forHIDName: name), let maxValue = byName[name]!.map(\.celsius).max() else { continue }
            let id = "hid:\(name)"
            if hidden.contains(id) { continue }
            out.append(SensorReading(id: id, name: displayName(hidName: name), group: overrides[id] ?? group, celsius: maxValue))
        }
        return out
    }
}
