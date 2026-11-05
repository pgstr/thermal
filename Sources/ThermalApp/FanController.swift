import Foundation
import Observation
import SMCKit

/// Turns snapshots into fan commands (SPEC §5.2): safety + cool charging → highest wins → ramp →
/// helper (with a 10 s lease, renewed every second). No proposal → fans go back to Apple.
@MainActor @Observable
final class FanController {
    enum State: Equatable {
        case idle                         // nothing wants the fans; Apple controls them
        case active(rpm: Int, reason: String)
        case blocked(String)              // a rule wants the fans but we may not drive them
    }

    // Persisted settings.
    var coolChargingEnabled: Bool {
        didSet { defaults.set(coolChargingEnabled, forKey: "coolCharging.enabled"); coolCharging.enabled = coolChargingEnabled }
    }
    var target: Double {
        didSet { defaults.set(target, forKey: "coolCharging.target"); coolCharging.target = target }
    }
    var cap: Double {
        didSet { defaults.set(cap, forKey: "coolCharging.cap"); coolCharging.cap = cap }
    }

    /// Slow-changing status for the UI (rpm rounded to 100) so hidden views don't redraw each second.
    private(set) var state: State = .idle
    private(set) var cantReach = false
    /// Whether the cool-charging rule currently applies (toggle on, on AC, not full).
    private(set) var coolChargingApplies = false

    let helper = FanHelperClient()
    static let lease: Double = 10

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var coolCharging: CoolCharging
    @ObservationIgnored private var safety = SafetyOverride()
    @ObservationIgnored private var arbiter = FanArbiter()
    @ObservationIgnored private var commanding = false
    @ObservationIgnored private var suspended = false

    init() {
        let enabled = defaults.bool(forKey: "coolCharging.enabled")
        let target = defaults.object(forKey: "coolCharging.target") as? Double ?? 28
        let cap = defaults.object(forKey: "coolCharging.cap") as? Double ?? 6000
        coolChargingEnabled = enabled
        self.target = target
        self.cap = cap
        coolCharging = CoolCharging(enabled: enabled, target: target, cap: cap)
    }

    func update(with s: Snapshot, fandyRunning: Bool) async {
        guard !suspended else { return }
        var proposals: [FanProposal] = []
        if let p = safety.evaluate(s) { proposals.append(p) }
        if let p = coolCharging.evaluate(s, now: s.date) { proposals.append(p) }
        set(\.coolChargingApplies, coolCharging.applies(s))
        set(\.cantReach, coolCharging.cantReach)

        if fandyRunning || !helper.isEnabled {
            if commanding { _ = await helper.setAuto(); commanding = false }
            arbiter = FanArbiter()
            let why = fandyRunning ? "Fandy is running — quit it to let Thermal control the fans"
                                   : "Fan control is not enabled"
            set(\.state, proposals.isEmpty ? .idle : .blocked(why))
            return
        }

        guard let rpm = arbiter.step(proposals: proposals, snapshot: s, now: s.date) else {
            if commanding { _ = await helper.setAuto(); commanding = false }
            set(\.state, .idle)
            return
        }
        if let error = await helper.setTarget(rpm, lease: Self.lease) {
            commanding = false
            arbiter = FanArbiter()
            set(\.state, .blocked(error))
            return
        }
        commanding = true
        let top = proposals.max { $0.minimumRPM < $1.minimumRPM }
        set(\.state, .active(rpm: Int((rpm / 100).rounded() * 100), reason: top?.reason ?? ""))
    }

    /// Before sleep / on quit: hand the fans back and pause until `resume()`.
    func suspend() async {
        suspended = true
        if commanding { _ = await helper.setAuto(); commanding = false }
        arbiter = FanArbiter()
        set(\.state, .idle)
    }

    func resume() { suspended = false }

    /// Assign only on change, so observers aren't invalidated every second.
    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<FanController, T>, _ value: T) {
        if self[keyPath: kp] != value { self[keyPath: kp] = value }
    }
}
