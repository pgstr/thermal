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
        didSet { defaults.set(target, forKey: "coolCharging.target"); coolCharging.target = effectiveTarget }
    }
    var cap: Double {
        didSet { defaults.set(cap, forKey: "coolCharging.cap"); coolCharging.cap = cap }
    }

    /// Slow-changing status for the UI (rpm rounded to 100) so hidden views don't redraw each second.
    private(set) var state: State = .idle
    private(set) var cantReach = false
    /// Whether the cool-charging rule currently applies (toggle on, on AC, not full).
    private(set) var coolChargingApplies = false
    /// AlDente's settings (re-read every 30 s); when its heat protection is on, the target follows it.
    private(set) var alDente: AlDenteSettings?
    @ObservationIgnored private var lastAlDenteRead = Date.distantPast
    /// AlDente's live state from the "AlDente State" shortcut; nil = unknown (inferred logic used).
    private(set) var alDenteState: AlDenteState?
    private(set) var alDenteShortcutMissing = false
    @ObservationIgnored private var lastStateRead = Date.distantPast
    @ObservationIgnored private var stateReadInFlight = false

    /// The target actually used: AlDente's heat-protection temperature when available.
    var effectiveTarget: Double {
        if let a = alDente, a.heatProtection { return a.maxTemperature }
        return target
    }

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
        if s.date.timeIntervalSince(lastAlDenteRead) >= 30 {
            lastAlDenteRead = s.date
            set(\.alDente, AlDenteSettings.read())
            coolCharging.alDente = alDente
            coolCharging.target = effectiveTarget
        }
        refreshAlDenteState(s)
        var proposals: [FanProposal] = []
        if let p = safety.evaluate(s) { proposals.append(p) }
        if let p = coolCharging.evaluate(s, now: s.date) { proposals.append(p) }
        // Test hook (not in the UI): `defaults write dev.streller.thermal debug.forceRPM 3000`,
        // remove with `defaults delete dev.streller.thermal debug.forceRPM`.
        let forced = defaults.double(forKey: "debug.forceRPM")
        if forced > 0 { proposals.append(FanProposal(source: "debug", minimumRPM: forced, reason: "Debug: forced \(Int(forced)) rpm")) }
        set(\.coolChargingApplies, coolCharging.applies(s))
        set(\.cantReach, coolCharging.cantReach)

        // Approval happens in System Settings, so re-check while not enabled (cheap, every 5 s).
        if !helper.isEnabled, Int(s.date.timeIntervalSince1970) % 5 == 0 { helper.refresh() }

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

    /// Every 30 s while on the charger and Cool charging is on (every 5 min if the shortcut is missing).
    /// Runs in the background; the result is used from the next sample on.
    private func refreshAlDenteState(_ s: Snapshot) {
        guard coolChargingEnabled, s.battery?.externalConnected == true else {
            if alDenteState != nil { alDenteState = nil; coolCharging.alDenteState = nil }
            return
        }
        let interval: TimeInterval = alDenteShortcutMissing ? 300 : 30
        guard !stateReadInFlight, s.date.timeIntervalSince(lastStateRead) >= interval else { return }
        lastStateRead = s.date
        stateReadInFlight = true
        Task {
            let state = await AlDenteStateReader.read()
            self.stateReadInFlight = false
            self.set(\.alDenteShortcutMissing, state == nil)
            self.set(\.alDenteState, state)
            self.coolCharging.alDenteState = state
        }
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
