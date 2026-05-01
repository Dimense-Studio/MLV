import Foundation
import os

struct VMMetadata: Codable {
    let id: UUID
    let name: String
    let cpuCount: Int
    let memorySizeMB: Int
    let systemDiskSizeGB: Int
    let dataDiskSizeGB: Int
    let systemDiskProfile: String?
    let dataDiskProfile: String?
    let selectedDistro: String
    let isMaster: Bool
    let stage: String
    let isInstalled: Bool
    let networkMode: String?
    let bridgeInterfaceName: String?
    let secondaryNetworkEnabled: Bool?
    let secondaryNetworkMode: String?
    let secondaryBridgeInterfaceName: String?
    let clusterRole: String?
    let wgControlPrivateKeyBase64: String?
    let wgControlPublicKeyBase64: String?
    let wgControlAddressCIDR: String?
    let wgControlListenPort: Int?
    let wgControlHostForwardPort: Int?
    let wgDataPrivateKeyBase64: String?
    let wgDataPublicKeyBase64: String?
    let wgDataAddressCIDR: String?
    let wgDataListenPort: Int?
    let wgDataHostForwardPort: Int?
    let autoStartOnLaunch: Bool?
    let terminalConsoleHostPort: Int?
    let monitoredProcessPID: Int?
    let monitoredProcessName: String?
    let hostServicePID: Int?
    let containerImageReference: String?
    let containerMounts: [VirtualMachine.ContainerMount]?
    let containerPorts: [VirtualMachine.ContainerPort]?
    let isContainerWorkload: Bool?
    let talosSetupCompleted: Bool?
    let clusterCoreDeployed: Bool?
    let clusterCoreDashboardPassword: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, cpuCount, memorySizeMB, memorySizeGB, systemDiskSizeGB, dataDiskSizeGB
        case systemDiskProfile, dataDiskProfile, selectedDistro, isMaster, stage, isInstalled
        case networkMode, bridgeInterfaceName, secondaryNetworkEnabled, secondaryNetworkMode
        case secondaryBridgeInterfaceName, clusterRole, wgControlPrivateKeyBase64, wgControlPublicKeyBase64
        case wgControlAddressCIDR, wgControlListenPort, wgControlHostForwardPort, wgDataPrivateKeyBase64
        case wgDataPublicKeyBase64, wgDataAddressCIDR, wgDataListenPort, wgDataHostForwardPort
        case autoStartOnLaunch, terminalConsoleHostPort, monitoredProcessPID, monitoredProcessName, hostServicePID
        case containerImageReference, containerMounts, containerPorts, isContainerWorkload
        case talosSetupCompleted, clusterCoreDeployed, clusterCoreDashboardPassword
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        
        if let mb = try container.decodeIfPresent(Int.self, forKey: .memorySizeMB) {
            memorySizeMB = mb
        } else if let gb = try container.decodeIfPresent(Int.self, forKey: .memorySizeGB) {
            memorySizeMB = gb * 1024
        } else {
            memorySizeMB = 16384
        }
        
        systemDiskSizeGB = try container.decode(Int.self, forKey: .systemDiskSizeGB)
        dataDiskSizeGB = try container.decode(Int.self, forKey: .dataDiskSizeGB)
        systemDiskProfile = try container.decodeIfPresent(String.self, forKey: .systemDiskProfile)
        dataDiskProfile = try container.decodeIfPresent(String.self, forKey: .dataDiskProfile)
        selectedDistro = try container.decode(String.self, forKey: .selectedDistro)
        isMaster = try container.decode(Bool.self, forKey: .isMaster)
        stage = try container.decode(String.self, forKey: .stage)
        isInstalled = try container.decode(Bool.self, forKey: .isInstalled)
        networkMode = try container.decodeIfPresent(String.self, forKey: .networkMode)
        bridgeInterfaceName = try container.decodeIfPresent(String.self, forKey: .bridgeInterfaceName)
        secondaryNetworkEnabled = try container.decodeIfPresent(Bool.self, forKey: .secondaryNetworkEnabled)
        secondaryNetworkMode = try container.decodeIfPresent(String.self, forKey: .secondaryNetworkMode)
        secondaryBridgeInterfaceName = try container.decodeIfPresent(String.self, forKey: .secondaryBridgeInterfaceName)
        clusterRole = try container.decodeIfPresent(String.self, forKey: .clusterRole)
        wgControlPrivateKeyBase64 = try container.decodeIfPresent(String.self, forKey: .wgControlPrivateKeyBase64)
        wgControlPublicKeyBase64 = try container.decodeIfPresent(String.self, forKey: .wgControlPublicKeyBase64)
        wgControlAddressCIDR = try container.decodeIfPresent(String.self, forKey: .wgControlAddressCIDR)
        wgControlListenPort = try container.decodeIfPresent(Int.self, forKey: .wgControlListenPort)
        wgControlHostForwardPort = try container.decodeIfPresent(Int.self, forKey: .wgControlHostForwardPort)
        wgDataPrivateKeyBase64 = try container.decodeIfPresent(String.self, forKey: .wgDataPrivateKeyBase64)
        wgDataPublicKeyBase64 = try container.decodeIfPresent(String.self, forKey: .wgDataPublicKeyBase64)
        wgDataAddressCIDR = try container.decodeIfPresent(String.self, forKey: .wgDataAddressCIDR)
        wgDataListenPort = try container.decodeIfPresent(Int.self, forKey: .wgDataListenPort)
        wgDataHostForwardPort = try container.decodeIfPresent(Int.self, forKey: .wgDataHostForwardPort)
        autoStartOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .autoStartOnLaunch)
        terminalConsoleHostPort = try container.decodeIfPresent(Int.self, forKey: .terminalConsoleHostPort)
        monitoredProcessPID = try container.decodeIfPresent(Int.self, forKey: .monitoredProcessPID)
        monitoredProcessName = try container.decodeIfPresent(String.self, forKey: .monitoredProcessName)
        hostServicePID = try container.decodeIfPresent(Int.self, forKey: .hostServicePID)
        containerImageReference = try container.decodeIfPresent(String.self, forKey: .containerImageReference)
        containerMounts = try container.decodeIfPresent([VirtualMachine.ContainerMount].self, forKey: .containerMounts)
        containerPorts = try container.decodeIfPresent([VirtualMachine.ContainerPort].self, forKey: .containerPorts)
        isContainerWorkload = try container.decodeIfPresent(Bool.self, forKey: .isContainerWorkload)
        talosSetupCompleted = try container.decodeIfPresent(Bool.self, forKey: .talosSetupCompleted)
        clusterCoreDeployed = try container.decodeIfPresent(Bool.self, forKey: .clusterCoreDeployed)
        clusterCoreDashboardPassword = try container.decodeIfPresent(String.self, forKey: .clusterCoreDashboardPassword)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(cpuCount, forKey: .cpuCount)
        try container.encode(memorySizeMB, forKey: .memorySizeMB)
        try container.encode(systemDiskSizeGB, forKey: .systemDiskSizeGB)
        try container.encode(dataDiskSizeGB, forKey: .dataDiskSizeGB)
        try container.encodeIfPresent(systemDiskProfile, forKey: .systemDiskProfile)
        try container.encodeIfPresent(dataDiskProfile, forKey: .dataDiskProfile)
        try container.encode(selectedDistro, forKey: .selectedDistro)
        try container.encode(isMaster, forKey: .isMaster)
        try container.encode(stage, forKey: .stage)
        try container.encode(isInstalled, forKey: .isInstalled)
        try container.encodeIfPresent(networkMode, forKey: .networkMode)
        try container.encodeIfPresent(bridgeInterfaceName, forKey: .bridgeInterfaceName)
        try container.encodeIfPresent(secondaryNetworkEnabled, forKey: .secondaryNetworkEnabled)
        try container.encodeIfPresent(secondaryNetworkMode, forKey: .secondaryNetworkMode)
        try container.encodeIfPresent(secondaryBridgeInterfaceName, forKey: .secondaryBridgeInterfaceName)
        try container.encodeIfPresent(clusterRole, forKey: .clusterRole)
        try container.encodeIfPresent(wgControlPrivateKeyBase64, forKey: .wgControlPrivateKeyBase64)
        try container.encodeIfPresent(wgControlPublicKeyBase64, forKey: .wgControlPublicKeyBase64)
        try container.encodeIfPresent(wgControlAddressCIDR, forKey: .wgControlAddressCIDR)
        try container.encodeIfPresent(wgControlListenPort, forKey: .wgControlListenPort)
        try container.encodeIfPresent(wgControlHostForwardPort, forKey: .wgControlHostForwardPort)
        try container.encodeIfPresent(wgDataPrivateKeyBase64, forKey: .wgDataPrivateKeyBase64)
        try container.encodeIfPresent(wgDataPublicKeyBase64, forKey: .wgDataPublicKeyBase64)
        try container.encodeIfPresent(wgDataAddressCIDR, forKey: .wgDataAddressCIDR)
        try container.encodeIfPresent(wgDataListenPort, forKey: .wgDataListenPort)
        try container.encodeIfPresent(wgDataHostForwardPort, forKey: .wgDataHostForwardPort)
        try container.encodeIfPresent(autoStartOnLaunch, forKey: .autoStartOnLaunch)
        try container.encodeIfPresent(terminalConsoleHostPort, forKey: .terminalConsoleHostPort)
        try container.encodeIfPresent(monitoredProcessPID, forKey: .monitoredProcessPID)
        try container.encodeIfPresent(monitoredProcessName, forKey: .monitoredProcessName)
        try container.encodeIfPresent(hostServicePID, forKey: .hostServicePID)
        try container.encodeIfPresent(containerImageReference, forKey: .containerImageReference)
        try container.encodeIfPresent(containerMounts, forKey: .containerMounts)
        try container.encodeIfPresent(containerPorts, forKey: .containerPorts)
        try container.encodeIfPresent(isContainerWorkload, forKey: .isContainerWorkload)
        try container.encodeIfPresent(talosSetupCompleted, forKey: .talosSetupCompleted)
        try container.encodeIfPresent(clusterCoreDeployed, forKey: .clusterCoreDeployed)
        try container.encodeIfPresent(clusterCoreDashboardPassword, forKey: .clusterCoreDashboardPassword)
    }
    
    init(
        id: UUID,
        name: String,
        cpuCount: Int,
        memorySizeMB: Int,
        systemDiskSizeGB: Int,
        dataDiskSizeGB: Int,
        systemDiskProfile: String?,
        dataDiskProfile: String?,
        selectedDistro: String,
        isMaster: Bool,
        stage: String,
        isInstalled: Bool,
        networkMode: String?,
        bridgeInterfaceName: String?,
        secondaryNetworkEnabled: Bool?,
        secondaryNetworkMode: String?,
        secondaryBridgeInterfaceName: String?,
        clusterRole: String?,
        wgControlPrivateKeyBase64: String?,
        wgControlPublicKeyBase64: String?,
        wgControlAddressCIDR: String?,
        wgControlListenPort: Int?,
        wgControlHostForwardPort: Int?,
        wgDataPrivateKeyBase64: String?,
        wgDataPublicKeyBase64: String?,
        wgDataAddressCIDR: String?,
        wgDataListenPort: Int?,
        wgDataHostForwardPort: Int?,
        autoStartOnLaunch: Bool?,
        terminalConsoleHostPort: Int?,
        monitoredProcessPID: Int?,
        monitoredProcessName: String?,
        hostServicePID: Int?,
        containerImageReference: String?,
        containerMounts: [VirtualMachine.ContainerMount]?,
        containerPorts: [VirtualMachine.ContainerPort]?,
        isContainerWorkload: Bool?,
        talosSetupCompleted: Bool? = nil,
        clusterCoreDeployed: Bool? = nil,
        clusterCoreDashboardPassword: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cpuCount = cpuCount
        self.memorySizeMB = memorySizeMB
        self.systemDiskSizeGB = systemDiskSizeGB
        self.dataDiskSizeGB = dataDiskSizeGB
        self.systemDiskProfile = systemDiskProfile
        self.dataDiskProfile = dataDiskProfile
        self.selectedDistro = selectedDistro
        self.isMaster = isMaster
        self.stage = stage
        self.isInstalled = isInstalled
        self.networkMode = networkMode
        self.bridgeInterfaceName = bridgeInterfaceName
        self.secondaryNetworkEnabled = secondaryNetworkEnabled
        self.secondaryNetworkMode = secondaryNetworkMode
        self.secondaryBridgeInterfaceName = secondaryBridgeInterfaceName
        self.clusterRole = clusterRole
        self.wgControlPrivateKeyBase64 = wgControlPrivateKeyBase64
        self.wgControlPublicKeyBase64 = wgControlPublicKeyBase64
        self.wgControlAddressCIDR = wgControlAddressCIDR
        self.wgControlListenPort = wgControlListenPort
        self.wgControlHostForwardPort = wgControlHostForwardPort
        self.wgDataPrivateKeyBase64 = wgDataPrivateKeyBase64
        self.wgDataPublicKeyBase64 = wgDataPublicKeyBase64
        self.wgDataAddressCIDR = wgDataAddressCIDR
        self.wgDataListenPort = wgDataListenPort
        self.wgDataHostForwardPort = wgDataHostForwardPort
        self.autoStartOnLaunch = autoStartOnLaunch
        self.terminalConsoleHostPort = terminalConsoleHostPort
        self.monitoredProcessPID = monitoredProcessPID
        self.monitoredProcessName = monitoredProcessName
        self.hostServicePID = hostServicePID
        self.containerImageReference = containerImageReference
        self.containerMounts = containerMounts
        self.containerPorts = containerPorts
        self.isContainerWorkload = isContainerWorkload
        self.talosSetupCompleted = talosSetupCompleted
        self.clusterCoreDeployed = clusterCoreDeployed
        self.clusterCoreDashboardPassword = clusterCoreDashboardPassword
    }
}

class VMStatePersistence {
    static let shared = VMStatePersistence()
    private let logger = Logger(subsystem: "dimense.net.MLV", category: "VMPersistence")
    
    private let vmsMetadataFile = "vms_metadata.json"
    
    private var metadataURL: URL {
        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return containerDir.appendingPathComponent(vmsMetadataFile)
    }
    
    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "mlv.persistence.save", qos: .utility)
    private var lastSavedSignature: Int?
    private let signatureLock = NSLock()
    
    func saveVMs(_ vms: [VirtualMachine]) {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [vms] in
            let metadata = vms.map { vm in
                VMMetadata(
                    id: vm.id,
                    name: vm.name,
                    cpuCount: vm.cpuCount,
                    memorySizeMB: vm.memorySizeMB,
                    systemDiskSizeGB: vm.systemDiskSizeGB,
                    dataDiskSizeGB: vm.dataDiskSizeGB,
                    systemDiskProfile: vm.systemDiskProfile.rawValue,
                    dataDiskProfile: vm.dataDiskProfile.rawValue,
                    selectedDistro: vm.selectedDistro.rawValue,
                    isMaster: vm.isMaster,
                    stage: vm.stage.rawValue,
                    isInstalled: vm.isInstalled,
                    networkMode: vm.networkMode.rawValue,
                    bridgeInterfaceName: vm.bridgeInterfaceName,
                    secondaryNetworkEnabled: vm.secondaryNetworkEnabled,
                    secondaryNetworkMode: vm.secondaryNetworkMode.rawValue,
                    secondaryBridgeInterfaceName: vm.secondaryBridgeInterfaceName,
                    clusterRole: vm.clusterRole.rawValue,
                    wgControlPrivateKeyBase64: vm.wgControlPrivateKeyBase64,
                    wgControlPublicKeyBase64: vm.wgControlPublicKeyBase64,
                    wgControlAddressCIDR: vm.wgControlAddressCIDR,
                    wgControlListenPort: vm.wgControlListenPort,
                    wgControlHostForwardPort: vm.wgControlHostForwardPort,
                    wgDataPrivateKeyBase64: vm.wgDataPrivateKeyBase64,
                    wgDataPublicKeyBase64: vm.wgDataPublicKeyBase64,
                    wgDataAddressCIDR: vm.wgDataAddressCIDR,
                    wgDataListenPort: vm.wgDataListenPort,
                    wgDataHostForwardPort: vm.wgDataHostForwardPort,
                    autoStartOnLaunch: vm.autoStartOnLaunch,
                    terminalConsoleHostPort: vm.terminalConsoleHostPort,
                    monitoredProcessPID: vm.monitoredProcessPID,
                    monitoredProcessName: vm.monitoredProcessName,
                    hostServicePID: vm.hostServicePID,
                    containerImageReference: vm.containerImageReference,
                    containerMounts: vm.containerMounts,
                    containerPorts: vm.containerPorts,
                    isContainerWorkload: vm.isContainerWorkload,
                    talosSetupCompleted: vm.talosSetupCompleted,
                    clusterCoreDeployed: vm.clusterCoreDeployed,
                    clusterCoreDashboardPassword: vm.clusterCoreDashboardPassword.isEmpty ? nil : vm.clusterCoreDashboardPassword
                )
            }
            do {
                let parentDir = self.metadataURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                let data = try JSONEncoder().encode(metadata)
                let signature = data.hashValue
                self.signatureLock.lock()
                let isDuplicate = self.lastSavedSignature == signature
                self.signatureLock.unlock()
                if isDuplicate {
                    return
                }
                try data.write(to: self.metadataURL, options: .atomic)
                self.signatureLock.lock()
                self.lastSavedSignature = signature
                self.signatureLock.unlock()
                self.logger.debug("Saved \(metadata.count, privacy: .public) VMs to disk.")
            } catch {
                self.logger.error("Error saving metadata: \(error.localizedDescription, privacy: .public)")
            }
        }
        saveWorkItem = workItem
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    func loadVMs() -> [VMMetadata] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: metadataURL, options: .mappedIfSafe)
            let metadata = try JSONDecoder().decode([VMMetadata].self, from: data)
            signatureLock.lock()
            lastSavedSignature = data.hashValue
            signatureLock.unlock()
            logger.debug("Loaded \(metadata.count, privacy: .public) VMs from disk.")
            return metadata
        } catch {
            logger.error("Error loading metadata: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
