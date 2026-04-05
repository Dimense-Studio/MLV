import Foundation

@MainActor
@Observable
final class AppSettingsStore {
    enum WorkloadRuntime: String, CaseIterable {
        case virtualization = "virtualization"
        case appleContainer = "appleContainer"
        
        var isContainer: Bool {
            return self == .appleContainer
        }
    }

    static let shared = AppSettingsStore()
    
    private let keyLaunchAtLogin = "MLV_LaunchAtLogin"
    private let keyPreventSleep = "MLV_PreventSleepWhileVMRunning"
    private let keyAutoStartVMs = "MLV_AutoStartVMs"
    private let keyAutoUpdate = "MLV_AutoUpdateEnabled"
    private let keyWorkloadRuntime = "MLV_WorkloadRuntime"
    
    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: keyLaunchAtLogin)
            LoginItemManager.shared.setEnabled(launchAtLogin)
        }
    }
    
    var preventSleepWhileVMRunning: Bool {
        didSet {
            UserDefaults.standard.set(preventSleepWhileVMRunning, forKey: keyPreventSleep)
            VMManager.shared.refreshBackgroundExecution()
        }
    }
    
    var autoStartVMsOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoStartVMsOnLaunch, forKey: keyAutoStartVMs)
        }
    }

    var autoUpdateEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoUpdateEnabled, forKey: keyAutoUpdate)
            AppUpdateManager.shared.start()
        }
    }

    var workloadRuntime: WorkloadRuntime {
        didSet {
            UserDefaults.standard.set(workloadRuntime.rawValue, forKey: keyWorkloadRuntime)
            Task { @MainActor in
                await VMManager.shared.handleRuntimeModeChange()
            }
        }
    }
    
    private init() {
        self.launchAtLogin = UserDefaults.standard.bool(forKey: keyLaunchAtLogin)
        self.preventSleepWhileVMRunning = UserDefaults.standard.object(forKey: keyPreventSleep) as? Bool ?? true
        self.autoStartVMsOnLaunch = UserDefaults.standard.object(forKey: keyAutoStartVMs) as? Bool ?? true
        self.autoUpdateEnabled = UserDefaults.standard.object(forKey: keyAutoUpdate) as? Bool ?? true
        self.workloadRuntime = WorkloadRuntime(
            rawValue: UserDefaults.standard.string(forKey: keyWorkloadRuntime) ?? WorkloadRuntime.virtualization.rawValue
        ) ?? .virtualization
    }
}
