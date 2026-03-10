import Foundation
import ServiceManagement

/// ログイン時の自動起動を管理（macOS 13+ SMAppService）
enum LoginItemManager {
    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    klog("LoginItem: registered")
                } else {
                    try SMAppService.mainApp.unregister()
                    klog("LoginItem: unregistered")
                }
            } catch {
                klog("LoginItem: error \(error.localizedDescription)")
            }
        }
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
}
