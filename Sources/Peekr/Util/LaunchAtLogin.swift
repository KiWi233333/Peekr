import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService for the "launch at login" toggle.
/// No-ops gracefully when run as a bare executable (no bundle).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Peekr: launch-at-login update failed: \(error.localizedDescription)")
        }
    }
}
