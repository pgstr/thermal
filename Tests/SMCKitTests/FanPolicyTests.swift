import Foundation
import Testing
@testable import SMCKit

private func snapshot(battery: Double, die: Double = 50, onAC: Bool = true, percent: Int = 50,
                      fanRPM: Double = 0, date: Date = Date(timeIntervalSince1970: 1_000_000)) -> Snapshot {
    let fans = (0..<2).map {
        FanStatus(id: $0, actualRPM: fanRPM, targetRPM: 0, minRPM: 2317, maxRPM: 7826, manual: false,
                  state: fanRPM > 0 ? .running : .stopped)
    }
    let b = BatteryStatus(percent: percent, isCharging: onAC, externalConnected: onAC, fullyCharged: false,
                          voltage: 12, amperage: 2000, cycleCount: 2, designCapacity: 6249, rawMaxCapacity: 6286,
                          notChargingReason: 0, adapterWatts: 96)
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
