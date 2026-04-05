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
        config.memorySize = UInt64(vm.memorySizeMB) * 1024 * 1024
        
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
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = efiStore
            config.bootLoader = bootLoader
            logger.info("RUN MODE: Configured for EFI Disk Boot")
        } else {
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            if #available(macOS 13.0, *) {
                storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment))
            } else {
                storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: isoAttachment))
            }
            
            if vm.zeroTouchInstall && vm.selectedDistro == .debian13 {
                var kernelInitrd: (URL, URL)? = extractDebianInstallerKernel(from: isoURL, workingDir: vmDir)
                if kernelInitrd == nil {
                    kernelInitrd = await fetchDebianNetbootKernel(cacheDir: vmDir)
                }
                if let (kernelURL, initrdURL) = kernelInitrd {
                    let linuxBoot = VZLinuxBootLoader(kernelURL: kernelURL)
                    linuxBoot.initialRamdiskURL = initrdURL
                    // Use GitHub raw URL for the preseed file instead of the local server
                    let preseedURL = "https://raw.githubusercontent.com/Dimense-Studio/MLV/main/preseed.cfg"
                    linuxBoot.commandLine = "auto priority=critical preseed/url=\(preseedURL) debian-installer/locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us --- quiet"
                    config.bootLoader = linuxBoot
                    logger.info("INSTALL MODE: Zero-touch Debian with VZLinuxBootLoader")
                } else {
                    let bootLoader = VZEFIBootLoader()
                    bootLoader.variableStore = efiStore
                    config.bootLoader = bootLoader
                    logger.error("INSTALL MODE: Failed to get kernel; fallback to EFI")
                }
            } else {
                let bootLoader = VZEFIBootLoader()
                bootLoader.variableStore = efiStore
                config.bootLoader = bootLoader
                logger.info("INSTALL MODE: Configured for EFI Boot with ISO")
            }
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
        
        // 5. Shared folder
        let sharedFolderURL = try VMStorageManager.shared.ensureVMSharedDirectoryExists(for: vm.id)
        let sharedDirectory = VZSharedDirectory(url: sharedFolderURL, readOnly: false)
        let directoryShare = VZSingleDirectoryShare(directory: sharedDirectory)
        let fileSystemDevice = VZVirtioFileSystemDeviceConfiguration(tag: sharedFolderMountTag)
        fileSystemDevice.share = directoryShare
        config.directorySharingDevices = [fileSystemDevice]
        
        // Cloud-init note
        if vm.selectedDistro == .minimal {
            logger.info("Cloud-init path selected")
        } else {
            logger.info("No user-data injected")
        }
        
        return config
    }
    
    private func extractDebianInstallerKernel(from iso: URL, workingDir: URL) -> (URL, URL)? {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mountPoint = tempRoot.appendingPathComponent("mnt")
        try? fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", iso.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        try? attach.run()
        attach.waitUntilExit()
        if attach.terminationStatus != 0 {
            return nil
        }
        
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-force"]
            try? detach.run()
            detach.waitUntilExit()
            try? fm.removeItem(at: tempRoot)
        }
        
        guard let (kernelSource, initrdSource) = findInstallerArtifacts(at: mountPoint) else {
            return nil
        }
        
        let kernelDest = workingDir.appendingPathComponent("vmlinuz-installer")
        let initrdDest = workingDir.appendingPathComponent("initrd-installer.gz")
        
        if fm.fileExists(atPath: kernelDest.path) { try? fm.removeItem(at: kernelDest) }
        if fm.fileExists(atPath: initrdDest.path) { try? fm.removeItem(at: initrdDest) }
        do {
            try fm.copyItem(at: kernelSource, to: kernelDest)
            try fm.copyItem(at: initrdSource, to: initrdDest)
            return (kernelDest, initrdDest)
        } catch {
            return nil
        }
    }
    
    private func findInstallerArtifacts(at mountPoint: URL) -> (URL, URL)? {
        let fm = FileManager.default
        let searchNames = ["install.amd", "install.amd64", "install.386", "install"]
        for name in searchNames {
            let dir = mountPoint.appendingPathComponent(name)
            let k = dir.appendingPathComponent("vmlinuz")
            let i = dir.appendingPathComponent("initrd.gz")
            if fm.fileExists(atPath: k.path) && fm.fileExists(atPath: i.path) {
                return (k, i)
            }
        }
        
        if let enumerator = fm.enumerator(at: mountPoint, includingPropertiesForKeys: nil) {
            var foundKernel: URL?
            var foundInitrd: URL?
            for case let url as URL in enumerator {
                let name = url.lastPathComponent.lowercased()
                if foundKernel == nil && (name == "vmlinuz" || name == "linux") {
                    foundKernel = url
                }
                if foundInitrd == nil && (name == "initrd.gz" || name == "initrd") {
                    foundInitrd = url
                }
                if foundKernel != nil && foundInitrd != nil { break }
            }
            if let k = foundKernel, let i = foundInitrd {
                return (k, i)
            }
        }
        return nil
    }
    
    private func fetchDebianNetbootKernel(cacheDir: URL) async -> (URL, URL)? {
        let fm = FileManager.default
        #if arch(arm64)
        let archPath = "arm64"
        #else
        let archPath = "amd64"
        #endif
        
        let kernelDest = cacheDir.appendingPathComponent("vmlinuz-netboot-\(archPath)")
        let initrdDest = cacheDir.appendingPathComponent("initrd-netboot-\(archPath).gz")
        
        if fm.fileExists(atPath: kernelDest.path) && fm.fileExists(atPath: initrdDest.path) {
            return (kernelDest, initrdDest)
        }
        
        guard let kernelURL = URL(string: "https://deb.debian.org/debian/dists/trixie/main/installer-\(archPath)/current/images/netboot/debian-installer/\(archPath)/linux"),
              let initrdURL = URL(string: "https://deb.debian.org/debian/dists/trixie/main/installer-\(archPath)/current/images/netboot/debian-installer/\(archPath)/initrd.gz") else {
            return nil
        }
        
        do {
            if !fm.fileExists(atPath: kernelDest.path) {
                let (data, _) = try await URLSession.shared.data(from: kernelURL)
                try data.write(to: kernelDest, options: .atomic)
            }
            if !fm.fileExists(atPath: initrdDest.path) {
                let (data, _) = try await URLSession.shared.data(from: initrdURL)
                try data.write(to: initrdDest, options: .atomic)

            }
            return (kernelDest, initrdDest)
        } catch {
            logger.error("Netboot download failed: \(error.localizedDescription)")
            return nil
        }
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
