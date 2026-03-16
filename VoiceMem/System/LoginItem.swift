import ServiceManagement
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "LoginItem")

/// Manages Launch at Login via SMAppService (macOS 13+).
enum LoginItemManager {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("[LoginItem] Registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("[LoginItem] Unregistered from launch at login")
            }
        } catch {
            logger.error("[LoginItem] Failed to \(enabled ? "register" : "unregister"): \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
