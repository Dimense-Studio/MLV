import Foundation
import Virtualization
import SwiftUI

enum VMState: Equatable {
    case stopped
    case starting
    case running
    case paused
    case error(String)
    
    var isRunning: Bool {
        return self == .running
    }
}

@Observable
class VirtualMachine: Identifiable {
    let id = UUID()
    let name: String
    let isoURL: URL
    var state: VMState = .stopped
    var vzVirtualMachine: VZVirtualMachine?
    var serialWritePipe: Pipe?
    var consoleOutput: String = ""
    var isInstalled: Bool = false
    
    // Deployment Progress
    struct DeploymentLog: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
        let isError: Bool
    }
    var deploymentLogs: [DeploymentLog] = []
    var deploymentProgress: Double = 0.0 // 0.0 to 1.0
    var needsUserInteraction: Bool = false
    
    func addLog(_ message: String, isError: Bool = false) {
        let log = DeploymentLog(message: message, isError: isError)
        deploymentLogs.append(log)
        print("[\(name)] \(message)")
    }
    
    // Configurable Hardware
    var cpuCount: Int = 4
    var memorySizeGB: Int = 4
    var systemDiskSizeGB: Int = 64
    var dataDiskSizeGB: Int = 100
    var isMaster: Bool = false
    var networkInterfaceType: HostResources.NetworkInterface.InterfaceType = .ethernet
    var networkInterfaceBSDName: String = "en0"
    var networkSpeed: String = "10 Gbps"
    
    var vmDirectory: URL? {
        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return containerDir.appendingPathComponent("mlv-\(id.uuidString)", isDirectory: true)
    }
    
    init(name: String, isoURL: URL, cpus: Int = 4, ramGB: Int = 4, sysDiskGB: Int = 64, dataDiskGB: Int = 100) {
        self.name = name
        self.isoURL = isoURL
        self.cpuCount = cpus
        self.memorySizeGB = ramGB
        self.systemDiskSizeGB = sysDiskGB
        self.dataDiskSizeGB = dataDiskGB
    }
}
