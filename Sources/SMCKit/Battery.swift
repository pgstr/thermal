import Foundation
import IOKit

/// Battery and charger state from the `AppleSmartBattery` IORegistry entry (no privileges needed).
/// Temperature is NOT taken from here: on macOS 27 it is unreliable; use SMC `TB0T…TB2T`.
public struct BatteryStatus: Sendable, Equatable {
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    public var voltage: Double            // V
    public var amperage: Int              // mA, + charging / − discharging
    public var cycleCount: Int
    public var designCapacity: Int        // mAh
    public var rawMaxCapacity: Int        // mAh
    public var notChargingReason: Int     // 0 = none; 4096 = held by a charge limit (AlDente / macOS)
    public var adapterWatts: Int?

    /// Power flowing into (+) or out of (−) the battery, in watts.
    public var batteryWatts: Double { voltage * Double(amperage) / 1000 }

    /// Raw max capacity ÷ design capacity, in percent.
    public var health: Double? {
        designCapacity > 0 ? Double(rawMaxCapacity) / Double(designCapacity) * 100 : nil
    }

    public var chargeState: String {
        if !externalConnected { return "On battery" }
        if isCharging { return "Charging" }
        if fullyCharged { return "Full" }
        if notChargingReason == 4096 { return "Paused (charge limit)" }
        if notChargingReason != 0 { return "Not charging (reason \(notChargingReason))" }
        return "Not charging"
    }

    public static func read() -> BatteryStatus? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let batteryData = dict["BatteryData"] as? [String: Any] ?? [:]
        let charger = dict["ChargerData"] as? [String: Any] ?? [:]
        let adapter = dict["AdapterDetails"] as? [String: Any] ?? [:]

        func int(_ key: String, _ sources: [String: Any]...) -> Int? {
            for s in sources { if let n = s[key] as? NSNumber { return n.intValue } }
            return nil
        }
        func bool(_ key: String) -> Bool {
            if let b = dict[key] as? Bool { return b }
            return (dict[key] as? NSNumber)?.boolValue ?? false
        }

        return BatteryStatus(
            percent: int("CurrentCapacity", dict, batteryData) ?? 0,
            isCharging: bool("IsCharging"),
            externalConnected: bool("ExternalConnected"),
            fullyCharged: bool("FullyCharged"),
            voltage: Double(int("Voltage", dict, batteryData) ?? 0) / 1000,
            amperage: int("InstantAmperage", dict) ?? int("Amperage", dict) ?? 0,
            cycleCount: int("CycleCount", dict, batteryData) ?? 0,
            designCapacity: int("DesignCapacity", batteryData, dict) ?? 0,
            rawMaxCapacity: int("AppleRawMaxCapacity", batteryData, dict) ?? 0,
            notChargingReason: int("NotChargingReason", charger) ?? 0,
            adapterWatts: int("Watts", adapter)
        )
    }
}
