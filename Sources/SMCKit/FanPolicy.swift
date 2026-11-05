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
    /// Degrees the curve acts early while AlDente reports Charging (prevention beats recovery).
    public static let chargingLead = 1.0

    /// AlDente's settings when available; they define when charging is wanted (see `applies`).
    public var alDente: AlDenteSettings?
    /// AlDente's live state (from its Shortcuts action). When known it replaces the inference.
    public var alDenteState: AlDenteState?

    public private(set) var currentRPM: Double = 0          // 0 = no proposal
    public private(set) var cantReach = false
    /// True from "charging is wanted" (charging seen, or charge ≤ resume level) until the limit is
    /// reached or the Mac is unplugged. A non-charging state inside a session is a heat pause.
    public private(set) var sessionActive = false
    private var lastEvaluation = Date.distantPast
    private var belowSince: Date?
    private var atCapAboveTargetSince: Date?

    public init(enabled: Bool = false, target: Double = 28, cap: Double = 6000) {
        self.enabled = enabled
        self.target = target
        self.cap = cap
    }

    /// NotChargingReason bit seen at a charge limit. NOTE: AlDente's heat pause sets the macOS
    /// limit to the *current* level, so after a few seconds it reports this same bit; the reason
    /// code alone cannot tell "limit reached" from "heat pause". Hence the session logic below.
    public static let limitReachedBit = 0x0100_0000
    /// Without AlDente settings: assume charging resumes at or below this level.
    public static let fallbackResumeLevel = 76
    /// Pre-cool this many percent above the resume level, so charging can start right away.
    public static let preCoolMargin = 1

    /// Whether cooling makes sense now: toggle on, on AC, not full, and charging is wanted:
    /// - charging, or
    /// - charge ≤ resume level + margin (charging due or imminent; pre-cool), or
    /// - inside a charging session below the limit but not charging (AlDente heat pause).
    /// Normal sailing between resume level and limit does not cool.
    public func applies(_ s: Snapshot) -> Bool {
        guard enabled, let b = s.battery, b.externalConnected, !b.fullyCharged else { return false }
        if let state = alDenteState {
            // Exact: cool only when AlDente would charge if not for the temperature.
            switch state {
            case .heatProtect: return true
            case .charging: return true     // the curve only acts near the target (prevents a pause)
            case .sailing: return b.percent <= resumeLevel + Self.preCoolMargin
            default: return false
            }
        }
        if b.isCharging { return true }
        if b.percent <= resumeLevel + Self.preCoolMargin { return true }
        return sessionActive && b.percent < chargeLimit
    }

    private var resumeLevel: Int { alDente?.resumeLevel ?? Self.fallbackResumeLevel }
    private var chargeLimit: Int { alDente?.chargeLimit ?? 100 }

    /// Track the charging session (call once per sample, before `applies`).
    public mutating func observe(_ s: Snapshot) {
        defer { seenAnySample = true }
        guard let b = s.battery, b.externalConnected else { sessionActive = false; return }
        if b.fullyCharged || b.percent >= chargeLimit { sessionActive = false; return }
        if b.isCharging || b.percent <= resumeLevel { sessionActive = true; return }
        // At launch we have no history: below the limit, not charging and at/above AlDente's heat
        // threshold is most likely a heat pause; cooling is the safe guess.
        if !sessionActive, !seenAnySample, let a = alDente, a.heatProtection,
           let t = s.batteryTemperature, t >= a.maxTemperature {
            sessionActive = true
        }
    }

    private var seenAnySample = false

    /// Pure curve: battery temperature → minimum rpm (0 = hand back to Apple).
    public func curve(battery t: Double, minRPM: Double) -> Double {
        let low = target - 1.5, high = target + 1.5
        if t <= low { return 0 }
        if t <= target { return minRPM + (Self.midRPM - minRPM) * (t - low) / (target - low) }
        if t <= high { return Self.midRPM + (cap - Self.midRPM) * (t - target) / (high - target) }
        return cap
    }

    public mutating func evaluate(_ s: Snapshot, now: Date) -> FanProposal? {
        observe(s)
        guard applies(s), let t = s.batteryTemperature, let minRPM = s.fans.map(\.minRPM).max() else {
            reset()
            return nil
        }
        if now.timeIntervalSince(lastEvaluation) >= Self.evaluationInterval {
            lastEvaluation = now
            // While AlDente is charging, act 1 °C early: a heat pause costs ≥ 10 min of charging
            // (AlDente re-checks ~10 min after pausing; observed 19:45:15 → 19:55:17).
            let lead = alDenteState == .charging ? Self.chargingLead : 0
            var wanted = curve(battery: t + lead, minRPM: minRPM)
            // AlDente resumes below its own (lower, unknown) threshold: keep cooling while it waits.
            if alDenteState == .heatProtect { wanted = max(wanted, minRPM) }
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
