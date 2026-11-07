import FanHelperProtocol
import Foundation
import Observation
import ServiceManagement

/// Registers the privileged fan helper (SMAppService) and talks to it over XPC.
@MainActor @Observable
final class FanHelperClient {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?
    /// Version reported by the running helper (nil until the first connection).
    private(set) var helperVersion: String?
    /// The running helper is older than this app and can't replace itself (pre-0.4.0 helper):
    /// it only goes away on restart or `sudo launchctl kickstart -k system/<label>`.
    private(set) var updatePending = false
    @ObservationIgnored private var versionChecked = false

    @ObservationIgnored private let service = SMAppService.daemon(plistName: FanHelperInfo.plistName)
    @ObservationIgnored private var connection: NSXPCConnection?

    init() { refresh() }

    var isEnabled: Bool { status == .enabled }

    var statusText: String {
        switch status {
        case .enabled: "Enabled"
        case .requiresApproval: "Waiting for approval in System Settings › Login Items"
        case .notRegistered: "Not set up"
        case .notFound: "Helper missing from the app bundle"
        @unknown default: "Unknown"
        }
    }

    func refresh() { status = service.status }

    /// Registers the daemon. The first time, macOS asks for approval in Login Items.
    func enable() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func disable() async {
        _ = await setAuto()
        connection?.invalidate()
        connection = nil
        do { try await service.unregister() } catch { lastError = error.localizedDescription }
        refresh()
    }

    // MARK: XPC

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: FanHelperInfo.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        // Only talk to a helper signed by our team.
        c.setCodeSigningRequirement(FanHelperInfo.helperRequirement)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.versionChecked = false   // a new helper process may answer next time
            }
        }
        c.resume()
        connection = c
        return c
    }

    private func call(_ body: @escaping (FanHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        guard isEnabled else { return "Fan control is not enabled" }
        await ensureCurrentHelper()
        return await rawCall(body)
    }

    private func rawCall(_ body: @escaping (FanHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        let c = makeConnection()
        let result: String? = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                once.resume(error.localizedDescription)
            }
            guard let helper = proxy as? FanHelperProtocol else {
                once.resume("Helper interface unavailable")
                return
            }
            body(helper) { once.resume($0) }
        }
        lastError = result
        return result
    }

    /// After a reinstall, launchd keeps the *old* helper process running. On the first call per
    /// connection, compare versions; a 0.4.0+ helper that differs is asked to exit, so the next
    /// connection starts the installed binary.
    private func ensureCurrentHelper() async {
        guard !versionChecked else { return }
        for attempt in 0..<2 {
            let v = await rawCall { helper, done in helper.version { done($0) } }
            // rawCall reports XPC errors through the same string; a version starts with a digit.
            guard let v, v.first?.isNumber == true else { return }   // retry on the next call
            helperVersion = v
            guard v != FanHelperInfo.version else {
                updatePending = false
                versionChecked = true
                return
            }
            let canExit = v.compare(FanHelperInfo.firstVersionWithExitForUpdate, options: .numeric) != .orderedAscending
            guard canExit, attempt == 0 else {
                updatePending = true    // legacy helper: keeps working, replaced on next restart
                versionChecked = true
                return
            }
            _ = await rawCall { helper, done in helper.exitForUpdate { done(nil) } }
            connection?.invalidate()
            connection = nil
            try? await Task.sleep(for: .milliseconds(800))
        }
    }

    func setTarget(_ rpm: Double, lease: Double) async -> String? {
        await call { $0.setTarget(rpm: rpm, leaseSeconds: lease, reply: $1) }
    }

    func setAuto() async -> String? {
        await call { $0.setAuto(reply: $1) }
    }
}

/// XPC may call either the error handler or the reply; resume the continuation exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private var cont: CheckedContinuation<String?, Never>?
    private let lock = NSLock()
    init(_ cont: CheckedContinuation<String?, Never>) { self.cont = cont }
    func resume(_ value: String?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
