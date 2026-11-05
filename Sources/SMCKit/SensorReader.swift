import Foundation

/// Owns the SMC connection and the HID client; produces one `Snapshot` per call.
/// Read-only. All hardware access is serialized on this actor.
public actor SensorReader {
    private let smc: SMCClient?
    private let hid = HIDTemperatureReader()
    private var catalog: SensorCatalog
    private let fanCount: Int

    public init(catalog: SensorCatalog = SensorCatalog()) {
        let smc = try? SMCClient()
        self.smc = smc
        self.catalog = catalog
        self.fanCount = Int(smc?.number("FNum") ?? 0)
    }

    public var smcAvailable: Bool { smc != nil }

    public func setCatalog(_ catalog: SensorCatalog) { self.catalog = catalog }

    private var pruned = false

    public func snapshot() -> Snapshot {
        let battery = SensorCatalog.smcBatteryKeys.compactMap { key in
            smc?.number(key).map { (key: key, celsius: $0) }
        }
        let raw = hid.read()
        if !pruned {
            // Stop polling services we never show: unused channels, battery duplicates, and the
            // 2nd/3rd copy of each same-named die sensor (the copies agree within ~1 °C, and every
            // HID event read is an IPC round trip — this cuts per-sample cost by about two thirds).
            var seen = Set<String>()
            let skip = raw.filter { r in
                catalog.defaultGroup(forHIDName: r.name) == nil || !seen.insert(r.name).inserted
            }
            hid.disable(skip.map(\.index))
            pruned = true
        }
        let sensors = catalog.readings(hid: raw, smcBattery: battery)
        return Snapshot(date: Date(), sensors: sensors, fans: readFans(), battery: BatteryStatus.read())
    }

    private func readFans() -> [FanStatus] {
        guard let smc else { return [] }
        return (0..<fanCount).map { n in
            FanStatus(
                id: n,
                actualRPM: smc.number("F\(n)Ac") ?? 0,
                targetRPM: smc.number("F\(n)Tg") ?? 0,
                minRPM: smc.number("F\(n)Mn") ?? 0,
                maxRPM: smc.number("F\(n)Mx") ?? 0,
                manual: (smc.number("F\(n)md") ?? 0) != 0,
                state: FanStatus.State(Int(smc.number("F\(n)St") ?? -1)))
        }
    }

    /// Full raw SMC dump for the debug view. Takes a few seconds.
    public func dumpAllKeys() -> [SMCValue] {
        guard let smc else { return [] }
        return smc.allKeys().compactMap { try? smc.read($0) }
    }
}
