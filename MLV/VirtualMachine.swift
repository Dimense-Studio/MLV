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
    
    var isInstalled: Bool {
        get {
            guard let dir = vmDirectory else { return false }
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("installed.tag").path)
        }
        set {
            guard let dir = vmDirectory else { return }
            let tagURL = dir.appendingPathComponent("installed.tag")
            if newValue {
                try? "".write(to: tagURL, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: tagURL)
            }
        }
    }
    
    // Deployment Progress
    struct DeploymentLog: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
        let isError: Bool
    }
    
    struct Pod: Identifiable {
        let id = UUID()
        let name: String
        let status: String
        let cpu: String
        let ram: String
        let namespace: String
    }
    
    var deploymentLogs: [DeploymentLog] = []
    var deploymentProgress: Double = 0.0 // 0.0 to 1.0
    var needsUserInteraction: Bool = false
    var pods: [Pod] = []
    var downloadTask: Task<Void, Error>?
    var downloadPercent: Int = 0
    var downloadSpeedMBps: Double = 0
    var downloadETASeconds: Int = 0
    var pendingAutoStartAfterInstall: Bool = false
    var userInitiatedStop: Bool = false
    
    // Networking Info
    var ipAddress: String = "Detecting..."
    var gateway: String = "192.168.64.1"
    var dns: [String] = ["8.8.8.8", "1.1.1.1"]
    var connectionType: String = "NAT (Virtualization.framework)"
    var isConnected: Bool = false
    
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
    
    enum LinuxDistro: String, CaseIterable, Identifiable {
        case debian13 = "Debian 13 (Trixie)"
        case alpine = "Alpine Linux (Edge)"
        case ubuntu = "Ubuntu Server (24.04)"
        case minimal = "Minimal K3s OS"
        
        var id: String { self.rawValue }
        
        var icon: String {
            switch self {
            case .debian13: return "debian"
            case .alpine: return "mount"
            case .ubuntu: return "ubuntu"
            case .minimal: return "sparkles"
            }
        }
        
        var mirrorURL: URL? {
            switch self {
            case .debian13: return URL(string: "https://cdimage.debian.org/cdimage/daily-builds/daily/arch-latest/arm64/iso-cd/debian-testing-arm64-netinst.iso")
            case .alpine: return URL(string: "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-virt-3.20.0-aarch64.iso")
            case .ubuntu: return URL(string: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.4-live-server-arm64.iso")
            case .minimal: return URL(string: "https://github.com/rancher/k3os/releases/download/v0.11.1/k3os-arm64.iso")
            }
        }

        var shortLabel: String {
            switch self {
            case .debian13: return "Debian"
            case .alpine: return "Alpine"
            case .ubuntu: return "Ubuntu"
            case .minimal: return "Minimal"
            }
        }
    }
    
    var selectedDistro: LinuxDistro = .debian13
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
