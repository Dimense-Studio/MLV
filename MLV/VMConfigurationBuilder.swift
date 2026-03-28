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
        try VMStorageManager.shared.createSparseDisk(at: systemDiskURL, sizeGiB: vm.systemDiskSizeGB)
        try VMStorageManager.shared.createSparseDisk(at: dataDiskURL, sizeGiB: vm.dataDiskSizeGB)
        
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
        let systemAttachment = try VZDiskImageStorageDeviceAttachment(url: systemDiskURL, readOnly: false)
        storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: systemAttachment))
        
        // Data Disk
        let dataAttachment = try VZDiskImageStorageDeviceAttachment(url: dataDiskURL, readOnly: false)
        storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: dataAttachment))
        
        // Bootloader Configuration
        if vm.isInstalled {
            // PHASE 2: RUN MODE - Boot from installed disk
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = efiStore
            config.bootLoader = bootLoader
            print("[VMConfigBuilder] RUN MODE: Configured for EFI Disk Boot (ISO detached)")
        } else {
            // PHASE 1: INSTALL MODE - Attach ISO and boot installer
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoURL, readOnly: true)
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: isoAttachment))
            
            // Distro-specific bootloader logic (mimicking VMManager but cleaner)
            switch vm.selectedDistro {
            case .debian13, .alpine:
                let kernelURL = vmDir.appendingPathComponent("vmlinuz")
                let initrdURL = vmDir.appendingPathComponent("initrd.gz")
                
                let haveKernel = FileManager.default.fileExists(atPath: kernelURL.path)
                let haveInitrd = FileManager.default.fileExists(atPath: initrdURL.path)
                if haveKernel && haveInitrd {
                    let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
                    bootLoader.initialRamdiskURL = initrdURL
                    bootLoader.commandLine = getInstallerCommandLine(for: vm.selectedDistro, isMaster: vm.isMaster)
                    config.bootLoader = bootLoader
                    print("[VMConfigBuilder] INSTALL MODE: Direct Kernel Boot (kernel/initrd present)")
                } else {
                    let bootLoader = VZEFIBootLoader()
                    bootLoader.variableStore = efiStore
                    config.bootLoader = bootLoader
                    print("[VMConfigBuilder] INSTALL MODE: Fallback to EFI Boot (kernel/initrd missing)")
                }
                
            case .ubuntu, .minimal:
                let bootLoader = VZEFIBootLoader()
                bootLoader.variableStore = efiStore
                config.bootLoader = bootLoader
                
                // Ubuntu needs the seed ISO for autoinstall
                let seedISOURL = vmDir.appendingPathComponent("cidata.iso")
                if FileManager.default.fileExists(atPath: seedISOURL.path) {
                    let seedAttachment = try VZDiskImageStorageDeviceAttachment(url: seedISOURL, readOnly: true)
                    storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: seedAttachment))
                }
                print("[VMConfigBuilder] INSTALL MODE: Configured for EFI Boot with ISOs")
            }
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
        
        return config
    }
    
    private func getInstallerCommandLine(for distro: VirtualMachine.LinuxDistro, isMaster: Bool) -> String {
        switch distro {
        case .debian13:
            return "auto=true priority=critical console=hvc0 console=tty0 earlycon=virtio_console video=1280x720 DEBIAN_FRONTEND=text preseed/file=/preseed.cfg ipv6.disable=1 netcfg/choose_interface=auto netcfg/link_wait_timeout=60 netcfg/dhcp_timeout=60 netcfg/dhcpv6_timeout=1 netcfg/get_nameservers=8.8.8.8,1.1.1.1 mirror/country=manual mirror/http/hostname=deb.debian.org mirror/http/directory=/debian mirror/suite=trixie mirror/udeb/suite=trixie hw-detect/load_firmware=false"
        case .alpine:
            return "console=hvc0 console=tty0 earlycon=virtio_console"
        default:
            return "console=hvc0 console=tty0 earlycon=virtio_console"
        }
    }
}
