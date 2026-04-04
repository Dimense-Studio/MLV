import Foundation
import Virtualization
import os

class VMConfigurationBuilder {
    static let shared = VMConfigurationBuilder()
    private let logger = Logger(subsystem: "dimense.net.MLV", category: "VMConfigBuilder")
    private let sharedFolderMountTag = "mlvshare"
    
    func build(for vm: VirtualMachine) async throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        
        // 1. Core Hardware
        config.cpuCount = vm.cpuCount
        config.memorySize = UInt64(vm.memorySizeGB) * 1024 * 1024 * 1024
        
        // 2. Storage & Bootloader
        let vmDir = VMStorageManager.shared.getVMRootDirectory(for: vm.id)
        let systemDiskURL = vmDir.appendingPathComponent("system.raw")
        let dataDiskURL = vmDir.appendingPathComponent("data.raw")
        let isoURL = vmDir.appendingPathComponent("installer.iso")
        let efiStoreURL = vmDir.appendingPathComponent("efi-variable-store")
        
        // Ensure VM directory exists
        _ = try VMStorageManager.shared.ensureVMDirectoryExists(for: vm.id)
        
        // Ensure system/data disks exist
        try VMStorageManager.shared.createSparseDisk(at: systemDiskURL, sizeGiB: vm.systemDiskSizeGB, preallocate: vm.systemDiskProfile == .durable)
        if vm.dataDiskSizeGB > 0 {
            try VMStorageManager.shared.createSparseDisk(at: dataDiskURL, sizeGiB: vm.dataDiskSizeGB, preallocate: vm.dataDiskProfile == .durable)
        }
        
        // EFI Variable Store
        let efiStore: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: efiStoreURL.path) {
            efiStore = VZEFIVariableStore(url: efiStoreURL)
        } else {
            efiStore = try VZEFIVariableStore(creatingVariableStoreAt: efiStoreURL)
        }
        
        // Storage Devices
        var storageDevices: [VZStorageDeviceConfiguration] = []
        
        // System Disk
        let systemAttachment: VZDiskImageStorageDeviceAttachment
        if #available(macOS 13.0, *) {
            systemAttachment = try VZDiskImageStorageDeviceAttachment(
                url: systemDiskURL,
                readOnly: false,
                cachingMode: vm.systemDiskProfile.diskImageCachingMode,
                synchronizationMode: vm.systemDiskProfile.diskImageSynchronizationMode
            )
        } else {
            systemAttachment = try VZDiskImageStorageDeviceAttachment(url: systemDiskURL, readOnly: false)
        }
        storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: systemAttachment))
        
        if vm.dataDiskSizeGB > 0 {
            let dataAttachment: VZDiskImageStorageDeviceAttachment
            if #available(macOS 13.0, *) {
                dataAttachment = try VZDiskImageStorageDeviceAttachment(
                    url: dataDiskURL,
                    readOnly: false,
                    cachingMode: vm.dataDiskProfile.diskImageCachingMode,
                    synchronizationMode: vm.dataDiskProfile.diskImageSynchronizationMode
                )
            } else {
                dataAttachment = try VZDiskImageStorageDeviceAttachment(url: dataDiskURL, readOnly: false)
            }
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: dataAttachment))
        }
        
        // Bootloader Configuration
        if vm.isInstalled {
            // PHASE 2: RUN MODE - Boot from installed disk
            // Note: User-data injection is only supported for cloud-init compatible distros.
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = efiStore
            config.bootLoader = bootLoader
            logger.info("RUN MODE: Configured for EFI Disk Boot (ISO detached)")
        } else {
            // PHASE 1: INSTALL MODE - Attach ISO and boot installer (manual install)
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: isoAttachment))
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = efiStore
            config.bootLoader = bootLoader
            logger.info("INSTALL MODE: Configured for EFI Boot with ISO")
        }
        
        config.storageDevices = storageDevices
        
        // 3. Network
        var networkDevices: [VZNetworkDeviceConfiguration] = []

        let primaryDevice = VZVirtioNetworkDeviceConfiguration()
        primaryDevice.attachment = resolvedAttachment(
            mode: vm.networkMode,
            bridgeInterfaceName: vm.bridgeInterfaceName,
            vm: vm,
            updateBridgeName: { vm.bridgeInterfaceName = $0 }
        )
        applyPersistentMAC(to: primaryDevice, at: vmDir.appendingPathComponent("mac-address.txt"))
        networkDevices.append(primaryDevice)

        if vm.secondaryNetworkEnabled {
            let secondaryDevice = VZVirtioNetworkDeviceConfiguration()
            secondaryDevice.attachment = resolvedAttachment(
                mode: vm.secondaryNetworkMode,
                bridgeInterfaceName: vm.secondaryBridgeInterfaceName,
                vm: vm,
                updateBridgeName: { vm.secondaryBridgeInterfaceName = $0 }
            )
            applyPersistentMAC(to: secondaryDevice, at: vmDir.appendingPathComponent("mac-address-2.txt"))
            networkDevices.append(secondaryDevice)
        }
        config.networkDevices = networkDevices
        
        // 4. Console, Graphics, Input, etc.
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)]
        config.graphicsDevices = [graphicsDevice]
        
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        
        // 5. Shared host folder mounted in guest via virtiofs.
        // Host path: ~/Library/Application Support/mlv-<UUID>/shared
        // Guest mount tag: mlvshare
        let sharedFolderURL = try VMStorageManager.shared.ensureVMSharedDirectoryExists(for: vm.id)
        let sharedDirectory = VZSharedDirectory(url: sharedFolderURL, readOnly: false)
        let directoryShare = VZSingleDirectoryShare(directory: sharedDirectory)
        let fileSystemDevice = VZVirtioFileSystemDeviceConfiguration(tag: sharedFolderMountTag)
        fileSystemDevice.share = directoryShare
        config.directorySharingDevices = [fileSystemDevice]
        
        // Serial Console setup (to be handled by VMManager to manage pipes)
        // config.consoleDevices = ...
        
        // --- BEGIN INSERT ---
        if vm.selectedDistro == .minimal {
            logger.info("Cloud-init path selected for compatible distro")
        } else {
            logger.info("No user-data injected: Distro does not support cloud-init")
        }
        // --- END INSERT ---
        
        return config
    }

    private func resolvedAttachment(
        mode: VMNetworkMode,
        bridgeInterfaceName: String?,
        vm: VirtualMachine,
        updateBridgeName: (String?) -> Void
    ) -> VZNetworkDeviceAttachment {
        if mode == .bridge, let interfaceName = bridgeInterfaceName {
            if EntitlementChecker.hasEntitlement("com.apple.vm.networking") {
                let interfaces = VZBridgedNetworkInterface.networkInterfaces
                if let interface = interfaces.first(where: { $0.identifier == interfaceName }) {
                    return VZBridgedNetworkDeviceAttachment(interface: interface)
                }
                if let first = interfaces.first {
                    updateBridgeName(first.identifier)
                    return VZBridgedNetworkDeviceAttachment(interface: first)
                }
            }
        }
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
