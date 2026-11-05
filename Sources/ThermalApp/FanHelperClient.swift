import FanHelperProtocol
import Foundation
import Observation
import ServiceManagement

/// Registers the privileged fan helper (SMAppService) and talks to it over XPC.
@MainActor @Observable
final class FanHelperClient {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

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
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    private func call(_ body: @escaping (FanHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        guard isEnabled else { return "Fan control is not enabled" }
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
