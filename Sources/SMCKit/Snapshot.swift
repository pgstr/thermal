import Foundation

public enum SensorGroup: String, Sendable, CaseIterable, Codable {
    case battery, cpu, gpu, soc, storage, other

    public var title: String {
        switch self {
        case .battery: "Battery"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .soc: "SoC dies"   // die sensors not yet mapped to CPU or GPU
        case .storage: "Storage"
        case .other: "Other"
        }
    }
}

public struct SensorReading: Sendable, Identifiable, Equatable {
    /// Stable across launches, e.g. "smc:TB0T" or "hid:PMU tdie3@2"; used as the history key.
    public let id: String
    public let name: String
    public let group: SensorGroup
    public let celsius: Double
}

public struct FanStatus: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case stopped, starting, running, spinningDown, unknown(Int)
        init(_ raw: Int) {
            switch raw {
            case 1: self = .starting
            case 2: self = .spinningDown
            case 3: self = .stopped
            case 5: self = .running
            default: self = .unknown(raw)
            }
        }
    }

    public let id: Int
    public let actualRPM: Double
    public let targetRPM: Double
    public let minRPM: Double
    public let maxRPM: Double
    /// true when something (Fandy, later our helper) has set manual mode (`F{n}md = 1`).
    public let manual: Bool
    public let state: State
}

public struct Snapshot: Sendable {
    public let date: Date
    public let sensors: [SensorReading]
    public let fans: [FanStatus]
    public let battery: BatteryStatus?

    public func sensors(in group: SensorGroup) -> [SensorReading] { sensors.filter { $0.group == group } }
    public func max(_ group: SensorGroup) -> Double? { sensors(in: group).map(\.celsius).max() }
    public func average(_ group: SensorGroup) -> Double? {
        let v = sensors(in: group).map(\.celsius)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// Battery temperature: mean of the SMC battery sensors.
    public var batteryTemperature: Double? { average(.battery) }

    /// Hottest die across CPU, GPU and unmapped SoC sensors.
    public var hottestDie: Double? {
        [max(.cpu), max(.gpu), max(.soc)].compactMap { $0 }.max()
    }

    public var fansSpinning: Bool { fans.contains { $0.actualRPM > 0 } }
    public var averageFanRPM: Double {
        fans.isEmpty ? 0 : fans.map(\.actualRPM).reduce(0, +) / Double(fans.count)
    }
}
