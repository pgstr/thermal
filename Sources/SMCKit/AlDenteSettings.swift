import Foundation

/// AlDente's charging settings, read (never written) from its preferences domain.
/// Keys observed on AlDente Pro, 2026-11: `chargeVal` (limit %), `sailingMode`/`sailingLevel`
/// (resume charging at limit − level), `heatProtectMode`/`maxTemperature` (pause charging at °C).
public struct AlDenteSettings: Sendable, Equatable {
    public var chargeLimit: Int
    public var sailingLevel: Int           // 0 when sailing is off
    public var heatProtection: Bool
    public var maxTemperature: Double

    public init(chargeLimit: Int, sailingLevel: Int, heatProtection: Bool, maxTemperature: Double) {
        self.chargeLimit = chargeLimit
        self.sailingLevel = sailingLevel
        self.heatProtection = heatProtection
        self.maxTemperature = maxTemperature
    }

    /// Charge level at which AlDente starts charging again.
    public var resumeLevel: Int { chargeLimit - sailingLevel }

    public static let domain = "com.apphousekitchen.aldente-pro"

    public static func read() -> AlDenteSettings? {
        CFPreferencesAppSynchronize(domain as CFString)
        func value(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain as CFString) }
        func int(_ key: String) -> Int? { (value(key) as? NSNumber)?.intValue }
        guard let limit = int("chargeVal"), (20...100).contains(limit) else { return nil }
        let sailing = (int("sailingMode") ?? 0) != 0 ? (int("sailingLevel") ?? 0) : 0
        return AlDenteSettings(
            chargeLimit: limit,
            sailingLevel: max(0, sailing),
            heatProtection: (int("heatProtectMode") ?? 0) != 0,
            maxTemperature: (value("maxTemperature") as? NSNumber)?.doubleValue ?? 35)
    }
}

/// AlDente's live state, from its Shortcuts "Get State" action (via a user-created shortcut
/// named "AlDente State"). Values observed/found in AlDente Pro: Charging, Discharging,
/// HeatProtect, Sailing, Calibration.
public enum AlDenteState: Sendable, Equatable {
    case charging, discharging, heatProtect, sailing, calibration
    case other(String)

    public init(_ raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "charging": self = .charging
        case "discharging": self = .discharging
        case "heatprotect": self = .heatProtect
        case "sailing": self = .sailing
        case "calibration": self = .calibration
        default: self = .other(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public var title: String {
        switch self {
        case .charging: "Charging"
        case .discharging: "Discharging"
        case .heatProtect: "Paused by heat protection"
        case .sailing: "Sailing"
        case .calibration: "Calibrating"
        case .other(let s): s
        }
    }
}
