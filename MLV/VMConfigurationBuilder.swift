import Foundation
import Virtualization

class VMConfigurationBuilder {
    static let shared = VMConfigurationBuilder()
    
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
            print("[VMConfigBuilder] RUN MODE: Configured for EFI Disk Boot (ISO detached)")
        } else {
            // PHASE 1: INSTALL MODE - Attach ISO and boot installer (manual install)
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: isoAttachment))
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = efiStore
            config.bootLoader = bootLoader
            print("[VMConfigBuilder] INSTALL MODE: Configured for EFI Boot with ISO")
        }
        
        config.storageDevices = storageDevices
        
        // 3. Network
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        
        if vm.networkMode == .bridge, let interfaceName = vm.bridgeInterfaceName {
            if EntitlementChecker.hasEntitlement("com.apple.vm.networking") {
                let interfaces = VZBridgedNetworkInterface.networkInterfaces
                if let interface = interfaces.first(where: { $0.identifier == interfaceName }) {
                    networkDevice.attachment = VZBridgedNetworkDeviceAttachment(interface: interface)
                    print("[VMConfigBuilder] Using BRIDGED networking on \(interfaceName)")
                } else if let first = interfaces.first {
                    networkDevice.attachment = VZBridgedNetworkDeviceAttachment(interface: first)
                    vm.bridgeInterfaceName = first.identifier
                    print("[VMConfigBuilder] Bridge '\(interfaceName)' not found, using '\(first.identifier)'")
                } else {
                    vm.networkMode = .nat
                    networkDevice.attachment = VZNATNetworkDeviceAttachment()
                    print("[VMConfigBuilder] No bridge interfaces available, falling back to NAT")
                }
            } else {
                vm.networkMode = .nat
                networkDevice.attachment = VZNATNetworkDeviceAttachment()
                print("[VMConfigBuilder] Missing entitlement for bridged networking, using NAT")
            }
        } else {
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
            vm.networkMode = .nat
            print("[VMConfigBuilder] Using NAT networking")
        }
        
        // Restore persistent MAC address if available
        let macURL = vmDir.appendingPathComponent("mac-address.txt")
        if let macString = try? String(contentsOf: macURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let mac = VZMACAddress(string: macString) {
            networkDevice.macAddress = mac
        } else {
            // Generate and save a new MAC
            let mac = VZMACAddress.randomLocallyAdministered()
            try? mac.string.write(to: macURL, atomically: true, encoding: .utf8)
            networkDevice.macAddress = mac
        }
        config.networkDevices = [networkDevice]
        
        // 4. Console, Graphics, Input, etc.
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)]
        config.graphicsDevices = [graphicsDevice]
        
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        
        // Serial Console setup (to be handled by VMManager to manage pipes)
        // config.consoleDevices = ...
        
        // --- BEGIN INSERT ---
        if vm.selectedDistro == .minimal {
            // Example: Attach user-data as a CD-ROM or config drive (adjust for your implementation)
            // ... (actual attachment logic here)
            print("[VMConfigBuilder] Injecting cloud-init user-data (only for compatible distro)")
            // TODO: Attach your userData disk/image here
        } else {
            print("[VMConfigBuilder] No user-data injected: Distro does not support cloud-init.")
        }
        // --- END INSERT ---
        
        return config
    }
    
}
