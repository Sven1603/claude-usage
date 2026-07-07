import ServiceManagement

/// Register/unregister the app as a login item (macOS 13+ SMAppService).
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// A freshly-registered login item is often `.requiresApproval` (registered
    /// but pending the user's OK in System Settings) rather than `.enabled`.
    /// Both mean "the user asked for launch-at-login", so treat both as on.
    static var isEnabled: Bool {
        let s = status
        return s == .enabled || s == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LaunchAtLogin toggle failed: \(error)")
        }
        // If enabling didn't land cleanly on `.enabled` (pending approval, or
        // registration was blocked), send the user to Login Items to approve/add.
        if enabled && status != .enabled {
            openLoginItemsSettings()
        }
        return isEnabled
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
