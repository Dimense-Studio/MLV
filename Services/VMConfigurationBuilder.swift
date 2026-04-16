import Foundation
import Virtualization
import os

class VMConfigurationBuilder {
    static let shared = VMConfigurationBuilder()
    private let logger = Logger(subsystem: "dimense.net.MLV", category: "VMConfigBuilder")
    private let sharedFolderMountTag = "mlvshare"
    
    func build(for vm: VirtualMachine) async throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        
        config.cpuCount = vm.cpuCount
        config.memorySize = UInt64(vm.memorySizeMB) * 1024 * 1024
        
        let vmDir = VMStorageManager.shared.getVMRootDirectory(for: vm.id)
        let systemDiskURL = vmDir.appendingPathComponent("system.raw")
        let dataDiskURL = vmDir.appendingPathComponent("data.raw")
        let isoURL = vmDir.appendingPathComponent("installer.iso")
        let efiStoreURL = vmDir.appendingPathComponent("efi-variable-store")
        
        _ = try VMStorageManager.shared.ensureVMDirectoryExists(for: vm.id)
        
        try VMStorageManager.shared.createSparseDisk(at: systemDiskURL, sizeGiB: vm.systemDiskSizeGB, preallocate: vm.systemDiskProfile == .durable)
        if vm.dataDiskSizeGB > 0 {
            try VMStorageManager.shared.createSparseDisk(at: dataDiskURL, sizeGiB: vm.dataDiskSizeGB, preallocate: vm.dataDiskProfile == .durable)
        }
        
        let efiStore: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: efiStoreURL.path) {
            efiStore = VZEFIVariableStore(url: efiStoreURL)
        } else {
            efiStore = try VZEFIVariableStore(creatingVariableStoreAt: efiStoreURL)
        }
        
        var storageDevices: [VZStorageDeviceConfiguration] = []
        
        let systemAttachment: VZDiskImageStorageDeviceAttachment
        if #available(macOS 13.0, *) {
            systemAttachment = try VZDiskImageStorageDeviceAttachment(url: systemDiskURL, readOnly: false, cachingMode: vm.systemDiskProfile.diskImageCachingMode, synchronizationMode: vm.systemDiskProfile.diskImageSynchronizationMode)
        } else {
            systemAttachment = try VZDiskImageStorageDeviceAttachment(url: systemDiskURL, readOnly: false)
        }
        storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: systemAttachment))
        
        if vm.dataDiskSizeGB > 0 {
            let dataAttachment: VZDiskImageStorageDeviceAttachment
            if #available(macOS 13.0, *) {
                dataAttachment = try VZDiskImageStorageDeviceAttachment(url: dataDiskURL, readOnly: false, cachingMode: vm.dataDiskProfile.diskImageCachingMode, synchronizationMode: vm.dataDiskProfile.diskImageSynchronizationMode)
            } else {
                dataAttachment = try VZDiskImageStorageDeviceAttachment(url: dataDiskURL, readOnly: false)
            }
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: dataAttachment))
        }
        
        if vm.isInstalled {
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = efiStore
            config.bootLoader = bootLoader
        } else {
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: isoAttachment))

            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = efiStore
            config.bootLoader = bootLoader
        }
        
        config.storageDevices = storageDevices
        
        var networkDevices: [VZNetworkDeviceConfiguration] = []
        let primaryDevice = VZVirtioNetworkDeviceConfiguration()
        primaryDevice.attachment = resolvedAttachment(
            preferredMode: vm.networkMode,
            bridgeInterfaceName: vm.bridgeInterfaceName,
            vm: vm,
            updateBridgeName: { vm.bridgeInterfaceName = $0 },
            updateMode: { vm.networkMode = $0 }
        )
        applyPersistentMAC(to: primaryDevice, at: vmDir.appendingPathComponent("mac-address.txt"))
        networkDevices.append(primaryDevice)
        
        if vm.secondaryNetworkEnabled {
            let secondaryDevice = VZVirtioNetworkDeviceConfiguration()
            secondaryDevice.attachment = resolvedAttachment(
                preferredMode: vm.secondaryNetworkMode,
                bridgeInterfaceName: vm.secondaryBridgeInterfaceName,
                vm: vm,
                updateBridgeName: { vm.secondaryBridgeInterfaceName = $0 },
                updateMode: { vm.secondaryNetworkMode = $0 }
            )
            applyPersistentMAC(to: secondaryDevice, at: vmDir.appendingPathComponent("mac-address-2.txt"))
            networkDevices.append(secondaryDevice)
        }
        config.networkDevices = networkDevices
        
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)]
        config.graphicsDevices = [graphicsDevice]
        
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        
        let sharedFolderURL = try VMStorageManager.shared.ensureVMSharedDirectoryExists(for: vm.id)
        let sharedDirectory = VZSharedDirectory(url: sharedFolderURL, readOnly: false)
        let directoryShare = VZSingleDirectoryShare(directory: sharedDirectory)
        let fileSystemDevice = VZVirtioFileSystemDeviceConfiguration(tag: sharedFolderMountTag)
        fileSystemDevice.share = directoryShare
        config.directorySharingDevices = [fileSystemDevice]
        
        return config
    }
    
    private func resolvedAttachment(
        preferredMode: VMNetworkMode,
        bridgeInterfaceName: String?,
        vm: VirtualMachine,
        updateBridgeName: (String?) -> Void,
        updateMode: (VMNetworkMode) -> Void
    ) -> VZNetworkDeviceAttachment {
        if preferredMode == .bridge, EntitlementChecker.hasEntitlement("com.apple.vm.networking") {
            let requiredSubnet = VMNetworkService.shared.primaryClusterSubnetPrefix()
            if let selection = VMNetworkService.shared.resolveBridgeSelection(
                preferred: bridgeInterfaceName,
                requiredSubnetPrefix: requiredSubnet,
                clusterSubnetPrefix: requiredSubnet
            ),
               let interface = VZBridgedNetworkInterface.networkInterfaces.first(where: { $0.identifier == selection.identifier }) {
                updateBridgeName(selection.identifier)
                updateMode(.bridge)
                return VZBridgedNetworkDeviceAttachment(interface: interface)
            }
            logger.warning("No active bridged interface found for VM \(vm.name, privacy: .public). Falling back to NAT.")
        } else if preferredMode == .bridge {
            logger.warning("Missing com.apple.vm.networking entitlement for VM \(vm.name, privacy: .public). Falling back to NAT.")
        }

        updateMode(.nat)
        return VZNATNetworkDeviceAttachment()
    }

    private func applyPersistentMAC(to device: VZVirtioNetworkDeviceConfiguration, at url: URL) {
        if let macString = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let mac = VZMACAddress(string: macString) {
            device.macAddress = mac
        } else {
            let mac = VZMACAddress.randomLocallyAdministered()
            try? mac.string.write(to: url, atomically: true, encoding: .utf8)
            device.macAddress = mac
        }
    }
}
