import Foundation
import Virtualization
import SwiftUI
import Network
import AppKit
import os
import Darwin

@MainActor
@Observable
public final class VMManager {
    public static let shared = VMManager()
    private let logger = Logger(subsystem: "dimense.net.MLV", category: "VMManager")
    var virtualMachines: [VirtualMachine] = []
    
    private var wgControlForwarders: [UUID: UDPPortForwarder] = [:]
    private var wgDataForwarders: [UUID: UDPPortForwarder] = [:]
    private var terminalConsoleServers: [UUID: VMTerminalConsoleServer] = [:]
    private var wgForwarderTargetIP: [UUID: String] = [:]
    private var serialReadPipes: [UUID: Pipe] = [:]
    private let serialWriteQueue = DispatchQueue(label: "dimense.net.MLV.serial-write", qos: .utility)
    private var pendingPollWrites: Set<UUID> = []
    private var pollBuffers: [UUID: String] = [:]
    private var hostProcessCPUSnapshots: [Int: (timestamp: Date, totalCPUSeconds: Double)] = [:]
    private var lastIPAddressDetectionAt: [UUID: Date] = [:]
    private var restartingVMs: Set<UUID> = []
    private var vmPressureStartTimes: [UUID: Date] = [:]
    private var vmPressureNotified: Set<UUID> = []
    private var hostPressureStartTime: Date? = nil
    private var hostPressureNotified = false
    private var knownRemoteNodeIDs: Set<String> = []
    
    // Resource tracking
    var totalAllocatedCPU: Int {
        virtualMachines.filter { $0.state == .running || $0.state == .starting }.reduce(0) { $0 + $1.cpuCount }
}

// Minimal inline HTTP server for serving preseed.cfg to the Debian installer.
fileprivate final class InlinePreseedServer {
    static let shared = InlinePreseedServer()
    private let logger = Logger(subsystem: "dimense.net.MLV", category: "PreseedServer")
    private var listener: NWListener?
    private var preseedData: Data = Data()
    private var port: UInt16 = 8088

    func start(preseed: Data, port: UInt16 = 8088) {
        self.preseedData = preseed
        self.port = port
        if listener != nil { return }
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: .global())
                // Wait for the HTTP request to arrive before sending the response
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    Task { @MainActor in
                        conn.send(content: self.httpResponse(), completion: .contentProcessed { _ in
                            conn.cancel()
                        })
                    }
                }
            }
            listener.start(queue: .global())
            self.listener = listener
            logger.info("Preseed server started on port \(self.port)")
        } catch {
            logger.error("Failed to start preseed server: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func httpResponse() -> Data {
        let header = """
HTTP/1.1 200 OK\r
Content-Type: text/plain\r
Content-Length: \(preseedData.count)\r
Connection: close\r
\r
"""
        var response = Data(header.utf8)
        response.append(preseedData)
        return response
    }
}

    var totalAllocatedMemoryMB: Int {
        virtualMachines.filter { $0.state == .running || $0.state == .starting }.reduce(0) { $0 + $1.memorySizeMB }
    }
    
    var availableCPU: Int {
        max(0, HostResources.cpuCount - totalAllocatedCPU)
    }
    
    var availableMemoryMB: Int {
        max(0, (HostResources.totalMemoryGB * 1024) - totalAllocatedMemoryMB)
    }
    
    // Persistent ISO authorization
    private let isoBookmarkKey = "MLV_ISO_Bookmark"
    private var assignedHostServicePIDs = Set<Int32>()
    
    private var useAppleContainerRuntime: Bool {
        AppSettingsStore.shared.workloadRuntime == .appleContainer
    }
    
    var authorizedISOURL: URL? {
        didSet {
            if let url = authorizedISOURL {
                saveBookmark(for: url)
            }
        }
    }
    
    func getAvailableBridgeInterfaces() -> [VZBridgedNetworkInterface] {
        guard EntitlementChecker.hasEntitlement("com.apple.vm.networking") else {
            return []
        }
        return VZBridgedNetworkInterface.networkInterfaces
    }

    private init() {
        loadBookmark()
        loadStoredVMs()
        startDataPolling()
        startLimitMonitoring()
    }
    
    private func loadStoredVMs() {
        let metadata = VMStatePersistence.shared.loadVMs()
        self.virtualMachines = metadata.compactMap { meta in
            guard let distro = VirtualMachine.LinuxDistro(rawValue: meta.selectedDistro) else { return nil }
            
            // We use a placeholder URL as the actual ISO will be staged/cached if needed
            let placeholderURL = FileManager.default.temporaryDirectory.appendingPathComponent("placeholder.iso")
            
        let vm = VirtualMachine(
            id: meta.id,
            name: meta.name,
            isoURL: placeholderURL,
            cpus: meta.cpuCount,
                ramMB: meta.memorySizeMB,
                sysDiskGB: meta.systemDiskSizeGB,
                dataDiskGB: meta.dataDiskSizeGB
            )
            if let raw = meta.systemDiskProfile, let p = VirtualMachine.DiskProfile(rawValue: raw) {
                vm.systemDiskProfile = p
            }
            if let raw = meta.dataDiskProfile, let p = VirtualMachine.DiskProfile(rawValue: raw) {
                vm.dataDiskProfile = p
            }
            vm.selectedDistro = distro
            vm.isMaster = meta.isMaster
            vm.networkMode = VMNetworkMode(rawValue: meta.networkMode ?? VMNetworkMode.nat.rawValue) ?? .nat
            vm.bridgeInterfaceName = meta.bridgeInterfaceName
            vm.secondaryNetworkEnabled = meta.secondaryNetworkEnabled ?? false
            vm.secondaryNetworkMode = VMNetworkMode(rawValue: meta.secondaryNetworkMode ?? VMNetworkMode.nat.rawValue) ?? .nat
            vm.secondaryBridgeInterfaceName = meta.secondaryBridgeInterfaceName
        vm.monitoredProcessPID = meta.monitoredProcessPID ?? 1
        vm.monitoredProcessName = meta.monitoredProcessName ?? ""
        vm.stage = VMStage(rawValue: meta.stage) ?? vm.stage
        vm.isContainerWorkload = meta.isContainerWorkload ?? false
            if meta.isInstalled {
                vm.isInstalled = true
            }
            vm.clusterRole = VMClusterRole(rawValue: meta.clusterRole ?? VMClusterRole.node.rawValue) ?? .node
            vm.wgControlPrivateKeyBase64 = meta.wgControlPrivateKeyBase64
            vm.wgControlPublicKeyBase64 = meta.wgControlPublicKeyBase64
            vm.wgControlAddressCIDR = meta.wgControlAddressCIDR
            vm.wgControlListenPort = meta.wgControlListenPort ?? vm.wgControlListenPort
            vm.wgControlHostForwardPort = meta.wgControlHostForwardPort ?? vm.wgControlHostForwardPort
            vm.wgDataPrivateKeyBase64 = meta.wgDataPrivateKeyBase64
            vm.wgDataPublicKeyBase64 = meta.wgDataPublicKeyBase64
            vm.wgDataAddressCIDR = meta.wgDataAddressCIDR
            vm.wgDataListenPort = meta.wgDataListenPort ?? vm.wgDataListenPort
            vm.wgDataHostForwardPort = meta.wgDataHostForwardPort ?? vm.wgDataHostForwardPort
            vm.autoStartOnLaunch = meta.autoStartOnLaunch ?? false
            vm.containerImageReference = meta.containerImageReference ?? ""
            vm.containerMounts = meta.containerMounts ?? []
            vm.containerPorts = meta.containerPorts ?? []
            vm.hostServicePID = meta.hostServicePID
            if let pid = vm.hostServicePID {
                assignedHostServicePIDs.insert(Int32(pid))
            }
            return vm
        }
    }

    func refreshBackgroundExecution() {
        let wants = AppSettingsStore.shared.preventSleepWhileVMRunning
        let running = virtualMachines.contains { $0.state == .running || $0.state == .starting }
        BackgroundExecutionManager.shared.setActive(wants && running)
    }

    func handleRuntimeModeChange() async {
        do {
            if useAppleContainerRuntime {
                try AppleContainerService.shared.ensureSystemRunning()
                AppNotifications.shared.notify(
                    id: "container-runtime-enabled",
                    title: "Container Runtime Enabled",
                    body: "Apple container system is running and available machine-wide."
                )
            } else {
                AppNotifications.shared.notify(
                    id: "vm-runtime-enabled",
                    title: "VM Runtime Enabled",
                    body: "Switched back to Virtualization.framework runtime."
                )
            }
        } catch {
            AppNotifications.shared.notify(
                id: "container-runtime-error",
                title: "Container Runtime Error",
                body: error.localizedDescription
            )
            Logger(subsystem: "dimense.net.MLV", category: "VMManager").error("Runtime mode switch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func isAppleContainerToolInstalled() -> Bool {
        AppleContainerService.shared.isInstalled
    }

    func installOrUpdateAppleContainerTool() async throws {
        try await AppleContainerService.shared.installOrUpdateFromOfficialRelease()
    }

    func listContainerImages() async throws -> [ContainerImageInfo] {
        try await AppleContainerService.shared.listContainerImages()
    }

    func pullContainerImage(reference: String) async throws {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VMError.configurationInvalid("Image reference cannot be empty.")
        }
        try await AppleContainerService.shared.pullImageAsync(reference: trimmed)
    }

    func pullContainerImage(
        reference: String,
        onProgress: @escaping @MainActor (_ progress: Double, _ detail: String) -> Void
    ) async throws {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VMError.configurationInvalid("Image reference cannot be empty.")
        }
        try await AppleContainerService.shared.pullImage(reference: trimmed) { progress, detail in
            Task { @MainActor in
                onProgress(progress, detail)
            }
        }
    }

    func deleteContainerImage(reference: String) async throws {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await AppleContainerService.shared.deleteImageAsync(reference: trimmed)
    }
    
    func autoStartVMsIfNeeded() {
        Task { @MainActor in
            logger.info("Initializing autostart sequence...")
            // Give launch-time services and VM metadata a moment to settle.
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            for attempt in 1...2 {
                let allTargets = self.virtualMachines.filter { $0.autoStartOnLaunch }
                let targets = allTargets.filter {
                    (self.useAppleContainerRuntime || $0.isInstalled) &&
                    !$0.state.isRunning &&
                    $0.state != .starting
                }
                
                if allTargets.isEmpty { break }
                if targets.isEmpty {
                    logger.info("Autostart: No eligible targets out of \(allTargets.count) flagged VMs.")
                    break
                }

                logger.info("Autostart attempt \(attempt): triggering \(targets.count) VMs.")
                for vm in targets {
                    do {
                        try await self.startVM(vm)
                        vm.addLog("Autostart successful on attempt \(attempt).")
                        logger.info("Autostart succeeded for \(vm.name)")
                    } catch {
                        vm.addLog("Autostart attempt \(attempt) failed: \(error.localizedDescription)", isError: true)
                        logger.error("Autostart failed for \(vm.name): \(error.localizedDescription)")
                    }
                    // Stagger starts to prevent resource spikes
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }

                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            logger.info("Autostart sequence completed.")
        }
    }
    
    private func startDataPolling() {
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                if self.useAppleContainerRuntime {
                    self.updateContainerStats()
                }
                for vm in self.virtualMachines where vm.state == .running {
                    self.updateDetectedIPAddress(for: vm)
                    if vm.isContainerWorkload {
                        // Container workloads get metrics from AppleContainerService stats.
                    } else {
                        self.pollVMData(vm)
                        self.applyHostUsageFallbackIfNeeded(for: vm)
                    }
                    self.evaluateVMHealth(vm)
                }
                self.evaluateLimitAlerts()
            }
        }
    }

    private func updateContainerStats() {
        Task {
            do {
                let stats = try await AppleContainerService.shared.getStats()
                await MainActor.run {
                    for stat in stats {
                        if let vm = self.virtualMachines.first(where: { candidate in
                            guard candidate.isContainerWorkload else { return false }
                            // Match by canonical name, VM display name, or UUID prefix to tolerate CLI naming differences.
                            let canon = self.containerName(for: candidate)
                            return stat.id == canon
                                || stat.id == candidate.name
                                || stat.id.hasPrefix(candidate.id.uuidString.prefix(8))
                        }) {
                            vm.guestCPUUsagePercent = Int(stat.cpuPercentage)
                            vm.guestMemoryUsagePercent = Int(stat.memoryPercentage)
                            vm.hasGuestUsageSample = true
                            vm.lastHealthyPoll = Date()
                        }
                    }
                }
            } catch {
                Logger(subsystem: "dimense.net.MLV", category: "VMManager").error("Failed to poll container stats: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func startLimitMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task { @MainActor in
                self.evaluateLimitAlerts()
            }
        }
    }
    
    private func pollVMData(_ vm: VirtualMachine) {
        guard let pipe = vm.serialWritePipe else { return }
        guard pendingPollWrites.insert(vm.id).inserted else { return }

        let pollCmd = VMTelemetryService.shared.generatePollCommand(for: vm)
        guard let data = (pollCmd + "\n").data(using: .utf8) else {
            pendingPollWrites.remove(vm.id)
            return
        }

        let handle = pipe.fileHandleForWriting
        let vmID = vm.id
        serialWriteQueue.async { [handle, data, vmID] in
            try? handle.write(contentsOf: data)
            Task { @MainActor in
                VMManager.shared.pendingPollWrites.remove(vmID)
            }
        }
    }
    
    // Fallback when guest telemetry isn't available (e.g., early boot or missing cloud-init).
    // Uses host-side process metrics for the captured virtualization helper PID.
    private func applyHostUsageFallbackIfNeeded(for vm: VirtualMachine) {
        // Once guest CPU ticks arrive, prefer guest telemetry and skip host-derived estimates.
        guard vm.lastGuestCPUTotalTicks == nil else { return }
        
        // Ensure the recorded helper PID is still alive; if not, clear and wait for next detection.
        if let helperPID = vm.hostServicePID, !isProcessAlive(helperPID) {
            hostProcessCPUSnapshots[helperPID] = nil
            vm.hostServicePID = nil
            vm.hasGuestUsageSample = false
        }
        
        let pid = vm.hostServicePID ?? vm.monitoredProcessPID
        guard pid > 1, isProcessAlive(pid) else {
            vm.hasGuestUsageSample = false
            return
        }
        
        guard let sample = hostProcessUsageSample(pid: pid, guestMemoryMB: vm.memorySizeMB) else {
            vm.hasGuestUsageSample = false
            return
        }
        
        vm.guestCPUUsagePercent = sample.cpuPercent
        vm.guestMemoryUsagePercent = sample.memPercent
        vm.hasGuestUsageSample = true
    }

    private func isProcessAlive(_ pid: Int) -> Bool {
        let result = kill(pid_t(pid), 0)
        if result == 0 { return true }
        return errno == EPERM // Exists but not permitted
    }
    
    private func hostProcessUsageSample(pid: Int, guestMemoryMB: Int) -> (cpuPercent: Int, memPercent: Int)? {
        var info = rusage_info_current()
        // proc_pid_rusage expects a pointer to rusage_info_t?, which itself is a pointer type.
        // Rebind the stack struct's pointer to match the expected double-pointer signature.
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid_t(pid), RUSAGE_INFO_CURRENT, reboundPtr)
            }
        }
        guard result == 0 else { return nil }
        
        let totalCPUSeconds = Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000.0
        let now = Date()
        
        let memBytes = Double(info.ri_resident_size)
        let memPercent = Int(min(100, max(0, (memBytes / (Double(guestMemoryMB) * 1024.0 * 1024.0)) * 100.0)))
        
        if let last = hostProcessCPUSnapshots[pid], now.timeIntervalSince(last.timestamp) > 0.5, totalCPUSeconds >= last.totalCPUSeconds {
            let deltaCPU = totalCPUSeconds - last.totalCPUSeconds
            let deltaT = now.timeIntervalSince(last.timestamp)
            guard deltaT > 0 else { return nil }
            let cpuPercent = Int(min(400, max(0, (deltaCPU / deltaT) * 100.0)))
            hostProcessCPUSnapshots[pid] = (now, totalCPUSeconds)
            return (cpuPercent, memPercent)
        } else {
            hostProcessCPUSnapshots[pid] = (now, totalCPUSeconds)
            return nil
        }
    }
    
    private func evaluateVMHealth(_ vm: VirtualMachine) {
        guard vm.state == .running, vm.isInstalled else { return }
        
        // Trigger provisioning if needed
        VMProvisioningService.shared.provisionIfNeeded(vm)
        
        guard let last = vm.lastHealthyPoll else { return }
        if Date().timeIntervalSince(last) < 90 { return }
        if vm.userInitiatedStop { return }
        if restartingVMs.contains(vm.id) { return }
        
        restartingVMs.insert(vm.id)
        vm.addLog("Health check timeout. Attempting recovery...", isError: true)
        Task { @MainActor in
            defer { self.restartingVMs.remove(vm.id) }
            do {
                try await self.restartVM(vm)
            } catch {
                vm.addLog("Recovery restart failed: \(error.localizedDescription)", isError: true)
            }
        }
    }
    
    func createLinuxVM(
        name: String? = nil,
        cpus: Int = 4,
        ramMB: Int = 4096,
        sysDiskGB: Int = 64,
        dataDiskGB: Int = 100,
        isMaster: Bool = false,
        distro: VirtualMachine.LinuxDistro = .debian13,
        containerImageReference: String? = nil,
        containerMounts: [VirtualMachine.ContainerMount] = [],
        containerPorts: [VirtualMachine.ContainerPort] = [],
        networkMode: VMNetworkMode = .nat,
        bridgeInterfaceName: String? = nil,
        secondaryNetworkEnabled: Bool = false,
        secondaryNetworkMode: VMNetworkMode = .nat,
        secondaryBridgeInterfaceName: String? = nil,
        zeroTouch: Bool = false
    ) async throws -> VirtualMachine {
        if !useAppleContainerRuntime && !VZVirtualMachine.isSupported {
            throw VMError.virtualizationNotSupported
        }
        
        let vmName = name ?? (useAppleContainerRuntime ? "container-\(virtualMachines.count + 1)" : "Node \(virtualMachines.count + 1)")
        let placeholderURL = FileManager.default.temporaryDirectory.appendingPathComponent("placeholder.iso")
        
        let vm = VirtualMachine(name: vmName, isoURL: placeholderURL, cpus: cpus, ramMB: ramMB, sysDiskGB: sysDiskGB, dataDiskGB: dataDiskGB)
        vm.isMaster = isMaster
        vm.selectedDistro = distro
        vm.networkMode = networkMode
        vm.bridgeInterfaceName = (networkMode == .bridge) ? VMNetworkService.shared.resolveBridgeInterface(preferred: bridgeInterfaceName) : nil
        vm.secondaryNetworkEnabled = secondaryNetworkEnabled
        vm.secondaryNetworkMode = secondaryNetworkMode
        vm.secondaryBridgeInterfaceName = (secondaryNetworkEnabled && secondaryNetworkMode == .bridge) ? VMNetworkService.shared.resolveBridgeInterface(preferred: secondaryBridgeInterfaceName) : nil
        vm.monitoredProcessPID = Int.random(in: 100...999_999)
        vm.monitoredProcessName = autoPattern(for: vm.name)
        vm.clusterRole = isMaster ? .master : .node
        vm.zeroTouchInstall = zeroTouch
        if useAppleContainerRuntime {
            vm.containerImageReference = containerImageReference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            vm.containerMounts = containerMounts
            vm.containerPorts = containerPorts
            vm.isInstalled = true
            vm.stage = .installed
            vm.isContainerWorkload = true
        } else {
            vm.isContainerWorkload = false
        }
        
        let (controlPorts, dataPorts) = VMNetworkService.shared.allocateWireGuardPorts(for: vm.id)
        vm.wgControlListenPort = 51820
        vm.wgDataListenPort = 51821
        vm.wgControlHostForwardPort = controlPorts
        vm.wgDataHostForwardPort = dataPorts
        vm.terminalConsoleHostPort = 20000 + (Int(vm.id.uuidString.suffix(4), radix: 16) ?? Int.random(in: 0...9999)) % 20000
        
        if vm.wgControlPrivateKeyBase64 == nil || vm.wgControlPublicKeyBase64 == nil {
            let kp = WireGuardKeyUtils.generateKeypairBase64()
            vm.wgControlPrivateKeyBase64 = kp.privateKey
            vm.wgControlPublicKeyBase64 = kp.publicKey
        }
        if vm.wgDataPrivateKeyBase64 == nil || vm.wgDataPublicKeyBase64 == nil {
            let kp = WireGuardKeyUtils.generateKeypairBase64()
            vm.wgDataPrivateKeyBase64 = kp.privateKey
            vm.wgDataPublicKeyBase64 = kp.publicKey
        }
        
        let octet = VMNetworkService.shared.allocateWireGuardOctet(for: vm.id, preferred: isMaster ? 1 : nil)
        vm.wgControlAddressCIDR = "10.13.0.\(octet)/24"
        vm.wgDataAddressCIDR = "10.13.1.\(octet)/24"
        
        self.virtualMachines.append(vm)
        VMStatePersistence.shared.saveVMs(self.virtualMachines)
        seedDebianAutomationIfNeeded(for: vm)
        
        do {
            try await startVM(vm)
        } catch {
            vm.state = .error(error.localizedDescription)
            throw error
        }
        return vm
    }

    private func allocateWireGuardPorts(for id: UUID) -> (Int, Int) {
        let suffix = Int(id.uuidString.suffix(4), radix: 16) ?? Int.random(in: 0...9999)
        let control = 30000 + (suffix % 10000)
        let data = 40000 + (suffix % 10000)
        return (control, data)
    }
    
    private func allocateWireGuardOctet(for id: UUID, preferred: Int?) -> Int {
        if let preferred { return preferred }
        let suffix = Int(id.uuidString.suffix(2), radix: 16) ?? Int.random(in: 10...250)
        let octet = (suffix % 220) + 10
        return octet
    }
    
    private func seedDebianAutomationIfNeeded(for vm: VirtualMachine) {
        guard vm.selectedDistro == .debian13 else { return }
        guard let sharedDir = try? VMStorageManager.shared.ensureVMSharedDirectoryExists(for: vm.id) else { return }
        let preseed = debianPreseed()
        let sources = """
        deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
        deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
        deb http://security.debian.org/ trixie-security main contrib non-free non-free-firmware
        """
        let script = """
        #!/bin/sh
        set -e
        MOUNTPOINT=/mnt/mlvshare
        SUDO=""
        if [ "$(id -u)" -ne 0 ]; then
          SUDO="sudo"
        fi

        echo "Ensuring virtiofs shared folder is mounted at $MOUNTPOINT ..."
        $SUDO mkdir -p "$MOUNTPOINT"
        if ! grep -q "^mlvshare\\s" /etc/fstab; then
          echo "mlvshare $MOUNTPOINT virtiofs defaults 0 0" | $SUDO tee -a /etc/fstab >/dev/null
        fi
        $SUDO mount "$MOUNTPOINT" || $SUDO mount -a || true

        echo "Writing Debian sources.list with deb.debian.org mirrors..."
        $SUDO cp "$MOUNTPOINT/sources.list" /etc/apt/sources.list
        $SUDO apt-get update || true
        echo "Installing spice-vdagent for clipboard..."
        $SUDO apt-get install -y spice-vdagent || true
        echo "Done. Reboot to enable clipboard sharing and keep the share mounted."
        """
        do {
            try sources.trimmingCharacters(in: .whitespacesAndNewlines)
                .appending("\n")
                .write(to: sharedDir.appendingPathComponent("sources.list"), atomically: true, encoding: .utf8)
            try script
                .write(to: sharedDir.appendingPathComponent("fix-apt.sh"), atomically: true, encoding: .utf8)
            try preseed
                .write(to: sharedDir.appendingPathComponent("preseed.cfg"), atomically: true, encoding: .utf8)
            InlinePreseedServer.shared.start(preseed: Data(preseed.utf8))
            vm.addLog("Preseed server ready: http://192.168.64.1:8088/preseed.cfg (append to installer boot args)")
        } catch {
            logger.error("Failed to seed Debian mirror helper files: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func debianPreseed() -> String {
        """
        d-i debian-installer/locale string en_US.UTF-8
        d-i console-setup/ask_detect boolean false
        d-i console-setup/layoutcode string us
        d-i keyboard-configuration/xkb-keymap select us
        d-i time/zone string UTC
        d-i clock-setup/utc boolean true
        d-i netcfg/choose_interface select auto
        d-i mirror/country string manual
        d-i mirror/http/hostname string deb.debian.org
        d-i mirror/http/directory string /debian
        d-i mirror/suite string trixie
        d-i mirror/http/proxy string
        d-i apt-setup/non-free boolean true
        d-i apt-setup/contrib boolean true
        d-i passwd/root-login boolean true
        d-i passwd/root-password password root
        d-i passwd/root-password-again password root
        d-i user-setup/allow-password-weak boolean true
        d-i partman-auto/disk string /dev/vda
        d-i partman-auto/method string lvm
        d-i partman-lvm/device_remove_lvm boolean true
        d-i partman-md/device_remove_md boolean true
        d-i partman-auto/choose_recipe select atomic
        d-i partman/confirm_write_new_label boolean true
        d-i partman/confirm boolean true
        d-i partman/confirm_nooverwrite boolean true
        tasksel/first multiselect standard, ssh-server
        popcon/participate boolean false
        d-i pkgsel/include string spice-vdagent openssh-server curl
        d-i finish-install/reboot_in_progress note
        """
    }

    func startVM(_ vm: VirtualMachine) async throws {
        try await VMLifecycleManager.shared.performOperation(for: vm.id) {
            try await self._startVMInternal(vm)
        }
    }

    private func _startVMInternal(_ vm: VirtualMachine) async throws {
        if vm.state == .starting || vm.state == .running { return }
        
        vm.addLog("Starting Virtual Machine: \(vm.name)")
        vm.state = .starting
        vm.ipAddress = "Detecting..."
        vm.isConnected = false
        refreshBackgroundExecution()

        if useAppleContainerRuntime {
            do {
                try AppleContainerService.shared.ensureSystemRunning()
                let image = containerImage(for: vm)
                try await AppleContainerService.shared.pullImageAsync(reference: image)
                let message = try await AppleContainerService.shared.startWorkload(
                    name: containerName(for: vm),
                    image: image,
                    cpus: vm.cpuCount,
                    memoryMB: vm.memorySizeMB,
                    mounts: vm.containerMounts,
                    ports: vm.containerPorts
                )
                vm.addLog(message)
                vm.isInstalled = true
                vm.stage = .running
                vm.state = .running
                vm.lastHealthyPoll = Date()
                refreshBackgroundExecution()
                return
            } catch {
                vm.addLog("Container start failed: \(error.localizedDescription)", isError: true)
                vm.state = .error(error.localizedDescription)
                refreshBackgroundExecution()
                throw error
            }
        }
        
        do {
            if let existing = vm.vzVirtualMachine {
                try? await existing.stop()
                vm.vzVirtualMachine = nil
                vm.vzDelegate = nil
            }
            
            let vmDir = try VMStorageManager.shared.ensureVMDirectoryExists(for: vm.id)
            
            if !vm.isInstalled {
                vm.addLog("PHASE 1: INSTALL MODE - Preparing installer...")
                let cacheDir = try VMStorageManager.shared.getISOCacheDirectory()
                let cachedISOURL = try await ensureCachedInstallerISO(for: vm, cacheDir: cacheDir)
                let stagedISOURL = vmDir.appendingPathComponent("installer.iso")
                
                vm.addLog("Staging ISO to VM storage (clean copy)...")
                try streamCopy(from: cachedISOURL, to: stagedISOURL)
                
                vm.needsUserInteraction = true
                vm.stage = .installing
            } else {
                vm.addLog("PHASE 2: RUN MODE - Booting from disk.")
            }

            let configuration = try await VMConfigurationBuilder.shared.build(for: vm)
            
            // Setup Serial Console
            let consoleDevice = VZVirtioConsoleDeviceConfiguration()
            let portConfig = VZVirtioConsolePortConfiguration()
            let readPipe = Pipe()
            let writePipe = Pipe()
            portConfig.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: readPipe.fileHandleForReading,
                fileHandleForWriting: writePipe.fileHandleForWriting
            )
            
            // Port 0: serial console for polling/logs.
            // Port 1: SPICE agent for clipboard sharing (requires spice-vdagent in guest).
            var portCount: UInt32 = 1
            if #available(macOS 14.0, *) {
                let spicePort = VZVirtioConsolePortConfiguration()
                let spiceAttachment = VZSpiceAgentPortAttachment()
                spiceAttachment.sharesClipboard = true
                spicePort.attachment = spiceAttachment
                consoleDevice.ports[1] = spicePort
                portCount = 2
            }
            consoleDevice.ports.maximumPortCount = portCount
            configuration.consoleDevices = [consoleDevice]
            
            vm.serialWritePipe = writePipe
            serialReadPipes[vm.id] = readPipe
            setupSerialPortListener(for: vm, readPipe: readPipe)
            startTerminalConsoleIfNeeded(for: vm, writePipe: writePipe)

            try configuration.validate()

            let v = VZVirtualMachine(configuration: configuration, queue: .main)
            let delegate = VMRuntimeDelegate(vm: vm)
            v.delegate = delegate
            vm.vzVirtualMachine = v
        vm.vzDelegate = delegate
        
        try await v.start()
        vm.state = .running
        vm.addLog("Virtualization engine started.")
        captureHostServicePID(for: vm)
        refreshBackgroundExecution()
        updateDetectedIPAddress(for: vm)
            pollVMData(vm)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.updateDetectedIPAddress(for: vm)
                self.pollVMData(vm)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.updateDetectedIPAddress(for: vm)
                self.pollVMData(vm)
            }
            
        } catch {
            vm.addLog("Start failed: \(error.localizedDescription)", isError: true)
            vm.state = .error(error.localizedDescription)
            refreshBackgroundExecution()
            throw error
        }
    }
    
    private func setupSerialPortListener(for vm: VirtualMachine, readPipe: Pipe) {
        readPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            
            if let str = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self.terminalConsoleServers[vm.id]?.sendToClient(data)
                    vm.consoleOutput.append(str)
                    if vm.consoleOutput.count > 100000 {
                        vm.consoleOutput = String(vm.consoleOutput.suffix(50000))
                    }
                    self.processConsoleChunk(str, for: vm)
                }
            }
        }
    }
    
    private func processConsoleChunk(_ chunk: String, for vm: VirtualMachine) {
        vm.lastConsoleActivity = Date()
        
        var buffer = pollBuffers[vm.id, default: ""]
        buffer.append(chunk)
        if buffer.count > 400000 {
            buffer = String(buffer.suffix(200000))
        }
        
        while let startRange = buffer.range(of: "---POLL_START---"),
              let endRange = buffer.range(of: "---POLL_END---", range: startRange.upperBound..<buffer.endIndex) {
            let block = String(buffer[startRange.lowerBound..<endRange.upperBound])
            parsePollingData(block, for: vm)
            vm.lastHealthyPoll = Date()
            buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
        }
        
        pollBuffers[vm.id] = buffer
    }
    
    private func startTerminalConsoleIfNeeded(for vm: VirtualMachine, writePipe: Pipe) {
        if terminalConsoleServers[vm.id] != nil { return }
        if vm.terminalConsoleHostPort <= 0 { return }
        
        do {
            let server = try VMTerminalConsoleServer(
                port: vm.terminalConsoleHostPort,
                initialData: { Data(vm.consoleOutput.utf8) },
                onConnect: { vm.addLog("Terminal attached on 127.0.0.1:\(vm.terminalConsoleHostPort)") },
                writeToVM: { data in
                    try? writePipe.fileHandleForWriting.write(contentsOf: data)
                }
            )
            try server.start()
            terminalConsoleServers[vm.id] = server
            vm.addLog("Terminal console listening on 127.0.0.1:\(vm.terminalConsoleHostPort) (use: nc 127.0.0.1 \(vm.terminalConsoleHostPort))")
        } catch {
            vm.addLog("Failed to start terminal console: \(error.localizedDescription)", isError: true)
        }
    }

    // --- Private Helpers (Bookmark, Download, Extract, etc.) ---
    
    private func parsePollingData(_ output: String, for vm: VirtualMachine) {
        guard let startRange = output.range(of: "---POLL_START---"),
              let endRange = output.range(of: "---POLL_END---") else { return }
        
        let rawContent = output[startRange.upperBound..<endRange.lowerBound]
        applyGuestUsage(from: String(rawContent), to: vm)
        var lines = rawContent.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let podsLines = VMPollingParser.extractSectionLines(
            from: &lines,
            startMarker: "---PODS_START---",
            endMarker: "---PODS_END---"
        )
        let containerLines = VMPollingParser.extractSectionLines(
            from: &lines,
            startMarker: "---CONTAINERS_START---",
            endMarker: "---CONTAINERS_END---"
        )
        lines = stripGuestUsageMarkers(from: lines)
        vm.pods = VMPollingParser.parsePods(from: podsLines)
        vm.containers = VMPollingParser.parseContainers(from: containerLines)
        
        if let ipLine = lines.first, !ipLine.isEmpty {
            vm.ipAddress = ipLine
            vm.isConnected = true
        }
        if lines.count >= 3 {
            vm.gateway = lines[1]
            vm.dns = lines[2].components(separatedBy: " ")
            ensureWireGuardForwarders(for: vm)
        }
    }

    private func stripGuestUsageMarkers(from lines: [String]) -> [String] {
        guard
            let startIndex = lines.firstIndex(where: { $0.contains("---VM_USAGE_START---") }),
            let endIndex = lines[startIndex...].firstIndex(where: { $0.contains("---VM_USAGE_END---") }),
            endIndex >= startIndex
        else {
            return lines
        }

        var trimmed = lines
        trimmed.removeSubrange(startIndex...endIndex)
        return trimmed
    }

    private func applyGuestUsage(from usageBlock: String, to vm: VirtualMachine) {
        guard vm.state == .running else { return }
        let previousTotalTicks = vm.lastGuestCPUTotalTicks
        var currentTotalTicks: UInt64?
        var currentMemTotalKB: Int?

        if let cpuValues = captureInts(in: usageBlock, pattern: #"CPU_TICKS\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)"#),
           cpuValues.count >= 8 {
            let user = UInt64(cpuValues[0])
            let nice = UInt64(cpuValues[1])
            let system = UInt64(cpuValues[2])
            let idle = UInt64(cpuValues[3])
            let iowait = UInt64(cpuValues[4])
            let irq = UInt64(cpuValues[5])
            let softirq = UInt64(cpuValues[6])
            let steal = UInt64(cpuValues[7])

            let total = user + nice + system + idle + iowait + irq + softirq + steal
            let idleTotal = idle + iowait
            currentTotalTicks = total

            if let previousTotal = vm.lastGuestCPUTotalTicks,
               let previousIdle = vm.lastGuestCPUIdleTicks,
               total > previousTotal,
               idleTotal >= previousIdle {
                let totalDelta = total - previousTotal
                let idleDelta = idleTotal - previousIdle
                if totalDelta > 0 {
                    let busyDelta = totalDelta - idleDelta
                    let usage = Int((Double(busyDelta) / Double(totalDelta)) * 100.0)
                    vm.guestCPUUsagePercent = min(100, max(0, usage))
                    vm.hasGuestUsageSample = true
                }
            }

            vm.lastGuestCPUTotalTicks = total
            vm.lastGuestCPUIdleTicks = idleTotal
        }

        if let memValues = captureInts(in: usageBlock, pattern: #"MEM_KB\s+(\d+)\s+(\d+)"#), memValues.count >= 2 {
            let totalKB = memValues[0]
            let availableKB = memValues[1]
            currentMemTotalKB = totalKB
            if totalKB > 0 {
                let used = totalKB - max(0, availableKB)
                let usage = Int((Double(used) / Double(totalKB)) * 100.0)
                vm.guestMemoryUsagePercent = min(100, max(0, usage))
                vm.hasGuestUsageSample = true
            }
        }

        if let diskValues = captureInts(in: usageBlock, pattern: #"DISK_PCT\s+(\d+)"#), let disk = diskValues.first {
            vm.guestDiskUsagePercent = min(100, max(0, disk))
            vm.hasGuestUsageSample = true
        }

        // PID-based process telemetry (preferred when available).
        if let pidTickValues = captureInts(in: usageBlock, pattern: #"PID_TICKS\s+(\d+)\s+(\d+)"#), pidTickValues.count >= 2 {
            let processTicks = UInt64(pidTickValues[0] + pidTickValues[1])
            if let previousProcessTicks = vm.lastMonitoredProcessTicks,
               let previousTotalTicks,
               let currentTotalTicks,
               currentTotalTicks > previousTotalTicks,
               processTicks >= previousProcessTicks {
                let deltaProcess = processTicks - previousProcessTicks
                let deltaTotal = currentTotalTicks - previousTotalTicks
                if deltaTotal > 0 {
                    let usage = Int((Double(deltaProcess) / Double(deltaTotal)) * 100.0)
                    vm.guestCPUUsagePercent = min(100, max(0, usage))
                    vm.hasGuestUsageSample = true
                }
            }
            vm.lastMonitoredProcessTicks = processTicks
        }

        if let selectedPID = captureInts(in: usageBlock, pattern: #"PID_SELECTED\s+(\d+)"#)?.first, selectedPID > 1 {
            vm.monitoredProcessPID = selectedPID
        }

        if let pidRSS = captureInts(in: usageBlock, pattern: #"PID_RSS_KB\s+(\d+)"#)?.first,
           let totalKB = currentMemTotalKB,
           totalKB > 0,
           pidRSS > 0 {
            let usage = Int((Double(pidRSS) / Double(totalKB)) * 100.0)
            vm.guestMemoryUsagePercent = min(100, max(0, usage))
            vm.hasGuestUsageSample = true
        }

        // Fallback parser for raw proc/df lines when awk-based formatted lines are missing.
        if !vm.hasGuestUsageSample {
            if let rawCPU = captureInts(in: usageBlock, pattern: #"(?m)^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)"#),
               rawCPU.count >= 8 {
                let total = rawCPU.reduce(0, +)
                let idleTotal = rawCPU[3] + rawCPU[4]
                if let previousTotal = vm.lastGuestCPUTotalTicks,
                   let previousIdle = vm.lastGuestCPUIdleTicks,
                   UInt64(total) > previousTotal,
                   UInt64(idleTotal) >= previousIdle {
                    let totalDelta = UInt64(total) - previousTotal
                    let idleDelta = UInt64(idleTotal) - previousIdle
                    if totalDelta > 0 {
                        let busyDelta = totalDelta - idleDelta
                        let usage = Int((Double(busyDelta) / Double(totalDelta)) * 100.0)
                        vm.guestCPUUsagePercent = min(100, max(0, usage))
                        vm.hasGuestUsageSample = true
                    }
                }
                vm.lastGuestCPUTotalTicks = UInt64(total)
                vm.lastGuestCPUIdleTicks = UInt64(idleTotal)
                currentTotalTicks = UInt64(total)
            }

            let memTotal = captureInts(in: usageBlock, pattern: #"MemTotal:\s+(\d+)"#)?.first ?? 0
            let memAvail = captureInts(in: usageBlock, pattern: #"MemAvailable:\s+(\d+)"#)?.first ?? 0
            if memTotal > 0 {
                currentMemTotalKB = memTotal
                let used = memTotal - max(0, memAvail)
                let usage = Int((Double(used) / Double(memTotal)) * 100.0)
                vm.guestMemoryUsagePercent = min(100, max(0, usage))
                vm.hasGuestUsageSample = true
            }

            if let rawDisk = captureInts(in: usageBlock, pattern: #"(?m)^\S+\s+\d+\s+\d+\s+\d+\s+(\d+)%\s+/"#)?.first {
                vm.guestDiskUsagePercent = min(100, max(0, rawDisk))
                vm.hasGuestUsageSample = true
            }
        }
    }

    // Associate the shared host helper process (Virtual Machine Service for MLV) with a VM instance.
    private func captureHostServicePID(for vm: VirtualMachine) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "Virtual Machine Service for MLV" }
        guard !apps.isEmpty else { return }
        let candidates = apps.map { $0.processIdentifier }
        let unassigned = candidates.filter { !assignedHostServicePIDs.contains($0) }
        let pid = unassigned.first ?? candidates.first
        if let pid, vm.hostServicePID == nil {
            vm.hostServicePID = Int(pid)
            assignedHostServicePIDs.insert(pid)
            vm.addLog("Associated host VM service PID \(pid).")
            vm.persist()
        }
    }

    private func captureInts(in text: String, pattern: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        var values: [Int] = []
        for index in 1..<match.numberOfRanges {
            let capture = match.range(at: index)
            guard let swiftRange = Range(capture, in: text) else { return nil }
            values.append(Int(text[swiftRange]) ?? 0)
        }
        return values
    }

    private func autoPattern(for vmName: String) -> String {
        "mlv-" + vmName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    private func containerName(for vm: VirtualMachine) -> String {
        let prefix = String(vm.id.uuidString.lowercased().prefix(8))
        return "mlv-\(prefix)"
    }

    private func containerImage(for vm: VirtualMachine) -> String {
        let explicit = vm.containerImageReference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }
        switch vm.selectedDistro {
        case .debian13:
            return "debian:latest"
        case .alpine:
            return "alpine:latest"
        case .ubuntu:
            return "ubuntu:24.04"
        case .minimal:
            return "busybox:latest"
        }
    }

    private func shellSingleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func evaluateLimitAlerts() {
        AppNotifications.shared.requestIfNeeded()
        let now = Date()

        for vm in virtualMachines where vm.state == .running {
            let isUnderPressure = vm.hasGuestUsageSample &&
                (vm.guestCPUUsagePercent >= 90 || vm.guestMemoryUsagePercent >= 90 || vm.guestDiskUsagePercent >= 90)

            if isUnderPressure {
                let start = vmPressureStartTimes[vm.id] ?? now
                vmPressureStartTimes[vm.id] = start
                if !vmPressureNotified.contains(vm.id), now.timeIntervalSince(start) >= 60 {
                    let reasons = [
                        vm.guestCPUUsagePercent >= 90 ? "CPU \(vm.guestCPUUsagePercent)%" : nil,
                        vm.guestMemoryUsagePercent >= 90 ? "RAM \(vm.guestMemoryUsagePercent)%" : nil,
                        vm.guestDiskUsagePercent >= 90 ? "Disk \(vm.guestDiskUsagePercent)%" : nil
                    ]
                        .compactMap { $0 }
                        .joined(separator: ", ")
                    AppNotifications.shared.notify(
                        id: "vm-pressure-\(vm.id.uuidString)",
                        title: "VM Resource Pressure",
                        body: "\(vm.name) is near limit for over 1 minute (\(reasons))."
                    )
                    vmPressureNotified.insert(vm.id)
                }
            } else {
                vmPressureStartTimes[vm.id] = nil
                vmPressureNotified.remove(vm.id)
            }
        }

        let totalAllocatedCPU = virtualMachines.filter { $0.state == .running }.reduce(0) { $0 + $1.cpuCount }
        let totalAllocatedMemoryGB = virtualMachines.filter { $0.state == .running }.reduce(0) { $0 + $1.memorySizeMB } / 1024
        let hostCPUThreshold = max(1, Int(Double(HostResources.cpuCount) * 0.9))
        let hostMemoryThreshold = max(1, Int(Double(HostResources.totalMemoryGB) * 0.9))
        let hostDiskLowThresholdGB = 20
        let hostUnderPressure = totalAllocatedCPU >= hostCPUThreshold ||
            totalAllocatedMemoryGB >= hostMemoryThreshold ||
            HostResources.freeDiskSpaceGB <= hostDiskLowThresholdGB

        if hostUnderPressure {
            let start = hostPressureStartTime ?? now
            hostPressureStartTime = start
            if !hostPressureNotified, now.timeIntervalSince(start) >= 60 {
                AppNotifications.shared.notify(
                    id: "host-pressure",
                    title: "Host Near Capacity",
                    body: "Host resources are near limits for over 1 minute (CPU/RAM allocation or free disk)."
                )
                hostPressureNotified = true
            }
        } else {
            hostPressureStartTime = nil
            hostPressureNotified = false
        }

        let currentRemoteIDs = Set(DiscoveryManager.shared.discovered.map(\.id))
        let newlyDetected = currentRemoteIDs.subtracting(knownRemoteNodeIDs)
        if !newlyDetected.isEmpty {
            for host in DiscoveryManager.shared.discovered where newlyDetected.contains(host.id) {
                AppNotifications.shared.notify(
                    id: "remote-node-\(host.id)",
                    title: "Remote Node Detected",
                    body: "\(host.name) has been detected on your cluster network."
                )
            }
        }
        knownRemoteNodeIDs = currentRemoteIDs
    }
    
    private func updateDetectedIPAddress(for vm: VirtualMachine) {
        let now = Date()
        if let last = lastIPAddressDetectionAt[vm.id], now.timeIntervalSince(last) < 15 {
            return
        }
        lastIPAddressDetectionAt[vm.id] = now
        
        if useAppleContainerRuntime {
            Task {
                do {
                    if let ip = try await AppleContainerService.shared.getContainerIPAsync(name: containerName(for: vm)) {
                        await MainActor.run {
                            if vm.ipAddress != ip {
                                vm.ipAddress = ip
                                vm.isConnected = true
                                self.ensureWireGuardForwarders(for: vm)
                            }
                        }
                    }
                } catch {
                    Logger(subsystem: "dimense.net.MLV", category: "VMManager").error("Failed to detect container IP for \(vm.name): \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        if vm.networkMode == .bridge, vm.bridgeInterfaceName == nil { return }
        guard let mac = storedMACAddress(for: vm) else { return }
        guard let ip = detectIPv4Address(forMAC: mac) else { return }
        if ip == vm.ipAddress { return }
        
        vm.ipAddress = ip
        if vm.networkMode == .nat, ip.hasPrefix("192.168.64.") {
            vm.gateway = "192.168.64.1"
        }
        vm.isConnected = true
        ensureWireGuardForwarders(for: vm)
    }
    
    private func storedMACAddress(for vm: VirtualMachine) -> String? {
        guard let vmDir = try? VMStorageManager.shared.ensureVMDirectoryExists(for: vm.id) else { return nil }
        let macURL = vmDir.appendingPathComponent("mac-address.txt")
        guard let mac = try? String(contentsOf: macURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !mac.isEmpty else { return nil }
        return canonicalMAC(mac)
    }
    
    private func canonicalMAC(_ mac: String) -> String {
        let normalized = mac.lowercased().replacingOccurrences(of: "-", with: ":")
        let parts = normalized.split(separator: ":").map { String($0) }
        guard parts.count == 6 else { return normalized }
        let padded = parts.map { part in
            let hex = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if hex.count == 1 { return "0\(hex)" }
            if hex.count == 0 { return "00" }
            if hex.count == 2 { return hex }
            return String(hex.suffix(2))
        }
        return padded.joined(separator: ":")
    }
    
    private func detectIPv4Address(forMAC mac: String) -> String? {
        if let arp = detectFromARPTable(forMAC: mac) {
            return arp
        }
        if let lease = detectFromDHCPLeases(forMAC: mac) {
            return lease
        }
        return nil
    }
    
    private func detectFromDHCPLeases(forMAC mac: String) -> String? {
        let paths = ["/var/db/dhcpd_leases", "/private/var/db/dhcpd_leases"]
        for path in paths {
            if let data = FileManager.default.contents(atPath: path),
               let text = String(data: data, encoding: .utf8) {
                if let ip = bestDHCPLeaseIPv4(forMAC: mac, in: text) {
                    return ip
                }
            }
        }
        return nil
    }
    
    private struct DHCPLeaseRecord {
        let ip: String
        let mac: String
        let starts: Date?
        let ends: Date?
        let bindingState: String?
    }
    
    private func bestDHCPLeaseIPv4(forMAC mac: String, in text: String) -> String? {
        let normalizedMAC = canonicalMAC(mac)
        let leases = parseDHCPLeaseRecords(text)
            .filter { canonicalMAC($0.mac) == normalizedMAC }
        
        if leases.isEmpty { return nil }
        
        let now = Date()
        let active = leases.filter { rec in
            if let state = rec.bindingState?.lowercased(), state != "active" { return false }
            if let ends = rec.ends, ends < now { return false }
            return true
        }
        
        let preferred = active.isEmpty ? leases : active
        
        let sorted = preferred.sorted { a, b in
            let aStarts = a.starts ?? .distantPast
            let bStarts = b.starts ?? .distantPast
            if aStarts != bStarts { return aStarts > bStarts }
            let aEnds = a.ends ?? .distantPast
            let bEnds = b.ends ?? .distantPast
            if aEnds != bEnds { return aEnds > bEnds }
            return a.ip > b.ip
        }
        return sorted.first?.ip
    }
    
    private func parseDHCPLeaseRecords(_ text: String) -> [DHCPLeaseRecord] {
        var records: [DHCPLeaseRecord] = []
        
        var currentIP: String?
        var currentMAC: String?
        var currentStarts: Date?
        var currentEnds: Date?
        var currentState: String?
        var currentIPFromKV: String?
        var currentMACFromKV: String?
        
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy/MM/dd HH:mm:ss"
        
        func flush() {
            let ip = currentIP ?? currentIPFromKV
            let mac = currentMAC ?? currentMACFromKV
            if let ip, !ip.isEmpty, let mac, !mac.isEmpty {
                records.append(DHCPLeaseRecord(ip: ip, mac: mac, starts: currentStarts, ends: currentEnds, bindingState: currentState))
            }
            currentIP = nil
            currentMAC = nil
            currentStarts = nil
            currentEnds = nil
            currentState = nil
            currentIPFromKV = nil
            currentMACFromKV = nil
        }
        
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.hasPrefix("lease "), trimmed.contains("{") {
                flush()
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    currentIP = parts[1]
                }
                continue
            }
            
            if trimmed.hasPrefix("ip_address=") {
                currentIPFromKV = trimmed
                    .replacingOccurrences(of: "ip_address=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                continue
            }
            
            if trimmed.contains("hardware ethernet") {
                if let r = trimmed.range(of: "hardware ethernet") {
                    let rest = trimmed[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    let macRaw = rest.components(separatedBy: CharacterSet(charactersIn: "; ")).first ?? ""
                    currentMAC = canonicalMAC(macRaw)
                }
                continue
            }
            
            if trimmed.hasPrefix("hw_address=") {
                let val = trimmed
                    .replacingOccurrences(of: "hw_address=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                let components = val.components(separatedBy: ",")
                let macRaw = components.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                currentMACFromKV = canonicalMAC(macRaw)
                continue
            }
            
            if trimmed.hasPrefix("starts ") || trimmed.hasPrefix("ends ") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 4 {
                    let dateString = "\(parts[2]) \(parts[3].trimmingCharacters(in: CharacterSet(charactersIn: ";")))"
                    let parsed = df.date(from: dateString)
                    if trimmed.hasPrefix("starts ") {
                        currentStarts = parsed
                    } else {
                        currentEnds = parsed
                    }
                }
                continue
            }
            
            if trimmed.hasPrefix("binding state") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 3 {
                    currentState = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                }
                continue
            }
            
            if trimmed == "}" {
                flush()
                continue
            }
        }
        
        flush()
        return records
    }
    
    private func detectFromARPTable(forMAC mac: String) -> String? {
        guard let output = runTool("/usr/sbin/arp", ["-an"]) else { return nil }
        let needleMAC = canonicalMAC(mac)
        let lines = output.split(separator: "\n").map { String($0) }
        for line in lines {
            let lower = line.lowercased()
            guard let atRange = lower.range(of: " at ") else { continue }
            let afterAt = lower[atRange.upperBound...]
            let macToken = afterAt.split(separator: " ").first.map(String.init) ?? ""
            if canonicalMAC(macToken) != needleMAC { continue }
            if let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close {
                let ip = String(line[line.index(after: open)..<close])
                if !ip.isEmpty {
                    return ip
                }
            }
        }
        return nil
    }
    
    private func runTool(_ executablePath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func ensureWireGuardForwarders(for vm: VirtualMachine) {
        guard vm.networkMode == .nat else { return }
        let guestIP = vm.ipAddress
        if guestIP == "Detecting..." || guestIP.isEmpty { return }
        
        if let last = wgForwarderTargetIP[vm.id], last != guestIP {
            wgControlForwarders[vm.id]?.stop()
            wgControlForwarders[vm.id] = nil
            wgDataForwarders[vm.id]?.stop()
            wgDataForwarders[vm.id] = nil
        }
        
        if vm.wgControlHostForwardPort > 0, wgControlForwarders[vm.id] == nil {
            do {
                let fwd = try UDPPortForwarder(listenPort: vm.wgControlHostForwardPort, targetIP: guestIP, targetPort: vm.wgControlListenPort)
                try fwd.start()
                wgControlForwarders[vm.id] = fwd
                wgForwarderTargetIP[vm.id] = guestIP
                vm.addLog("WireGuard control UDP forwarder active on host port \(vm.wgControlHostForwardPort).")
            } catch {
                vm.addLog("Failed to start WG control UDP forwarder: \(error.localizedDescription)", isError: true)
            }
        }
        
        if vm.wgDataHostForwardPort > 0, wgDataForwarders[vm.id] == nil {
            do {
                let fwd = try UDPPortForwarder(listenPort: vm.wgDataHostForwardPort, targetIP: guestIP, targetPort: vm.wgDataListenPort)
                try fwd.start()
                wgDataForwarders[vm.id] = fwd
                wgForwarderTargetIP[vm.id] = guestIP
                vm.addLog("WireGuard data UDP forwarder active on host port \(vm.wgDataHostForwardPort).")
            } catch {
                vm.addLog("Failed to start WG data UDP forwarder: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func saveBookmark(for url: URL) {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: isoBookmarkKey)
        } catch {
            logger.error("Error saving bookmark: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadBookmark() {
        guard let data = UserDefaults.standard.data(forKey: isoBookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if url.startAccessingSecurityScopedResource() {
                self.authorizedISOURL = url
                url.stopAccessingSecurityScopedResource()
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: isoBookmarkKey)
        }
    }

    private func ensureCachedInstallerISO(for vm: VirtualMachine, cacheDir: URL) async throws -> URL {
        let cachedURL = cacheDir.appendingPathComponent(cacheFileName(for: vm.selectedDistro))
        
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return maybePreseeded(url: cachedURL, vm: vm, cacheDir: cacheDir)
        }
        
        if vm.selectedDistro == .debian13 {
            guard let local = templateISOURL(for: .debian13) else {
                throw VMError.configurationInvalid("Please upload Debian ISO.")
            }
            try streamCopy(from: local, to: cachedURL)
            return cachedURL
        }
        
        guard let mirror = vm.selectedDistro.mirrorURL else {
            throw VMError.configurationInvalid("No mirror for \(vm.selectedDistro.rawValue)")
        }
        
        vm.stage = .downloadingISO
        try await downloadISO(from: mirror, to: cachedURL, vm: vm)
        return maybePreseeded(url: cachedURL, vm: vm, cacheDir: cacheDir)
    }

    private func cacheFileName(for distro: VirtualMachine.LinuxDistro) -> String {
        switch distro {
        case .debian13: return "debian-13.iso"
        case .alpine: return "alpine.iso"
        case .ubuntu: return "ubuntu.iso"
        case .minimal: return "minimal.iso"
        }
    }

    private func preseededCacheFileName(for distro: VirtualMachine.LinuxDistro) -> String {
        switch distro {
        case .debian13: return "debian-13-preseed.iso"
        default: return cacheFileName(for: distro)
        }
    }

    private func templateISOURL(for distro: VirtualMachine.LinuxDistro) -> URL? {
        if let authorized = authorizedISOURL { return authorized }
        return nil
    }

    private func downloadISO(from url: URL, to destination: URL, vm: VirtualMachine) async throws {
        vm.addLog("Downloading ISO...")
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VMError.configurationInvalid("Download failed")
        }
        
        // Move downloaded file to destination
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        vm.addLog("ISO download complete.")
    }

    private func streamCopy(from source: URL, to destination: URL) throws {
        let didStartAccess = source.startAccessingSecurityScopedResource()
        defer { if didStartAccess { source.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        
        let readHandle = try FileHandle(forReadingFrom: source)
        let writeHandle = try FileHandle(forWritingTo: destination)
        defer {
            try? readHandle.close()
            try? writeHandle.close()
        }
        
        let chunkSize = 4 * 1024 * 1024
        while true {
            let data = try autoreleasepool {
                try readHandle.read(upToCount: chunkSize) ?? Data()
            }
            if data.isEmpty { break }
            try writeHandle.write(contentsOf: data)
        }
    }

    private func maybePreseeded(url: URL, vm: VirtualMachine, cacheDir: URL) -> URL {
        // VZLinuxBootLoader passes the preseed URL natively via the kernel command line.
        // We do not need to build a preseeded ISO with makehybrid, which can strip boot sectors
        // and cause the Apple Virtualization Framework to reject the disk image.
        return url
    }

    private func buildPreseededISO(from source: URL, to destination: URL, preseedURL: String) throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mountPoint = tempRoot.appendingPathComponent("mnt")
        let workDir = tempRoot.appendingPathComponent("work")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Mount ISO
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", source.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        try attach.run()
        attach.waitUntilExit()

        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint.path, "-force"]
            try? detach.run()
            let _ = try? detach.waitUntilExit()
            try? fm.removeItem(at: tempRoot)
        }

        // Copy contents
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [mountPoint.path, workDir.path]
        try ditto.run()
        ditto.waitUntilExit()

        // Patch isolinux/grub if present
        patchBootConfigs(in: workDir, preseedURL: preseedURL)

        // Rebuild ISO (best-effort)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        make.arguments = ["makehybrid", "-iso", "-joliet", "-o", destination.path, workDir.path]
        try make.run()
        make.waitUntilExit()
    }

    private func patchBootConfigs(in dir: URL, preseedURL: String) {
        let files = [
            dir.appendingPathComponent("isolinux/txt.cfg"),
            dir.appendingPathComponent("isolinux/isolinux.cfg"),
            dir.appendingPathComponent("boot/grub/grub.cfg")
        ]
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            if var text = try? String(contentsOf: file, encoding: .utf8) {
                if !text.contains("preseed/url") {
                    text = text.replacingOccurrences(of: "append", with: "append auto priority=critical preseed/url=\(preseedURL) debian-installer/locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us", options: .literal, range: nil)
                    text = text.replacingOccurrences(of: "linux", with: "linux auto priority=critical preseed/url=\(preseedURL) debian-installer/locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us", options: .literal, range: nil)
                    try? text.write(to: file, atomically: true, encoding: .utf8)
                }
            }
        }
    }
    
    func stopVM(_ vm: VirtualMachine) async throws {
        try await VMLifecycleManager.shared.performOperation(for: vm.id) {
            try await self._stopVMInternal(vm)
        }
    }

    private func _stopVMInternal(_ vm: VirtualMachine) async throws {
        if useAppleContainerRuntime {
            vm.userInitiatedStop = true
            do {
                try AppleContainerService.shared.stopWorkload(name: containerName(for: vm))
                vm.addLog("Stopped container workload \(containerName(for: vm)).")
            } catch {
                vm.addLog("Container stop failed: \(error.localizedDescription)", isError: true)
                throw error
            }
            vm.state = .stopped
            vm.stage = .stopped
            vm.guestCPUUsagePercent = 0
            vm.guestMemoryUsagePercent = 0
            vm.guestDiskUsagePercent = 0
            vm.hasGuestUsageSample = false
            vm.lastGuestCPUTotalTicks = nil
        vm.lastGuestCPUIdleTicks = nil
        vm.lastMonitoredProcessTicks = nil
        vm.lastHealthyPoll = nil
        vm.isConnected = false
        wgForwarderTargetIP[vm.id] = nil
        if let pid = vm.hostServicePID {
            assignedHostServicePIDs.remove(Int32(pid))
            vm.hostServicePID = nil
        }
        restartingVMs.remove(vm.id)
        refreshBackgroundExecution()
        return
    }

        vm.userInitiatedStop = true
        try await vm.vzVirtualMachine?.stop()
        vm.state = .stopped
        vm.guestCPUUsagePercent = 0
        vm.guestMemoryUsagePercent = 0
        vm.guestDiskUsagePercent = 0
        vm.hasGuestUsageSample = false
        vm.lastGuestCPUTotalTicks = nil
        vm.lastGuestCPUIdleTicks = nil
        vm.lastMonitoredProcessTicks = nil
        serialReadPipes[vm.id]?.fileHandleForReading.readabilityHandler = nil
        try? serialReadPipes[vm.id]?.fileHandleForReading.close()
        try? vm.serialWritePipe?.fileHandleForWriting.close()
        if let pid = vm.hostServicePID {
            assignedHostServicePIDs.remove(Int32(pid))
            vm.hostServicePID = nil
        }
        serialReadPipes[vm.id] = nil
        pollBuffers[vm.id] = nil
        vm.serialWritePipe = nil
        vm.vzVirtualMachine = nil
        vm.vzDelegate = nil
        wgControlForwarders[vm.id]?.stop()
        wgControlForwarders[vm.id] = nil
        wgDataForwarders[vm.id]?.stop()
        wgDataForwarders[vm.id] = nil
        terminalConsoleServers[vm.id]?.stop()
        terminalConsoleServers[vm.id] = nil
        wgForwarderTargetIP[vm.id] = nil
        restartingVMs.remove(vm.id)
        refreshBackgroundExecution()
    }
    
    func restartVM(_ vm: VirtualMachine) async throws {
        try await stopVM(vm)
        try await startVM(vm)
    }
    
    func openVMFolder(_ vm: VirtualMachine) {
        if let url = vm.vmDirectory {
            NSWorkspace.shared.open(url)
        }
    }
    
    func removeVM(_ vm: VirtualMachine) {
        Task {
            try? await stopVM(vm)
            if useAppleContainerRuntime {
                try? AppleContainerService.shared.deleteWorkload(name: containerName(for: vm))
            }
            VMStorageManager.shared.cleanupVMDirectory(for: vm.id)
            virtualMachines.removeAll { $0.id == vm.id }
            VMStatePersistence.shared.saveVMs(self.virtualMachines)
        }
    }

    func ensurePreseedServerRunning() {
        let preseed = debianPreseed()
        InlinePreseedServer.shared.start(preseed: Data(preseed.utf8))
    }
}
