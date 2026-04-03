import Foundation

@MainActor
final class BackgroundExecutionManager {
    static let shared = BackgroundExecutionManager()
    
    private var activity: NSObjectProtocol?
    
    private init() {}
    
    func setActive(_ active: Bool) {
        if active {
            if activity != nil { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "MLV is running virtual machines"
            )
        } else {
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        }
    }
}

