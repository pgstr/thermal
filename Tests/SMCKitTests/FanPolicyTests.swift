import Foundation
import Testing
@testable import SMCKit

private func snapshot(battery: Double, die: Double = 50, onAC: Bool = true, percent: Int = 50,
                      fanRPM: Double = 0, charging: Bool? = nil, reason: Int = 0,
                      date: Date = Date(timeIntervalSince1970: 1_000_000)) -> Snapshot {
    let fans = (0..<2).map {
        FanStatus(id: $0, actualRPM: fanRPM, targetRPM: 0, minRPM: 2317, maxRPM: 7826, manual: false,
                  state: fanRPM > 0 ? .running : .stopped)
    }
    let b = BatteryStatus(percent: percent, isCharging: charging ?? onAC, externalConnected: onAC, fullyCharged: false,
                          voltage: 12, amperage: 2000, cycleCount: 2, designCapacity: 6249, rawMaxCapacity: 6286,
                          notChargingReason: reason, adapterWatts: 96)
    return Snapshot(date: date, sensors: [
        SensorReading(id: "smc:TB0T", name: "Battery 1", group: .battery, celsius: battery),
        SensorReading(id: "hid:PMU tdie1", name: "Die 1", group: .soc, celsius: die),
    ], fans: fans, battery: b)
}

@Suite struct CoolChargingCurve {
    let rule = CoolCharging(enabled: true, target: 28, cap: 6000)

    @Test func handsBackWhenCool() {
        #expect(rule.curve(battery: 26.5, minRPM: 2317) == 0)
        #expect(rule.curve(battery: 25, minRPM: 2317) == 0)
    }

    @Test func rampsBetweenMinAndCap() {
        #expect(abs(rule.curve(battery: 26.6, minRPM: 2317) - 2429) < 1)   // just above hand-back
        #expect(rule.curve(battery: 28, minRPM: 2317) == 4000)
        #expect(rule.curve(battery: 28.75, minRPM: 2317) == 5000)
        #expect(rule.curve(battery: 29.5, minRPM: 2317) == 6000)
        #expect(rule.curve(battery: 32, minRPM: 2317) == 6000)
    }
}

@Suite struct CoolChargingBehaviour {
    @Test func inactiveWhenDisabledOrOnBattery() {
        var off = CoolCharging(enabled: false)
        #expect(off.evaluate(snapshot(battery: 30), now: .now) == nil)
        var onBattery = CoolCharging(enabled: true)
        #expect(onBattery.evaluate(snapshot(battery: 30, onAC: false), now: .now) == nil)
    }

    let alDente = AlDenteSettings(chargeLimit: 85, sailingLevel: 5, heatProtection: true, maxTemperature: 28)
    let limitBit = CoolCharging.limitReachedBit

    @Test func appliesWhileChargingAndNearResumeLevel() {
        var r = CoolCharging(enabled: true); r.alDente = alDente
        #expect(r.applies(snapshot(battery: 30, percent: 83)))                                   // charging
        #expect(r.applies(snapshot(battery: 30, percent: 81, charging: false, reason: limitBit))) // resume 80 + 1: pre-cool
        #expect(!r.applies(snapshot(battery: 30, percent: 83, charging: false, reason: limitBit)))// sailing: no session
        #expect(!r.applies(snapshot(battery: 30, onAC: false)))
    }

    @Test func heatPauseInsideSessionKeepsCooling() {
        // The observed deadlock: AlDente heat-pauses at 82 %, macOS then reports the limit bit.
        var r = CoolCharging(enabled: true); r.alDente = alDente
        r.observe(snapshot(battery: 27, percent: 80))                        // charging session starts
        r.observe(snapshot(battery: 28.5, percent: 82))                      // charging, warming up
        let paused = snapshot(battery: 28.5, percent: 82, charging: false, reason: limitBit)
        r.observe(paused)
        #expect(r.sessionActive)
        #expect(r.applies(paused))
        r.observe(snapshot(battery: 27, percent: 85, charging: false, reason: limitBit))  // limit reached
        #expect(!r.sessionActive)
    }

    @Test func launchHeuristicAssumesHeatPauseWhenWarm() {
        var warm = CoolCharging(enabled: true); warm.alDente = alDente
        let s = snapshot(battery: 29, percent: 83, charging: false, reason: limitBit)
        warm.observe(s)
        #expect(warm.applies(s))
        var cool = CoolCharging(enabled: true); cool.alDente = alDente
        let c = snapshot(battery: 26, percent: 83, charging: false, reason: limitBit)
        cool.observe(c)
        #expect(!cool.applies(c))     // just sailing
    }

    @Test func fallbackWithoutAlDente() {
        let r = CoolCharging(enabled: true)
        #expect(r.applies(snapshot(battery: 30, percent: 77, charging: false, reason: limitBit)))   // ≤ 76 + 1
        #expect(!r.applies(snapshot(battery: 30, percent: 79, charging: false, reason: limitBit)))
    }

    @Test func holdsMinimumBeforeHandingBack() {
        var r = CoolCharging(enabled: true)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(r.evaluate(snapshot(battery: 28), now: t0)?.minimumRPM == 4000)
        // Cooled down: keeps min rpm until 60 s below the hand-back point…
        #expect(r.evaluate(snapshot(battery: 26), now: t0 + 10)?.minimumRPM == 2317)
        #expect(r.evaluate(snapshot(battery: 26), now: t0 + 60)?.minimumRPM == 2317)
        // …then hands back.
        #expect(r.evaluate(snapshot(battery: 26), now: t0 + 70) == nil)
    }

    @Test func onlyReevaluatesEveryTenSeconds() {
        var r = CoolCharging(enabled: true)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(r.evaluate(snapshot(battery: 28), now: t0)?.minimumRPM == 4000)
        #expect(r.evaluate(snapshot(battery: 29.5), now: t0 + 5)?.minimumRPM == 4000)
        #expect(r.evaluate(snapshot(battery: 29.5), now: t0 + 10)?.minimumRPM == 6000)
    }

    @Test func flagsCantReachAfterFifteenMinutesAtCap() {
        var r = CoolCharging(enabled: true)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in stride(from: 0, through: 900, by: 10) { _ = r.evaluate(snapshot(battery: 30), now: t0 + Double(i)) }
        #expect(r.cantReach)
        _ = r.evaluate(snapshot(battery: 27.5), now: t0 + 910)
        #expect(!r.cantReach)
    }
}

@Suite struct Safety {
    @Test func tripsAndReleasesWithHysteresis() {
        var s = SafetyOverride()
        #expect(s.evaluate(snapshot(battery: 30, die: 94)) == nil)
        #expect(s.evaluate(snapshot(battery: 30, die: 95))?.minimumRPM == 7826)
        #expect(s.evaluate(snapshot(battery: 30, die: 91)) != nil)    // still above release
        #expect(s.evaluate(snapshot(battery: 30, die: 89)) == nil)
        #expect(s.evaluate(snapshot(battery: 36, die: 50)) != nil)
        #expect(s.evaluate(snapshot(battery: 34, die: 50)) != nil)
        #expect(s.evaluate(snapshot(battery: 32.9, die: 50)) == nil)
    }
}

@Suite struct Arbiter {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func noProposalMeansApple() {
        var a = FanArbiter()
        #expect(a.step(proposals: [], snapshot: snapshot(battery: 25), now: t0) == nil)
    }

    @Test func takesOverFromStoppedFansAtMinimumAndRamps() {
        var a = FanArbiter()
        let p = [FanProposal(source: "coolCharging", minimumRPM: 4000, reason: "")]
        #expect(a.step(proposals: p, snapshot: snapshot(battery: 28), now: t0) == 2567)      // 2317 + 250
        #expect(a.step(proposals: p, snapshot: snapshot(battery: 28), now: t0 + 1) == 2817)
        #expect(a.step(proposals: p, snapshot: snapshot(battery: 28), now: t0 + 10) == 4000)
    }

    @Test func takesOverFromSpinningFansWithoutAJump() {
        var a = FanArbiter()
        let p = [FanProposal(source: "coolCharging", minimumRPM: 2317, reason: "")]
        // Apple is running the fans at 3500; we start there and ramp down slowly.
        #expect(a.step(proposals: p, snapshot: snapshot(battery: 28, fanRPM: 3500), now: t0) == 3350)
    }

    @Test func highestWinsAndSafetySkipsRamp() {
        var a = FanArbiter()
        let p = [FanProposal(source: "coolCharging", minimumRPM: 4000, reason: ""),
                 FanProposal(source: "safety", minimumRPM: 7826, reason: "")]
        #expect(a.step(proposals: p, snapshot: snapshot(battery: 36), now: t0) == 7826)
    }

    @Test func clampsToFanLimits() {
        var a = FanArbiter()
        let p = [FanProposal(source: "x", minimumRPM: 100, reason: "")]
        #expect(a.step(proposals: p, snapshot: snapshot(battery: 28), now: t0) == 2317)
    }
}

@Suite struct AlDenteLiveState {
    let alDente = AlDenteSettings(chargeLimit: 85, sailingLevel: 5, heatProtection: true, maxTemperature: 28)
    let limitBit = CoolCharging.limitReachedBit

    func rule(_ state: AlDenteState) -> CoolCharging {
        var r = CoolCharging(enabled: true); r.alDente = alDente; r.alDenteState = state; return r
    }

    @Test func parsesShortcutOutput() {
        #expect(AlDenteState("HeatProtect\n") == .heatProtect)
        #expect(AlDenteState("Sailing") == .sailing)
        #expect(AlDenteState("Something new") == .other("Something new"))
    }

    @Test func stateDecidesWhetherToCool() {
        let s = snapshot(battery: 29, percent: 83, charging: false, reason: limitBit)
        #expect(rule(.heatProtect).applies(s))
        #expect(!rule(.sailing).applies(s))                                    // 83 > 80 + 1
        #expect(rule(.sailing).applies(snapshot(battery: 29, percent: 81, charging: false, reason: limitBit)))
        #expect(!rule(.discharging).applies(s))
        #expect(rule(.charging).applies(snapshot(battery: 29, percent: 82)))
    }

    @Test func actsEarlyWhileCharging() {
        var charging = rule(.charging)
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        // 27 °C while charging behaves like 28 °C: 4000 rpm (without lead it would be ~3439).
        #expect(charging.evaluate(snapshot(battery: 27, percent: 82), now: t0)?.minimumRPM == 4000)
        var heat = rule(.heatProtect)
        #expect(heat.evaluate(snapshot(battery: 27, percent: 82, charging: false), now: t0)?.minimumRPM ?? 0 < 4000)
    }

    @Test func keepsMinimumWhileHeatProtectEvenWhenCool() {
        // AlDente still paused at 26.3 °C (observed): never hand back while it waits.
        var r = rule(.heatProtect)
        let p = r.evaluate(snapshot(battery: 26.3, percent: 81, charging: false, reason: limitBit), now: Date(timeIntervalSince1970: 2_000_000))
        #expect(p?.minimumRPM == 2317)
    }
}
