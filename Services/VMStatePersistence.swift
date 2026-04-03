import Foundation
import os

struct VMMetadata: Codable {
    let id: UUID
    let name: String
    let cpuCount: Int
    let memorySizeGB: Int
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
    
    init(
        id: UUID,
        name: String,
        cpuCount: Int,
        memorySizeGB: Int,
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
        monitoredProcessName: String?
    ) {
        self.id = id
        self.name = name
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
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
                    memorySizeGB: vm.memorySizeGB,
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
                    monitoredProcessName: vm.monitoredProcessName
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
