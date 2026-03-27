import Foundation

struct VMMetadata: Codable {
    let id: UUID
    let name: String
    let cpuCount: Int
    let memorySizeGB: Int
    let systemDiskSizeGB: Int
    let dataDiskSizeGB: Int
    let selectedDistro: String
    let isMaster: Bool
    let stage: String
    let isInstalled: Bool
    let networkMode: String?
    let bridgeInterfaceName: String?
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
    
    init(
        id: UUID,
        name: String,
        cpuCount: Int,
        memorySizeGB: Int,
        systemDiskSizeGB: Int,
        dataDiskSizeGB: Int,
        selectedDistro: String,
        isMaster: Bool,
        stage: String,
        isInstalled: Bool,
        networkMode: String?,
        bridgeInterfaceName: String?,
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
        terminalConsoleHostPort: Int?
    ) {
        self.id = id
        self.name = name
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
        self.systemDiskSizeGB = systemDiskSizeGB
        self.dataDiskSizeGB = dataDiskSizeGB
        self.selectedDistro = selectedDistro
        self.isMaster = isMaster
        self.stage = stage
        self.isInstalled = isInstalled
        self.networkMode = networkMode
        self.bridgeInterfaceName = bridgeInterfaceName
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
    }
}

class VMStatePersistence {
    static let shared = VMStatePersistence()
    
    private let vmsMetadataFile = "vms_metadata.json"
    
    private var metadataURL: URL {
        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return containerDir.appendingPathComponent(vmsMetadataFile)
    }
    
    func saveVMs(_ vms: [VirtualMachine]) {
        let metadata = vms.map { vm in
            VMMetadata(
                id: vm.id,
                name: vm.name,
                cpuCount: vm.cpuCount,
                memorySizeGB: vm.memorySizeGB,
                systemDiskSizeGB: vm.systemDiskSizeGB,
                dataDiskSizeGB: vm.dataDiskSizeGB,
                selectedDistro: vm.selectedDistro.rawValue,
                isMaster: vm.isMaster,
                stage: vm.stage.rawValue,
                isInstalled: vm.isInstalled,
                networkMode: vm.networkMode.rawValue,
                bridgeInterfaceName: vm.bridgeInterfaceName,
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
                terminalConsoleHostPort: vm.terminalConsoleHostPort
            )
        }
        
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
            print("[VMPersistence] Saved \(metadata.count) VMs to disk.")
        } catch {
            print("[VMPersistence] Error saving metadata: \(error.localizedDescription)")
        }
    }
    
    func loadVMs() -> [VMMetadata] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: metadataURL)
            let metadata = try JSONDecoder().decode([VMMetadata].self, from: data)
            print("[VMPersistence] Loaded \(metadata.count) VMs from disk.")
            return metadata
        } catch {
            print("[VMPersistence] Error loading metadata: \(error.localizedDescription)")
            return []
        }
    }
}
