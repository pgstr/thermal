// ThermalFanHelper: the privileged (root) launchd daemon behind Thermal's fan control.
//
// Deliberately small (SPEC §4):
// - accepts only the FanHelperProtocol calls, only from Thermal.app signed by our team
// - writes only F{n}md / F{n}Tg (allowlist enforced again in CFanWrite), rpm clamped to [Mn, Mx]
// - a manual target is a lease; when it runs out, or the app disconnects, fans go back to Apple
// - fans go back to Apple on start, on SIGTERM/SIGINT and before system sleep

import CFanWrite
import FanHelperProtocol
import Foundation
import IOKit
import IOKit.pwr_mgt
import os

let log = Logger(subsystem: "dev.streller.thermal.fanhelper", category: "helper")

// MARK: - Fan state (all access on `queue`)

final class FanState {
    let queue = DispatchQueue(label: "dev.streller.thermal.fanhelper.state")
    private let conn: UInt32
    private let fanCount: Int
    private var leaseExpiry: Date?        // nil = fans are with Apple
    private var rpm: Double = 0

    init?() {
        conn = cfw_open()
        guard conn != 0 else { return nil }
        var n: UInt8 = 0
        fanCount = cfw_read_u8(conn, "FNum", &n) == 0 ? Int(n) : 0
        guard fanCount > 0 else { return nil }
    }

    var isManual: Bool { leaseExpiry != nil }

    @discardableResult
    func setAuto(_ reason: String) -> String? {
        var errors: [String] = []
        for fan in 0..<fanCount {
            let rc = cfw_write_mode(conn, Int32(fan), 0)
            if rc != 0 { errors.append("F\(fan)md=0 rc=\(rc)") }
        }
        if leaseExpiry != nil || !errors.isEmpty {
            log.notice("fans -> Apple (\(reason, privacy: .public))\(errors.isEmpty ? "" : " errors: " + errors.joined(separator: ", "), privacy: .public)")
        }
        leaseExpiry = nil
        rpm = 0
        return errors.isEmpty ? nil : errors.joined(separator: ", ")
    }

    func setTarget(_ requested: Double, lease: Double) -> String? {
        if leaseExpiry == nil, isFandyRunning() {
            return "Fandy is running; quit it before Thermal can control the fans"
        }
        let lease = min(max(lease, 1), FanHelperInfo.maxLease)
        var errors: [String] = []
        var applied = requested
        for fan in 0..<fanCount {
            var mn: Float = 0, mx: Float = 0
            guard cfw_read_float(conn, "F\(fan)Mn", &mn) == 0, cfw_read_float(conn, "F\(fan)Mx", &mx) == 0, mx > mn else {
                errors.append("F\(fan) limits unreadable")
                continue
            }
            applied = min(max(requested, Double(mn)), Double(mx))
            var md: UInt8 = 0
            if cfw_read_u8(conn, "F\(fan)md", &md) != 0 || md != 1 {
                let rc = cfw_write_mode(conn, Int32(fan), 1)
                if rc != 0 { errors.append("F\(fan)md=1 rc=\(rc)") }
            }
            // Written right after the mode: mode alone makes the firmware pick its own target (M1).
            let rc = cfw_write_target(conn, Int32(fan), Float(applied))
            if rc != 0 { errors.append("F\(fan)Tg rc=\(rc)") }
        }
        if !errors.isEmpty {
            setAuto("write failed")
            return errors.joined(separator: ", ")
        }
        if leaseExpiry == nil { log.notice("fans -> manual \(Int(applied)) rpm") }
        rpm = applied
        leaseExpiry = Date().addingTimeInterval(lease)
        return nil
    }

    func tick() {
        if let e = leaseExpiry, Date() > e { setAuto("lease expired") }
    }

    var status: String {
        guard let e = leaseExpiry else { return "auto" }
        return String(format: "manual %.0f %.1f", rpm, e.timeIntervalSinceNow)
    }

    private func isFandyRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-xq", "Fandy"]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

let state: FanState = {
    guard let s = FanState() else {
        log.error("cannot open AppleSMC or no fans; exiting")
        exit(1)
    }
    return s
}()

// MARK: - XPC

final class Service: NSObject, FanHelperProtocol {
    func version(reply: @escaping @Sendable (String) -> Void) { reply(FanHelperInfo.version) }

    func setTarget(rpm: Double, leaseSeconds: Double, reply: @escaping @Sendable (String?) -> Void) {
        state.queue.async { reply(state.setTarget(rpm, lease: leaseSeconds)) }
    }

    func setAuto(reply: @escaping @Sendable (String?) -> Void) {
        state.queue.async { reply(state.setAuto("requested by app")) }
    }

    func status(reply: @escaping @Sendable (String) -> Void) {
        state.queue.async { reply(state.status) }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private var connections = 0   // only touched on state.queue

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Only Thermal.app signed by our team may connect; others are rejected by the system.
        c.setCodeSigningRequirement(FanHelperInfo.clientRequirement)
        c.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        c.exportedObject = Service()
        c.invalidationHandler = { [weak self] in
            state.queue.async {
                guard let self else { return }
                self.connections -= 1
                // App quit or crashed: don't wait for the lease.
                if self.connections <= 0, state.isManual { state.setAuto("app disconnected") }
            }
        }
        state.queue.async { self.connections += 1 }
        c.resume()
        return true
    }
}

// MARK: - Sleep, signals, lease timer

private var rootPort: io_connect_t = 0
private let kMessageCanSystemSleep: UInt32 = 0xe000_0270
private let kMessageSystemWillSleep: UInt32 = 0xe000_0280

private func powerCallback(_ refcon: UnsafeMutableRawPointer?, _ service: io_service_t,
                           _ messageType: UInt32, _ messageArgument: UnsafeMutableRawPointer?) {
    switch messageType {
    case kMessageCanSystemSleep:
        IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
    case kMessageSystemWillSleep:
        state.queue.sync { _ = state.setAuto("system sleep") }
        IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
    default:
        break
    }
}

var notifyPort: IONotificationPortRef?
var notifier: io_object_t = 0
rootPort = IORegisterForSystemPower(nil, &notifyPort, powerCallback, &notifier)
if rootPort != 0, let notifyPort {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
} else {
    log.error("IORegisterForSystemPower failed; sleep hand-back relies on the lease")
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: state.queue)
    src.setEventHandler {
        state.setAuto("signal \(sig)")
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

let timer = DispatchSource.makeTimerSource(queue: state.queue)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler { state.tick() }
timer.resume()

// Start from a known state (after a crash the fans could still be in manual mode).
state.queue.sync { _ = state.setAuto("helper start") }
log.notice("ThermalFanHelper \(FanHelperInfo.version, privacy: .public) started")

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: FanHelperInfo.machService)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
