import Foundation
import ServiceManagement

enum LoginItem {
    /// Only an installed .app bundle can register itself (not `swift run`).
    static var isAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static var isEnabled: Bool { isAvailable && SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Strays: login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }

    /// Opens at login by default after install; the footer toggle turns it off.
    static func configureOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard isAvailable, !UserDefaults.standard.bool(forKey: key) else { return }
        set(true)
        UserDefaults.standard.set(true, forKey: key)
    }
}
