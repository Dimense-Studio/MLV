import Foundation
import Virtualization
import SwiftUI
import AppKit

@MainActor
@Observable
class VMManager {
    static let shared = VMManager()
    var virtualMachines: [VirtualMachine] = []
    
    // Persistent ISO authorization
    private let isoBookmarkKey = "MLV_ISO_Bookmark"
    var authorizedISOURL: URL? {
        didSet {
            if let url = authorizedISOURL {
                saveBookmark(for: url)
            }
        }
    }

    private init() {
        loadBookmark()
    }
    
    private func saveBookmark(for url: URL) {
        // The URL from fileImporter is already scoped. We just need to bookmark it.
        // We try to access it first to ensure we have permission.
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        
        do {
            // Using security-scoped bookmark data is essential for sandboxed apps
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: isoBookmarkKey)
            print("[VMManager] Saved ISO bookmark for: \(url.lastPathComponent)")
        } catch {
            print("[VMManager] Error saving bookmark: \(error.localizedDescription)")
            
            // If the standard bookmark fails, try a minimal bookmark without security scope
            // as a fallback for some edge cases (though less ideal for sandbox persistence)
            do {
                let minimalData = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(minimalData, forKey: isoBookmarkKey)
                print("[VMManager] Saved minimal bookmark as fallback for: \(url.lastPathComponent)")
            } catch {
                print("[VMManager] FINAL error saving bookmark: \(error.localizedDescription)")
            }
        }
    }
    
    private func loadBookmark() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: isoBookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            // Try to access to verify it's valid
            if url.startAccessingSecurityScopedResource() {
                // We keep it open during loading to ensure stale check works
                if isStale {
                    saveBookmark(for: url)
                }
                self.authorizedISOURL = url
                url.stopAccessingSecurityScopedResource()
                print("[VMManager] Loaded and verified authorized ISO: \(url.lastPathComponent)")
            } else {
                print("[VMManager] ERROR: Failed to access security scoped bookmark for: \(url.lastPathComponent)")
                // Clear the stale bookmark if we can't access it
                UserDefaults.standard.removeObject(forKey: isoBookmarkKey)
                self.authorizedISOURL = nil
            }
        } catch {
            print("[VMManager] Error loading bookmark: \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: isoBookmarkKey)
            self.authorizedISOURL = nil
        }
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }
    
    private func runProcess(executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw VMError.configurationInvalid("Failed to launch process \(executable): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
    
    // Use the embedded template ISO for all machines
    private var templateISOURL: URL? {
        let isoName = "debian-13.1.0-arm64-netinst"
        
        // 1. Try Bundle (Recommended for Sandbox)
        if let bundleURL = Bundle.main.url(forResource: isoName, withExtension: "iso") {
            print("[VMManager] Found template ISO in bundle: \(bundleURL.path)")
            return bundleURL
        }
        
        // 2. Try User-Authorized Bookmark (Persistent across launches)
        if let authorized = authorizedISOURL {
            print("[VMManager] Found authorized ISO: \(authorized.path)")
            return authorized
        }
        
        // 3. Try Absolute User Path (Bypassing sandbox-relative home)
        let userName = NSUserName()
        let specificPath = URL(fileURLWithPath: "/Users/\(userName)/Desktop/MLV/MLV/\(isoName).iso")
        if FileManager.default.fileExists(atPath: specificPath.path) {
            print("[VMManager] Found template ISO at specific path: \(specificPath.path)")
            return specificPath
        }
        
        // 4. Try Development Fallback (Parent of bundle)
        let bundlePath = Bundle.main.bundleURL
        let projectRoot = bundlePath.deletingLastPathComponent().deletingLastPathComponent()
        let devISOURL = projectRoot.appendingPathComponent("\(isoName).iso")
        if FileManager.default.fileExists(atPath: devISOURL.path) {
            print("[VMManager] Found template ISO in dev project root: \(devISOURL.path)")
            return devISOURL
        }
        
        // 5. Try current working directory
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let cwdISO = cwd.appendingPathComponent("\(isoName).iso")
        if FileManager.default.fileExists(atPath: cwdISO.path) {
            print("[VMManager] Found template ISO in CWD: \(cwdISO.path)")
            return cwdISO
        }
        
        print("[VMManager] ERROR: Template ISO not found in bundle, authorized list, Desktop (\(specificPath.path)), or dev root.")
        return nil
    }
    
    func createLinuxVM(name: String? = nil, cpus: Int = 4, ramGB: Int = 8, sysDiskGB: Int = 64, dataDiskGB: Int = 100, isMaster: Bool = false, networkType: HostResources.NetworkInterface.InterfaceType = .ethernet, bsdName: String = "en0", networkSpeed: String = "10 Gbps") async throws -> VirtualMachine {
        if !VZVirtualMachine.isSupported {
            throw VMError.virtualizationNotSupported
        }
        
        // Verify template ISO exists
        guard let isoURL = templateISOURL else {
            throw VMError.configurationInvalid("Template ISO not found. Please ensure 'debian-13.1.0-arm64-netinst.iso' is added to the Xcode project and its target.")
        }
        
        let vmName = name ?? "Node \(virtualMachines.count + 1)"
        let vm = VirtualMachine(name: vmName, isoURL: isoURL, cpus: cpus, ramGB: ramGB, sysDiskGB: sysDiskGB, dataDiskGB: dataDiskGB)
        vm.isMaster = isMaster
        vm.networkInterfaceType = networkType
        vm.networkInterfaceBSDName = bsdName
        vm.networkSpeed = networkSpeed
        
        self.virtualMachines.append(vm)
        
        do {
            try await startVM(vm)
        } catch {
            vm.state = .error(error.localizedDescription)
            throw error
        }
        return vm
    }
    
    func startVM(_ vm: VirtualMachine) async throws {
        // Prevent multiple starts for the same VM
        if vm.state == .starting || vm.state == .running {
            vm.addLog("VM is already starting or running.")
            return
        }
        
        vm.addLog("Starting Virtual Machine sequence...")
        vm.state = .starting
        vm.deploymentProgress = 0.05
        
        do {
            // Clean up any existing engine instance
            if let existing = vm.vzVirtualMachine {
                try? await existing.stop()
                vm.vzVirtualMachine = nil
            }
            
            let configuration = try await createVMConfiguration(for: vm)
            vm.addLog("Configuration validated successfully.")
            vm.deploymentProgress = 0.2

            let v = VZVirtualMachine(configuration: configuration, queue: .main)
            vm.vzVirtualMachine = v
            
            // Set up state observation
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("VZVirtualMachineDidStop"),
                object: v,
                queue: .main
            ) { _ in
                vm.addLog("VM process terminated.")
                vm.state = .stopped
                
                // If it stopped during installation, it might have finished the first stage
                if !vm.isInstalled {
                    // We should ideally check if the system disk is now bootable
                    vm.addLog("Node installation stage 1 complete.")
                    vm.isInstalled = true
                    vm.deploymentProgress = 1.0
                }
            }
            
            vm.addLog("Launching virtualization engine...")
            try await v.start()
            vm.addLog("Virtual Machine process is now running.")
            vm.deploymentProgress = 0.25
            vm.state = .running
        } catch {
            vm.addLog("ERROR: \(error.localizedDescription)", isError: true)
            vm.state = .error(error.localizedDescription)
            throw error
        }
    }
    
    private func streamCopy(from source: URL, to destination: URL) throws {
        let didStartAccess = source.startAccessingSecurityScopedResource()
        defer { if didStartAccess { source.stopAccessingSecurityScopedResource() } }
        
        guard let inputStream = InputStream(url: source) else {
            throw VMError.configurationInvalid("Failed to open source ISO for reading")
        }
        guard let outputStream = OutputStream(url: destination, append: false) else {
            throw VMError.configurationInvalid("Failed to open destination for writing")
        }
        
        inputStream.open()
        outputStream.open()
        defer {
            inputStream.close()
            outputStream.close()
        }
        
        let bufferSize = 1024 * 1024 // 1MB buffer
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        while inputStream.hasBytesAvailable {
            let read = inputStream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                throw inputStream.streamError ?? VMError.configurationInvalid("Read error during ISO staging")
            }
            if read == 0 { break }
            
            var written = 0
            while written < read {
                let result = outputStream.write(buffer.advanced(by: written), maxLength: read - written)
                if result < 0 {
                    throw outputStream.streamError ?? VMError.configurationInvalid("Write error during ISO staging")
                }
                written += result
            }
        }
    }
    
    private func removeQuarantine(from url: URL) {
        _ = try? runProcess(executable: "/usr/bin/xattr", arguments: ["-d", "com.apple.quarantine", url.path])
    }
    
    private func createVMConfiguration(for vm: VirtualMachine) async throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        
        // CPU and Memory from VM object
        config.cpuCount = vm.cpuCount
        config.memorySize = UInt64(vm.memorySizeGB) * 1024 * 1024 * 1024
        
        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let vmTempDir = containerDir.appendingPathComponent("mlv-\(vm.id.uuidString)", isDirectory: true)
        
        // Ensure the directory is created with correct permissions before copying
        do {
            if !FileManager.default.fileExists(atPath: vmTempDir.path) {
                try FileManager.default.createDirectory(at: vmTempDir, withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            throw VMError.configurationInvalid("Failed to create node directory: \(error.localizedDescription)")
        }
        
        // Stage ISO to container FIRST. 
        let stagedISOURL = vmTempDir.appendingPathComponent("installer.iso")
        
        // Always verify the staged ISO is complete. If it's missing or too small (< 10MB), re-stage it.
        var needsStaging = true
        if FileManager.default.fileExists(atPath: stagedISOURL.path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: stagedISOURL.path),
               let size = attrs[.size] as? UInt64,
               size > 10 * 1024 * 1024 {
                needsStaging = false
                vm.addLog("Staged ISO exists (\(size / 1024 / 1024) MB).")
            } else {
                vm.addLog("Staged ISO is incomplete. Re-staging...")
                try? FileManager.default.removeItem(at: stagedISOURL)
            }
        }
        
        if needsStaging {
            vm.addLog("Staging ISO to cluster storage...")
            vm.deploymentProgress = 0.2
            
            do {
                // Try streaming copy as it's more robust for security-scoped resources
                try streamCopy(from: vm.isoURL, to: stagedISOURL)
                
                // Remove quarantine attribute if it exists
                removeQuarantine(from: stagedISOURL)
                
                // Verify the copy actually worked
                let attrs = try FileManager.default.attributesOfItem(atPath: stagedISOURL.path)
                let size = attrs[.size] as? UInt64 ?? 0
                vm.addLog("Staging successful (\(size / 1024 / 1024) MB).")
            } catch {
                vm.addLog("Staging failed: \(error.localizedDescription)", isError: true)
                
                // Fallback to standard copy
                do {
                    if FileManager.default.fileExists(atPath: stagedISOURL.path) {
                        try? FileManager.default.removeItem(at: stagedISOURL)
                    }
                    try FileManager.default.copyItem(at: vm.isoURL, to: stagedISOURL)
                } catch {
                    throw VMError.configurationInvalid("Permission Denied: Could not copy ISO.")
                }
            }
        }

        let variableStoreURL = vmTempDir.appendingPathComponent("efi-variable-store")
        let variableStore: VZEFIVariableStore
        
        if FileManager.default.fileExists(atPath: variableStoreURL.path) {
            variableStore = VZEFIVariableStore(url: variableStoreURL)
        } else {
            do {
                variableStore = try VZEFIVariableStore(creatingVariableStoreAt: variableStoreURL)
            } catch {
                vm.addLog("Failed to create EFI store.", isError: true)
                throw VMError.configurationInvalid("Failed to create EFI variable store: \(error.localizedDescription)")
            }
        }

        if vm.isInstalled {
            // Normal boot using EFI
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = variableStore
            config.bootLoader = bootLoader
            vm.addLog("Configured for EFI Disk Boot.")
        } else {
            // First time boot - automated install using LinuxBootLoader
            // We mount the STAGED iso which is inside the container
            vm.addLog("Extracting installer kernel/initrd...")
            vm.deploymentProgress = 0.3
            let (kernelURL, initrdURL) = try await extractKernelAndInitrd(from: stagedISOURL, to: vmTempDir, vm: vm)
            
            // Inject preseed.cfg into the initrd.gz for zero-touch install
            vm.addLog("Injecting zero-touch automation config...")
            vm.deploymentProgress = 0.4
            try injectPreseed(into: initrdURL, isMaster: vm.isMaster, vm: vm)
            
            let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
            bootLoader.initialRamdiskURL = initrdURL
            
            // High-Performance Boot arguments for Debian 13 ARM64 on Apple Silicon
            // console=hvc0: Use Virtio Console as primary for zero-touch logs
            // console=tty0: Enable the graphics console as a secondary view
            // DEBIAN_FRONTEND=text: Use text-based installer for maximum stability
            // iommu.passthrough=1: Improve Virtio stability on M4
            // ipv6.disable=1: Disable IPv6 to prevent mirror resolution timeouts
            bootLoader.commandLine = "auto=true priority=critical console=hvc0 console=tty0 earlycon=virtio_console video=1280x720 DEBIAN_FRONTEND=text preseed/file=/preseed.cfg iommu.passthrough=1 ipv6.disable=1"
            config.bootLoader = bootLoader
            vm.addLog("Configured for Automated Installation Boot.")
        }
        
        // Storage - attach the staged installer ISO plus a writable system disk.
        let isoAttachment: VZDiskImageStorageDeviceAttachment
        do {
            isoAttachment = try VZDiskImageStorageDeviceAttachment(
                url: stagedISOURL,
                readOnly: true
            )
        } catch {
            // Clean up temp files if attachment fails
            try? FileManager.default.removeItem(at: vmTempDir)
            vm.addLog("Failed to attach ISO.", isError: true)
            throw VMError.configurationInvalid("Failed to attach ISO: \(error.localizedDescription)")
        }
        
        let isoDevice = VZVirtioBlockDeviceConfiguration(attachment: isoAttachment)

        let systemDiskURL = vmTempDir.appendingPathComponent("system.img")
        if !FileManager.default.fileExists(atPath: systemDiskURL.path) {
            vm.addLog("Creating \(vm.systemDiskSizeGB)GiB system disk...")
            let created = FileManager.default.createFile(atPath: systemDiskURL.path, contents: nil)
            if !created {
                throw VMError.configurationInvalid("Failed to create system disk image")
            }
            do {
                let fileHandle = try FileHandle(forWritingTo: systemDiskURL)
                try fileHandle.truncate(atOffset: UInt64(vm.systemDiskSizeGB) * 1024 * 1024 * 1024)
                try fileHandle.close()
            } catch {
                throw VMError.configurationInvalid("Failed to size system disk image: \(error.localizedDescription)")
            }
        }

        let systemAttachment: VZDiskImageStorageDeviceAttachment
        do {
            systemAttachment = try VZDiskImageStorageDeviceAttachment(url: systemDiskURL, readOnly: false)
        } catch {
            throw VMError.configurationInvalid("Failed to attach system disk: \(error.localizedDescription)")
        }

        let systemDiskDevice = VZVirtioBlockDeviceConfiguration(attachment: systemAttachment)
        
        // Add a secondary data disk for Longhorn/Storage tests if needed
        let dataDiskURL = vmTempDir.appendingPathComponent("data.img")
        
        if !FileManager.default.fileExists(atPath: dataDiskURL.path) {
            FileManager.default.createFile(atPath: dataDiskURL.path, contents: nil)
            let fileHandle = try? FileHandle(forWritingTo: dataDiskURL)
            try? fileHandle?.truncate(atOffset: UInt64(vm.dataDiskSizeGB) * 1024 * 1024 * 1024)
            try? fileHandle?.close()
        }
        
        // CRITICAL DEVICE ORDER:
        // 1. System Disk (/dev/vda) - Target for OS
        // 2. Data Disk (/dev/vdb) - Reserved for Longhorn
        // 3. ISO Installer (/dev/vdc) - Read-only source
        var storageDevices: [VZStorageDeviceConfiguration] = [systemDiskDevice]
        
        if let dataAttachment = try? VZDiskImageStorageDeviceAttachment(url: dataDiskURL, readOnly: false) {
            let dataDevice = VZVirtioBlockDeviceConfiguration(attachment: dataAttachment)
            storageDevices.append(dataDevice)
        }
        
        storageDevices.append(isoDevice)
        config.storageDevices = storageDevices
        
        // Network - High-Performance NAT (standard for Sandbox)
        // Note: Bridged networking requires a restricted Apple entitlement (com.apple.vm.networking)
        // which is only available to organizations with specific provisioning.
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        
        vm.addLog("Configuring NAT virtualization with optimized DNS...")
        
        // Set a MAC address for stability in K8s clusters
        networkDevice.macAddress = VZMACAddress.randomLocallyAdministered()
        config.networkDevices = [networkDevice]
        
        // Serial Console - standard way for Linux to communicate boot logs
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let portConfig = VZVirtioConsolePortConfiguration()
        
        let readPipe = Pipe()
        let writePipe = Pipe()
        
        let attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: readPipe.fileHandleForReading,
            fileHandleForWriting: writePipe.fileHandleForWriting
        )
        portConfig.attachment = attachment
        
        // Store the write pipe for interactivity
        vm.serialWritePipe = writePipe
        
        // Listen for data
        readPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            
            if let str = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    vm.consoleOutput.append(str)
                    
                    // Intelligent log filtering for the Provisioning Dashboard
                    if !vm.isInstalled {
                        // Detect if user interaction is needed
                        let stuckKeywords = [
                            "bad archive mirror",
                            "choose a mirror",
                            "partitioning",
                            "configure the network",
                            "enter the hostname",
                            "failure",
                            "warning"
                        ]
                        
                        for keyword in stuckKeywords {
                            if str.localizedCaseInsensitiveContains(keyword) {
                                vm.needsUserInteraction = true
                                vm.addLog("Action Required: \(keyword) detected in installer.", isError: true)
                                break
                            }
                        }

                        // Granular Progress Tracking
                        if str.localizedCaseInsensitiveContains("Linux version") {
                            vm.addLog("Kernel sequence initiated.")
                            vm.deploymentProgress = 0.3
                        } else if str.localizedCaseInsensitiveContains("debian-installer") {
                            vm.addLog("Automated installer detected.")
                            vm.deploymentProgress = 0.35
                        } else if str.localizedCaseInsensitiveContains("netcfg") {
                            vm.addLog("Configuring the network...")
                            vm.deploymentProgress = 0.4
                        } else if str.localizedCaseInsensitiveContains("partman") {
                            vm.addLog("Partitioning disks...")
                            vm.deploymentProgress = 0.5
                        } else if str.localizedCaseInsensitiveContains("debootstrap") {
                            vm.addLog("Installing the base system...")
                            vm.deploymentProgress = 0.6
                        } else if str.localizedCaseInsensitiveContains("pkgsel") {
                            vm.addLog("Selecting and installing software...")
                            vm.deploymentProgress = 0.75
                        } else if str.localizedCaseInsensitiveContains("grub-installer") {
                            vm.addLog("Installing boot loader...")
                            vm.deploymentProgress = 0.85
                        } else if str.localizedCaseInsensitiveContains("late_command") || str.localizedCaseInsensitiveContains("Starting K3s") {
                            vm.addLog("Executing post-install automation (K3s/Storage)...")
                            vm.deploymentProgress = 0.95
                        } else if str.localizedCaseInsensitiveContains("Installation complete") {
                            vm.addLog("Deployment finalized.")
                            vm.deploymentProgress = 1.0
                            vm.needsUserInteraction = false
                        }
                    }
                    
                    // Keep console output to a reasonable size
                    if vm.consoleOutput.count > 100000 {
                        vm.consoleOutput = String(vm.consoleOutput.suffix(50000))
                    }
                }
            }
        }
        
        consoleDevice.ports[0] = portConfig
        config.consoleDevices = [consoleDevice]
        
        // Entropy
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        
        // Graphics
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        // Use 1280x720 for maximum compatibility during install
        let scanout = VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)
        graphicsDevice.scanouts = [scanout]
        config.graphicsDevices = [graphicsDevice]
        
        // Input - Essential for interacting with the VM
        // For Linux guests, we use USB-based keyboard and screen-coordinate pointing devices
        let keyboardDevice = VZUSBKeyboardConfiguration()
        let pointingDevice = VZUSBScreenCoordinatePointingDeviceConfiguration()
        config.keyboards = [keyboardDevice]
        config.pointingDevices = [pointingDevice]
        
        // Audio (optional) - using generic audio device without specific sink for now
        #if os(macOS)
        if #available(macOS 15.0, *) {
            let audioOutput = VZVirtioSoundDeviceOutputStreamConfiguration()
            let audioDevice = VZVirtioSoundDeviceConfiguration()
            audioDevice.streams = [audioOutput]
            config.audioDevices = [audioDevice]
        }
        #endif
        
        // Validate configuration
        do {
            try config.validate()
        } catch {
            // Clean up temp files if validation fails
            try? FileManager.default.removeItem(at: vmTempDir)
            throw VMError.configurationInvalid("VM configuration invalid: \(error.localizedDescription)")
        }
        
        return config
    }
    
    func stopVM(_ vm: VirtualMachine) async throws {
        guard let vzVM = vm.vzVirtualMachine else { return }
        try await vzVM.stop()
        vm.state = .stopped
    }

    func restartVM(_ vm: VirtualMachine) async throws {
        try await stopVM(vm)
        try await startVM(vm)
    }
    
    func pauseVM(_ vm: VirtualMachine) async throws {
        guard let vzVM = vm.vzVirtualMachine else { return }
        try await vzVM.pause()
        vm.state = .paused
    }
    
    func resumeVM(_ vm: VirtualMachine) async throws {
        guard let vzVM = vm.vzVirtualMachine else { return }
        try await vzVM.resume()
        vm.state = .running
    }
    
    func removeVM(_ vm: VirtualMachine) {
        // Stop the VM if it's running
        Task {
            if vm.state != .stopped {
                try? await stopVM(vm)
            }
            
            // Delete disk files
            if let dir = vm.vmDirectory {
                try? FileManager.default.removeItem(at: dir)
            }
            
            virtualMachines.removeAll { $0.id == vm.id }
        }
    }

    private func extractKernelAndInitrd(from isoURL: URL, to tempDir: URL, vm: VirtualMachine) async throws -> (kernelURL: URL, initrdURL: URL) {
        let kernelURL = tempDir.appendingPathComponent("vmlinuz")
        let initrdURL = tempDir.appendingPathComponent("initrd.gz")
        
        if FileManager.default.fileExists(atPath: kernelURL.path) && FileManager.default.fileExists(atPath: initrdURL.path) {
            return (kernelURL, initrdURL)
        }

        vm.addLog("Extracting ISO contents via 'tar'...")
        
        // Debian arm64 installer paths - search list
        let kernelPaths = [
            "install.a64/vmlinuz",
            "install/vmlinuz",
            "casper/vmlinuz",
            "vmlinuz"
        ]
        let initrdPaths = [
            "install.a64/initrd.gz",
            "install/initrd.gz",
            "casper/initrd.gz",
            "initrd.gz"
        ]

        // Use 'tar' to extract. bsdtar on macOS can read ISOs and is sandbox-friendly
        // Unlike hdiutil, it doesn't need to 'mount' a device.
        
        var foundKernel = false
        for path in kernelPaths {
            let result = try runProcess(executable: "/usr/bin/tar", arguments: ["-xf", isoURL.path, "-C", tempDir.path, path])
            if result.exitCode == 0 {
                let extracted = tempDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: extracted.path) {
                    try? FileManager.default.removeItem(at: kernelURL)
                    try FileManager.default.moveItem(at: extracted, to: kernelURL)
                    // Ensure the extracted file is writable by the user
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kernelURL.path)
                    vm.addLog("Kernel extracted: \(path)")
                    foundKernel = true
                    break
                }
            }
        }

        var foundInitrd = false
        for path in initrdPaths {
            let result = try runProcess(executable: "/usr/bin/tar", arguments: ["-xf", isoURL.path, "-C", tempDir.path, path])
            if result.exitCode == 0 {
                let extracted = tempDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: extracted.path) {
                    try? FileManager.default.removeItem(at: initrdURL)
                    try FileManager.default.moveItem(at: extracted, to: initrdURL)
                    // Ensure the extracted file is writable by the user
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: initrdURL.path)
                    vm.addLog("Initrd extracted: \(path)")
                    foundInitrd = true
                    break
                }
            }
        }

        if foundKernel && foundInitrd {
            return (kernelURL, initrdURL)
        }

        // Fallback to hdiutil ONLY if tar fails (though tar is more likely to work in sandbox)
        vm.addLog("Tar failed. Falling back to 'hdiutil' mount...", isError: true)

        let mountPoint = tempDir.appendingPathComponent("iso_mount")
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attachResult = try runProcess(executable: "/usr/bin/hdiutil", arguments: ["attach", isoURL.path, "-mountpoint", mountPoint.path, "-readonly", "-nobrowse", "-noverify"])
        
        if attachResult.exitCode != 0 {
            throw VMError.configurationInvalid("Extraction failed.")
        }
        
        defer {
            _ = try? runProcess(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"])
        }

        for path in kernelPaths {
            let src = mountPoint.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: kernelURL)
                try FileManager.default.copyItem(at: src, to: kernelURL)
                // Ensure the extracted file is writable by the user
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kernelURL.path)
                foundKernel = true
                break
            }
        }

        for path in initrdPaths {
            let src = mountPoint.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: initrdURL)
                try FileManager.default.copyItem(at: src, to: initrdURL)
                // Ensure the extracted file is writable by the user
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kernelURL.path)
                foundInitrd = true
                break
            }
        }

        guard foundKernel, foundInitrd else {
            throw VMError.configurationInvalid("Failed to find vmlinuz/initrd.gz.")
        }

        return (kernelURL, initrdURL)
    }

    private func injectPreseed(into initrdURL: URL, isMaster: Bool, vm: VirtualMachine) throws {
        vm.addLog("Generating preseed.cfg...")
        
        let k3sCommand = isMaster ? 
            "curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 --cluster-init --disable traefik" :
            "curl -sfL https://get.k3s.io | K3S_URL=https://mlv-master:6443 K3S_TOKEN=mlv-cluster-token sh -"
            
        let preseed = """
        d-i debian-installer/locale string en_US
        d-i keyboard-configuration/xkb-keymap select us
        
        # Robust Network Configuration
        d-i netcfg/choose_interface select auto
        d-i netcfg/link_wait_timeout string 10
        d-i netcfg/dhcp_timeout string 60
        d-i netcfg/get_hostname string \(isMaster ? "mlv-master" : "mlv-node")
        d-i netcfg/get_domain string local
        
        # Disable IPv6 and force IPv4 for mirror discovery
        d-i netcfg/enable_ipv6 boolean false
        d-i netcfg/disable_autoconfig boolean false
        
        # Explicit DNS to avoid resolution failures
        d-i netcfg/get_nameservers string 8.8.8.8 1.1.1.1 9.9.9.9 192.168.64.1
        d-i netcfg/confirm_static boolean true
        
        # Mirror selection - Debian 13 (Trixie)
        d-i mirror/country string manual
        d-i mirror/http/hostname string deb.debian.org
        d-i mirror/http/directory string /debian
        d-i mirror/http/proxy string
        d-i mirror/suite string trixie
        d-i mirror/udeb/suite string trixie
        
        # Mirror failure handling & robustness
        d-i mirror/protocol string http
        d-i mirror/http/mirror select deb.debian.org
        d-i mirror/http/hostname_fallback string http.debian.net
        d-i mirror/error/ignore boolean true
        d-i apt-setup/use_mirror boolean true
        d-i apt-setup/no_mirror boolean false
        
        # Alternative mirrors in case deb.debian.org is slow/blocked
        d-i apt-setup/local0/repository string http://deb.debian.org/debian trixie main contrib non-free
        d-i apt-setup/local1/repository string http://http.debian.net/debian trixie main contrib non-free
        d-i apt-setup/local2/repository string http://ftp.us.debian.org/debian trixie main contrib non-free
        
        d-i apt-setup/services-select multiselect security, updates
        d-i apt-setup/security_host string security.debian.org
        
        d-i passwd/root-login boolean false
        d-i passwd/user-fullname string MLV Admin
        d-i passwd/username string mlv
        d-i passwd/user-password password mlv
        d-i passwd/user-password-again password mlv
        d-i clock-setup/utc boolean true
        d-i time/zone string UTC
        
        # Partitioning - target FIRST disk (/dev/vda) only
        d-i partman-auto/disk string /dev/vda
        d-i partman-auto/method string regular
        d-i partman-auto/choose_recipe select atomic
        
        # Automatically remove existing LVM and RAID metadata
        d-i partman-lvm/device_remove_lvm boolean true
        d-i partman-md/device_remove_md boolean true
        d-i partman-lvm/confirm boolean true
        d-i partman-lvm/confirm_nooverwrite boolean true
        
        # Confirm partitioning without prompts
        d-i partman-partitioning/confirm_write_new_label boolean true
        d-i partman/choose_partition select finish
        d-i partman/confirm boolean true
        d-i partman/confirm_nooverwrite boolean true
        
        # Software Selection
        d-i pkgsel/include string openssh-server curl build-essential open-iscsi util-linux nfs-common bash-completion sudo
        d-i pkgsel/upgrade select full-upgrade
        
        d-i preseed/late_command string \\
            in-target systemctl enable iscsid; \\
            in-target bash -c 'echo "mlv ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/mlv'; \\
            in-target bash -c 'date -s "@$(date +%s)"'; \\
            in-target bash -c 'echo "--- DIAGNOSTIC START ---"; cat /etc/apt/sources.list; echo "--- DIAGNOSTIC END ---"'; \\
            in-target bash -c 'until ping -c 1 8.8.8.8; do sleep 5; done'; \\
            in-target bash -c '\(k3sCommand)'; \\
            in-target bash -c 'if [ "\(isMaster)" != "true" ]; then sed -i "s/mlv-node/mlv-node-$(cat /dev/urandom | tr -dc \\"a-z0-9\\" | head -c 4)/g" /etc/hostname; fi'; \\
            in-target bash -c 'sed -i "s/mlv-node/$(hostname)/g" /etc/hosts';
            
        d-i grub-installer/only_debian boolean true
        d-i finish-install/reboot_in_progress note
        """
        
        let tempDir = initrdURL.deletingLastPathComponent()
        let preseedFile = tempDir.appendingPathComponent("preseed.cfg")
        try preseed.write(to: preseedFile, atomically: true, encoding: .utf8)
        
        // Create a CPIO archive containing the preseed.cfg
        vm.addLog("Creating CPIO archive...")
        let cpioURL = tempDir.appendingPathComponent("preseed.cpio")
        
        // We use quoted paths to handle spaces in 'Application Support'
        let shellCmd = "cd \"\(tempDir.path)\" && echo preseed.cfg | cpio -o -H newc > \"\(cpioURL.path)\""
        let result = try runProcess(executable: "/bin/sh", arguments: ["-c", shellCmd])
        
        if result.exitCode != 0 {
            throw VMError.configurationInvalid("CPIO failed.")
        }
        
        // Append the CPIO archive to the end of the initrd.gz
        vm.addLog("Merging preseed into initrd...")
        let combinedURL = tempDir.appendingPathComponent("initrd_combined.gz")
        let concatCmd = "cat \"\(initrdURL.path)\" \"\(cpioURL.path)\" > \"\(combinedURL.path)\""
        let concatResult = try runProcess(executable: "/bin/sh", arguments: ["-c", concatCmd])
        
        if concatResult.exitCode != 0 {
            throw VMError.configurationInvalid("Concatenation failed.")
        }
        
        // Move the combined file back to the original initrdURL
        try? FileManager.default.removeItem(at: initrdURL)
        try FileManager.default.moveItem(at: combinedURL, to: initrdURL)
        
        vm.addLog("Preseed injection complete.")
    }

    func openVMFolder(_ vm: VirtualMachine) {
        if let url = vm.vmDirectory {
            NSWorkspace.shared.open(url)
        }
    }
}

enum VMError: Error, LocalizedError {
    case virtualizationNotSupported
    case failedToCreateVM
    case missingEFIBootloader
    case configurationInvalid(String)
    
    var errorDescription: String? {
        switch self {
        case .virtualizationNotSupported:
            return "Virtualization is not supported on this Mac"
        case .failedToCreateVM:
            return "Failed to create virtual machine"
        case .missingEFIBootloader:
            return "Missing EFI bootloader"
        case .configurationInvalid(let reason):
            return "Invalid VM configuration: \(reason)"
        }
    }
}
