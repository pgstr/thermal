import Foundation

/// A source's wish for the fans: a minimum rpm, with a reason shown in the UI.
public struct FanProposal: Sendable, Equatable {
    public let source: String
    public let minimumRPM: Double
    public let reason: String

    public init(source: String, minimumRPM: Double, reason: String) {
        self.source = source
        self.minimumRPM = minimumRPM
        self.reason = reason
    }
}

/// Safety overrides (SPEC §5.2): always on. Any die ≥ 95 °C or battery ≥ 36 °C → maximum rpm,
/// until back under the threshold minus the release margin.
public struct SafetyOverride: Sendable {
    public static let dieTrip = 95.0, dieRelease = 90.0
    public static let batteryTrip = 36.0, batteryRelease = 33.0

    public private(set) var active = false

    public init() {}

    public mutating func evaluate(_ s: Snapshot) -> FanProposal? {
        let die = s.hottestDie ?? 0
        let battery = s.batteryTemperature ?? 0
        if die >= Self.dieTrip || battery >= Self.batteryTrip { active = true }
        if active, die < Self.dieRelease, battery < Self.batteryRelease { active = false }
        guard active, let maxRPM = s.fans.map(\.maxRPM).max(), maxRPM > 0 else { return nil }
        return FanProposal(source: "safety", minimumRPM: maxRPM,
                           reason: String(format: "Safety: die %.0f °C, battery %.1f °C", die, battery))
    }
}

/// "Cool charging" (SPEC §5.3): keep the battery below `target` while charging.
///
/// The curve aims ~1 °C under the target: hand back at ≤ target − 1.5, min rpm at target − 1.5,
/// 4000 rpm at target, `cap` at target + 1.5. Battery temperature moves slowly, so the output is
/// re-evaluated every `evaluationInterval` and held at least `handBackHold` before handing back.
public struct CoolCharging: Sendable {
    public var enabled: Bool
    public var target: Double          // °C, default 28 = AlDente's heat-protection threshold
    public var cap: Double             // rpm ceiling (noise limit)
    public static let midRPM = 4000.0
    public static let evaluationInterval: TimeInterval = 10
    public static let handBackHold: TimeInterval = 60
    public static let cantReachAfter: TimeInterval = 15 * 60

    public private(set) var currentRPM: Double = 0          // 0 = no proposal
    public private(set) var cantReach = false
    private var lastEvaluation = Date.distantPast
    private var belowSince: Date?
    private var atCapAboveTargetSince: Date?

    public init(enabled: Bool = false, target: Double = 28, cap: Double = 6000) {
        self.enabled = enabled
        self.target = target
        self.cap = cap
    }

    /// Whether the rule applies at all right now (toggle on, on AC, battery not full).
    public func applies(_ s: Snapshot) -> Bool {
        guard enabled, let b = s.battery else { return false }
        return b.externalConnected && !b.fullyCharged && b.percent < 100
    }

    /// Pure curve: battery temperature → minimum rpm (0 = hand back to Apple).
    public func curve(battery t: Double, minRPM: Double) -> Double {
        let low = target - 1.5, high = target + 1.5
        if t <= low { return 0 }
        if t <= target { return minRPM + (Self.midRPM - minRPM) * (t - low) / (target - low) }
        if t <= high { return Self.midRPM + (cap - Self.midRPM) * (t - target) / (high - target) }
        return cap
    }

    public mutating func evaluate(_ s: Snapshot, now: Date) -> FanProposal? {
        guard applies(s), let t = s.batteryTemperature, let minRPM = s.fans.map(\.minRPM).max() else {
            reset()
            return nil
        }
        if now.timeIntervalSince(lastEvaluation) >= Self.evaluationInterval {
            lastEvaluation = now
            let wanted = curve(battery: t, minRPM: minRPM)
            if wanted == 0 {
                // Hand back only after staying cool for a while (avoids on/off cycling).
                belowSince = belowSince ?? now
                if currentRPM == 0 || now.timeIntervalSince(belowSince!) >= Self.handBackHold { currentRPM = 0 }
                else { currentRPM = minRPM }
            } else {
                belowSince = nil
                currentRPM = wanted
            }
            if currentRPM >= cap, t >= target {
                atCapAboveTargetSince = atCapAboveTargetSince ?? now
                cantReach = now.timeIntervalSince(atCapAboveTargetSince!) >= Self.cantReachAfter
            } else {
                atCapAboveTargetSince = nil
                cantReach = false
            }
        }
        guard currentRPM > 0 else { return nil }
        return FanProposal(source: "coolCharging", minimumRPM: currentRPM,
                           reason: String(format: "Cool charging: battery %.1f °C → %.0f °C", t, target - 1))
    }

    private mutating func reset() {
        currentRPM = 0
        cantReach = false
        belowSince = nil
        atCapAboveTargetSince = nil
        lastEvaluation = .distantPast
    }
}

/// Combines proposals (highest wins) and limits how fast the commanded rpm changes.
public struct FanArbiter: Sendable {
    public static let rampUp = 250.0     // rpm per second
    public static let rampDown = 150.0

    /// Last commanded rpm; nil = fans are with Apple.
    public private(set) var commanded: Double?
    private var lastUpdate: Date?

    public init() {}

    /// Returns the rpm to command now, or nil to hand the fans back to Apple.
    ///
    /// Starting from Apple's control, the ramp starts at the fans' current actual speed (or the
    /// minimum if they are stopped), so taking over never causes a jump.
    public mutating func step(proposals: [FanProposal], snapshot s: Snapshot, now: Date) -> Double? {
        defer { lastUpdate = now }
        guard let goal = proposals.map(\.minimumRPM).max(), goal > 0 else {
            commanded = nil
            return nil
        }
        let minRPM = s.fans.map(\.minRPM).max() ?? 0
        let maxRPM = s.fans.map(\.maxRPM).max() ?? goal
        let clampedGoal = min(max(goal, minRPM), maxRPM)
        // Safety goes straight to the goal; everything else ramps.
        if proposals.contains(where: { $0.source == "safety" }) {
            commanded = clampedGoal
            return clampedGoal
        }
        let start = commanded ?? max(s.averageFanRPM, minRPM)
        let dt = lastUpdate.map { max(0, min(now.timeIntervalSince($0), 5)) } ?? 1
        let next: Double
        if clampedGoal > start { next = min(clampedGoal, start + Self.rampUp * dt) }
        else { next = max(clampedGoal, start - Self.rampDown * dt) }
        commanded = next
        return next
    }
}
