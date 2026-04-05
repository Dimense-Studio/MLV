import Foundation
import Virtualization
import SwiftUI
import os

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

enum VMStage: String, Codable, Equatable {
    case new
    case downloadingISO
    case stagingISO
    case configuring
    case installing
    case installed
    case rebooting
    case running
    case stopped
    case crashed
    case error
}

enum VMNetworkMode: String, Codable, CaseIterable {
    case nat = "NAT"
    case bridge = "Bridge"
}

enum VMClusterRole: String, Codable, CaseIterable {
    case master = "Master"
    case node = "Node"
}

@Observable
class VirtualMachine: Identifiable {
    private static let logger = Logger(subsystem: "dimense.net.MLV", category: "VirtualMachine")
    enum DiskProfile: String, Codable, CaseIterable, Identifiable {
        case balanced = "Balanced"
        case durable = "Durable"
        case maxPerformance = "Max Performance"
        
        var id: String { rawValue }
        
        @available(macOS 13.0, *)
        var diskImageCachingMode: VZDiskImageCachingMode {
            switch self {
            case .balanced: return .automatic
            case .durable: return .uncached
            case .maxPerformance: return .cached
            }
        }
        
        @available(macOS 13.0, *)
        var diskImageSynchronizationMode: VZDiskImageSynchronizationMode {
            switch self {
            case .balanced: return .fsync
            case .durable: return .full
            case .maxPerformance: return .none
            }
        }
    }
    
    let id: UUID
    let name: String
    var isoURL: URL
    var state: VMState = .stopped
    var vzVirtualMachine: VZVirtualMachine?
    var vzDelegate: VMRuntimeDelegate?
    var serialWritePipe: Pipe?
    var consoleOutput: String = ""
    var lastConsoleActivity: Date = Date()
    var lastHealthyPoll: Date? = nil
    /// True when this VM represents a container workload (Apple container runtime).
    var isContainerWorkload: Bool = false {
        didSet { persist() }
    }
    
    var stage: VMStage = .new {
        didSet {
            persist()
        }
    }
    
    var networkMode: VMNetworkMode = .nat {
        didSet { persist() }
    }
    
    var bridgeInterfaceName: String? = nil {
        didSet { persist() }
    }

    var secondaryNetworkEnabled: Bool = false {
        didSet { persist() }
    }

    var secondaryNetworkMode: VMNetworkMode = .nat {
        didSet { persist() }
    }

    var secondaryBridgeInterfaceName: String? = nil {
        didSet { persist() }
    }

    var clusterRole: VMClusterRole = .node {
        didSet { persist() }
    }

    var autoStartOnLaunch: Bool = false {
        didSet { persist() }
    }
    
    var wgControlPrivateKeyBase64: String? = nil {
        didSet { persist() }
    }
    
    var wgControlPublicKeyBase64: String? = nil {
        didSet { persist() }
    }
    
    var wgControlAddressCIDR: String? = nil {
        didSet { persist() }
    }
    
    var wgControlListenPort: Int = 51820 {
        didSet { persist() }
    }
    
    var wgControlHostForwardPort: Int = 0 {
        didSet { persist() }
    }
    
    var wgDataPrivateKeyBase64: String? = nil {
        didSet { persist() }
    }
    
    var wgDataPublicKeyBase64: String? = nil {
        didSet { persist() }
    }
    
    var wgDataAddressCIDR: String? = nil {
        didSet { persist() }
    }
    
    var wgDataListenPort: Int = 51821 {
        didSet { persist() }
    }
    
    var wgDataHostForwardPort: Int = 0 {
        didSet { persist() }
    }

    var terminalConsoleHostPort: Int = 0 {
        didSet { persist() }
    }
    
    var isInstalled: Bool {
        get {
            guard let dir = vmDirectory else { return false }
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("installed.tag").path)
        }
        set {
            guard let dir = vmDirectory else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tagURL = dir.appendingPathComponent("installed.tag")
            if newValue {
                try? "installed\n".write(to: tagURL, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: tagURL)
            }
            persist()
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

    struct Container: Identifiable {
        let id = UUID()
        let name: String
        let image: String
        let status: String
        let runtime: String
    }

    struct ContainerMount: Codable, Identifiable, Equatable {
        let id: UUID
        var hostPath: String
        var containerPath: String
        var isReadOnly: Bool
        
        init(id: UUID = UUID(), hostPath: String, containerPath: String, isReadOnly: Bool = false) {
            self.id = id
            self.hostPath = hostPath
            self.containerPath = containerPath
            self.isReadOnly = isReadOnly
        }
    }

    struct ContainerPort: Codable, Identifiable, Equatable {
        let id: UUID
        var hostPort: Int
        var containerPort: Int
        var protocolName: String
        
        init(id: UUID = UUID(), hostPort: Int, containerPort: Int, protocolName: String = "tcp") {
            self.id = id
            self.hostPort = hostPort
            self.containerPort = containerPort
            self.protocolName = protocolName
        }
    }
    
    var deploymentLogs: [DeploymentLog] = []
    var deploymentProgress: Double = 0.0 // 0.0 to 1.0
    var needsUserInteraction: Bool = false
    var pods: [Pod] = []
    var containers: [Container] = []
    var containerMounts: [ContainerMount] = [] {
        didSet { persist() }
    }
    var containerPorts: [ContainerPort] = [] {
        didSet { persist() }
    }
    var downloadTask: Task<Void, Error>?
    var downloadPercent: Int = 0
    var downloadSpeedMBps: Double = 0
    var downloadETASeconds: Int = 0
    var pendingAutoStartAfterInstall: Bool = false
    var userInitiatedStop: Bool = false
    var guestCPUUsagePercent: Int = 0
    var guestMemoryUsagePercent: Int = 0
    var guestDiskUsagePercent: Int = 0
    // Runtime telemetry target. This is updated by polling logic and should not trigger persistence on each sample.
    var monitoredProcessPID: Int = 1
    var monitoredProcessName: String = ""
    var hasGuestUsageSample: Bool = false
    var lastGuestCPUTotalTicks: UInt64? = nil
    var lastGuestCPUIdleTicks: UInt64? = nil
    var lastMonitoredProcessTicks: UInt64? = nil
    var hostServicePID: Int? = nil {
        didSet { persist() }
    }
    var containerImageReference: String = "" {
        didSet { persist() }
    }
    
    // Networking Info
    var ipAddress: String = "Detecting..."
    var gateway: String = "192.168.64.1"
    var dns: [String] = ["8.8.8.8", "1.1.1.1"]
    var connectionType: String = "NAT (Virtualization.framework)"
    var isConnected: Bool = false
    
    func addLog(_ message: String, isError: Bool = false) {
        let log = DeploymentLog(message: message, isError: isError)
        deploymentLogs.append(log)
        if isError {
            Self.logger.error("[\(self.name, privacy: .public)] \(message, privacy: .public)")
        } else {
            Self.logger.info("[\(self.name, privacy: .public)] \(message, privacy: .public)")
        }
    }
    
    // Configurable Hardware
    var cpuCount: Int = 4
    var memorySizeMB: Int = 4096
    var systemDiskSizeGB: Int = 64
    var dataDiskSizeGB: Int = 100
    var isMaster: Bool = false
    
    var systemDiskProfile: DiskProfile = .balanced {
        didSet { persist() }
    }
    
    var dataDiskProfile: DiskProfile = .durable {
        didSet { persist() }
    }
    
    enum LinuxDistro: String, CaseIterable, Identifiable, Codable {
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
    
    var vmDirectory: URL? {
        return VMStorageManager.shared.getVMRootDirectory(for: id)
    }

    private var stageTagURL: URL? {
        vmDirectory?.appendingPathComponent("stage.tag")
    }

    func persist() {
        // Only persist if we are already in the VMManager's list
        // and avoid infinite loops by checking if the metadata is actually different
        Task { @MainActor in
            VMStatePersistence.shared.saveVMs(VMManager.shared.virtualMachines)
            
            // Also persist stage to stage.tag for redundancy/backwards compatibility
            if let url = stageTagURL {
                try? stage.rawValue.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    
    func resetRuntimeState() {
        vzVirtualMachine = nil
        vzDelegate = nil
        serialWritePipe = nil
        consoleOutput = ""
        downloadTask?.cancel()
        downloadTask = nil
        lastHealthyPoll = nil
        isConnected = false
        ipAddress = "Detecting..."
        guestCPUUsagePercent = 0
        guestMemoryUsagePercent = 0
        guestDiskUsagePercent = 0
        hasGuestUsageSample = false
        lastGuestCPUTotalTicks = nil
        lastGuestCPUIdleTicks = nil
        lastMonitoredProcessTicks = nil
    }
    
    init(id: UUID = UUID(), name: String, isoURL: URL, cpus: Int = 4, ramMB: Int = 4096, sysDiskGB: Int = 64, dataDiskGB: Int = 100) {
        self.id = id
        self.name = name
        self.isoURL = isoURL
        self.cpuCount = cpus
        self.memorySizeMB = ramMB
        self.systemDiskSizeGB = sysDiskGB
        self.dataDiskSizeGB = dataDiskGB
        
        // Try to load stage from tag if it exists
        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let vmDir = containerDir.appendingPathComponent("mlv-\(id.uuidString)", isDirectory: true)
        let tagURL = vmDir.appendingPathComponent("stage.tag")
        if let raw = try? String(contentsOf: tagURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let loaded = VMStage(rawValue: raw) {
            self.stage = loaded
        }
    }
}
