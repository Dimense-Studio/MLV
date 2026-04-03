import Foundation
import ServiceManagement
import os

@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()
    private let logger = Logger(subsystem: "dimense.net.MLV", category: "LoginItem")
    
    private init() {}
    
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
