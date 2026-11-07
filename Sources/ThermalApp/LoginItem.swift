import Foundation
import Observation
import ServiceManagement

/// "Launch at login" for Thermal itself (SMAppService.mainApp). Without it, Cool charging is off
/// after a restart until Thermal is opened by hand.
@MainActor @Observable
final class LoginItem {
    private(set) var isEnabled = false
    private(set) var lastError: String?

    init() { refresh() }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if on, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
