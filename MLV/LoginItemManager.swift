import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()
    
    private init() {}
    
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[LoginItem] Failed to update login item: \(error.localizedDescription)")
        }
    }
    
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

