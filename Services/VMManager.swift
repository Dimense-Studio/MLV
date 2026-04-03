import Foundation
import Virtualization
import SwiftUI
import AppKit
import os

@MainActor
@Observable
class VMManager {
    static let shared = VMManager()
    private let logger = Logger(subsystem: "dimense.net.MLV", category: "VMManager")
    var virtualMachines: [VirtualMachine] = []
    
    private var wgControlForwarders: [UUID: UDPPortForwarder] = [:]
    private var wgDataForwarders: [UUID: UDPPortForwarder] = [:]
    private var terminalConsoleServers: [UUID: VMTerminalConsoleServer] = [:]
    private var wgForwarderTargetIP: [UUID: String] = [:]
    private var serialReadPipes: [UUID: Pipe] = [:]
    private var pollBuffers: [UUID: String] = [:]
    private var vmPressureStartTimes: [UUID: Date] = [:]
    private var vmPressureNotified: Set<UUID> = []
    private var hostPressureStartTime: Date? = nil
    private var hostPressureNotified = false
    private var knownRemoteNodeIDs: Set<String> = []
    
    // Persistent ISO authorization
    private let isoBookmarkKey = "MLV_ISO_Bookmark"
    
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
                ramGB: meta.memorySizeGB,
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
            return vm
        }
    }

    func refreshBackgroundExecution() {
        let wants = AppSettingsStore.shared.preventSleepWhileVMRunning
        let running = virtualMachines.contains { $0.state == .running || $0.state == .starting }
        BackgroundExecutionManager.shared.setActive(wants && running)
    }
    
    func autoStartVMsIfNeeded() {
        Task { @MainActor in
            // Give launch-time services and VM metadata a moment to settle.
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            for attempt in 1...3 {
                let targets = self.virtualMachines.filter {
                    $0.autoStartOnLaunch &&
                    $0.isInstalled &&
                    !$0.state.isRunning &&
                    $0.state != .starting
                }
                if targets.isEmpty { break }

                for vm in targets {
                    do {
                        try await self.startVM(vm)
                        vm.addLog("Autostart succeeded.")
                    } catch {
                        vm.addLog("Autostart attempt \(attempt) failed: \(error.localizedDescription)", isError: true)
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }

                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
    
    private func startDataPolling() {
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                for vm in self.virtualMachines where vm.state == .running {
                    self.updateDetectedIPAddress(for: vm)
                    if vm.isInstalled {
                        self.pollVMData(vm)
                        self.evaluateVMHealth(vm)
                    }
                }
                self.evaluateLimitAlerts()
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
        let normalizedVMName = vm.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let autoPattern = "mlv-\(normalizedVMName)"
        let shellAutoPattern = shellSingleQuoted(autoPattern)
        
        let pollCmd = """
        echo "---POLL_START---"
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
        ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | head -n 1
        ip route show default | awk '{print $3}' | head -n 1
        cat /etc/resolv.conf | grep nameserver | awk '{print $2}' | xargs echo
        echo "---VM_USAGE_START---"
        awk '/^cpu / {print "CPU_TICKS " $2 " " $3 " " $4 " " $5 " " $6 " " $7 " " $8 " " $9; exit}' /proc/stat 2>/dev/null || echo "CPU_TICKS 0 0 0 0 0 0 0 0"
        awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {avail=$2} END {if (total>0) print "MEM_KB " total " " avail; else print "MEM_KB 0 0"}' /proc/meminfo 2>/dev/null
        df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print "DISK_PCT " $5}' || echo "DISK_PCT 0"
        PID=\(max(0, vm.monitoredProcessPID))
        if [ "$PID" -le 1 ]; then
          PID=$(pgrep -fo -- \(shellAutoPattern) 2>/dev/null || echo 0)
        fi
        echo "PID_SELECTED $PID"
        if [ "$PID" -gt 0 ] && [ -r "/proc/$PID/stat" ]; then
          awk -v pid="$PID" '$1 == pid {print "PID_TICKS " $14 " " $15; found=1} END {if (!found) print "PID_TICKS 0 0"}' /proc/$PID/stat 2>/dev/null
          awk -v pid="$PID" '/^VmRSS:/ {print "PID_RSS_KB " $2; found=1} END {if (!found) print "PID_RSS_KB 0"}' /proc/$PID/status 2>/dev/null
        else
          echo "PID_TICKS 0 0"
          echo "PID_RSS_KB 0"
        fi
        head -n 1 /proc/stat 2>/dev/null || true
        grep -m1 '^MemTotal:' /proc/meminfo 2>/dev/null || true
        grep -m1 '^MemAvailable:' /proc/meminfo 2>/dev/null || true
        df -P / 2>/dev/null | head -n 2 || true
        echo "---VM_USAGE_END---"
        echo "---PODS_START---"
        KUBECTL_BIN="$(command -v kubectl 2>/dev/null || true)"
        if [ -z "$KUBECTL_BIN" ] && [ -x /usr/local/bin/kubectl ]; then KUBECTL_BIN=/usr/local/bin/kubectl; fi
        if [ -z "$KUBECTL_BIN" ] && [ -x /usr/bin/kubectl ]; then KUBECTL_BIN=/usr/bin/kubectl; fi
        if [ -n "$KUBECTL_BIN" ]; then
          "$KUBECTL_BIN" get pods -A --no-headers -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CPU:.spec.containers[0].resources.requests.cpu,RAM:.spec.containers[0].resources.requests.memory" | awk '{print $1 "|" $2 "|" $3 "|" $4 "|" $5}' | head -n 40
        else
          echo "K3S_NOT_READY"
        fi
        echo "---PODS_END---"
        echo "---CONTAINERS_START---"
        DOCKER_BIN="$(command -v docker 2>/dev/null || true)"
        NERDCTL_BIN="$(command -v nerdctl 2>/dev/null || true)"
        PODMAN_BIN="$(command -v podman 2>/dev/null || true)"
        CRICTL_BIN="$(command -v crictl 2>/dev/null || true)"
        if [ -z "$DOCKER_BIN" ] && [ -x /usr/local/bin/docker ]; then DOCKER_BIN=/usr/local/bin/docker; fi
        if [ -z "$DOCKER_BIN" ] && [ -x /usr/bin/docker ]; then DOCKER_BIN=/usr/bin/docker; fi
        if [ -z "$NERDCTL_BIN" ] && [ -x /usr/local/bin/nerdctl ]; then NERDCTL_BIN=/usr/local/bin/nerdctl; fi
        if [ -z "$NERDCTL_BIN" ] && [ -x /usr/bin/nerdctl ]; then NERDCTL_BIN=/usr/bin/nerdctl; fi
        if [ -z "$PODMAN_BIN" ] && [ -x /usr/local/bin/podman ]; then PODMAN_BIN=/usr/local/bin/podman; fi
        if [ -z "$PODMAN_BIN" ] && [ -x /usr/bin/podman ]; then PODMAN_BIN=/usr/bin/podman; fi
        if [ -z "$CRICTL_BIN" ] && [ -x /usr/local/bin/crictl ]; then CRICTL_BIN=/usr/local/bin/crictl; fi
        if [ -z "$CRICTL_BIN" ] && [ -x /usr/bin/crictl ]; then CRICTL_BIN=/usr/bin/crictl; fi
        if [ -n "$DOCKER_BIN" ]; then
          "$DOCKER_BIN" ps --format '{{.Names}}|{{.Image}}|{{.Status}}|docker' 2>/dev/null | head -n 40
        elif [ -n "$NERDCTL_BIN" ]; then
          "$NERDCTL_BIN" ps --format '{{.Names}}|{{.Image}}|{{.Status}}|nerdctl' 2>/dev/null | head -n 40
        elif [ -n "$PODMAN_BIN" ]; then
          "$PODMAN_BIN" ps --format '{{.Names}}|{{.Image}}|{{.Status}}|podman' 2>/dev/null | head -n 40
        elif [ -n "$CRICTL_BIN" ]; then
          "$CRICTL_BIN" ps --no-trunc 2>/dev/null | awk 'NR>1 {print $NF "|" $2 "|" $5 "|" "crictl"}' | head -n 40
        else
          echo "CONTAINERS_NOT_READY"
        fi
        echo "---CONTAINERS_END---"
        echo "---POLL_END---"
        """
        
        if let data = (pollCmd + "\n").data(using: .utf8) {
            try? pipe.fileHandleForWriting.write(contentsOf: data)
        }
    }
    
    private func evaluateVMHealth(_ vm: VirtualMachine) {
        guard vm.state == .running, vm.isInstalled else { return }
        guard let last = vm.lastHealthyPoll else { return }
        if Date().timeIntervalSince(last) < 90 { return }
        if vm.userInitiatedStop { return }
        
        vm.addLog("Health check timeout. Attempting recovery...", isError: true)
        Task { @MainActor in
            try? await self.restartVM(vm)
        }
    }
    
    func createLinuxVM(
        name: String? = nil,
        cpus: Int = 4,
        ramGB: Int = 8,
        sysDiskGB: Int = 64,
        dataDiskGB: Int = 100,
        isMaster: Bool = false,
        distro: VirtualMachine.LinuxDistro = .debian13,
        networkMode: VMNetworkMode = .nat,
        bridgeInterfaceName: String? = nil,
        secondaryNetworkEnabled: Bool = false,
        secondaryNetworkMode: VMNetworkMode = .nat,
        secondaryBridgeInterfaceName: String? = nil
    ) async throws -> VirtualMachine {
        if !VZVirtualMachine.isSupported {
            throw VMError.virtualizationNotSupported
        }
        
        let vmName = name ?? "Node \(virtualMachines.count + 1)"
        let placeholderURL = FileManager.default.temporaryDirectory.appendingPathComponent("placeholder.iso")
        
        let vm = VirtualMachine(name: vmName, isoURL: placeholderURL, cpus: cpus, ramGB: ramGB, sysDiskGB: sysDiskGB, dataDiskGB: dataDiskGB)
        vm.isMaster = isMaster
        vm.selectedDistro = distro
        vm.networkMode = networkMode
        vm.bridgeInterfaceName = networkMode == .bridge ? bridgeInterfaceName : nil
        vm.secondaryNetworkEnabled = secondaryNetworkEnabled
        vm.secondaryNetworkMode = secondaryNetworkMode
        vm.secondaryBridgeInterfaceName = (secondaryNetworkEnabled && secondaryNetworkMode == .bridge) ? secondaryBridgeInterfaceName : nil
        vm.monitoredProcessPID = Int.random(in: 100...999_999)
        vm.monitoredProcessName = autoPattern(for: vm.name)
        vm.clusterRole = isMaster ? .master : .node
        
        let (controlPorts, dataPorts) = allocateWireGuardPorts(for: vm.id)
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
        
        let octet = allocateWireGuardOctet(for: vm.id, preferred: isMaster ? 1 : nil)
        vm.wgControlAddressCIDR = "10.13.0.\(octet)/24"
        vm.wgDataAddressCIDR = "10.13.1.\(octet)/24"
        
        self.virtualMachines.append(vm)
        VMStatePersistence.shared.saveVMs(self.virtualMachines)
        
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
    
    func startVM(_ vm: VirtualMachine) async throws {
        if vm.state == .starting || vm.state == .running { return }
        
        vm.addLog("Starting Virtual Machine: \(vm.name)")
        vm.state = .starting
        vm.ipAddress = "Detecting..."
        vm.isConnected = false
        refreshBackgroundExecution()
        
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
                
                if !FileManager.default.fileExists(atPath: stagedISOURL.path) {
                    vm.addLog("Staging ISO to VM storage...")
                    try streamCopy(from: cachedISOURL, to: stagedISOURL)
                }
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
            consoleDevice.ports[0] = portConfig
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
        
        if lines.count >= 3 {
            vm.ipAddress = lines[0]
            vm.gateway = lines[1]
            vm.dns = lines[2].components(separatedBy: " ")
            vm.isConnected = true
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
        let totalAllocatedMemoryGB = virtualMachines.filter { $0.state == .running }.reduce(0) { $0 + $1.memorySizeGB }
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
            return cachedURL
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
        return cachedURL
    }

    private func cacheFileName(for distro: VirtualMachine.LinuxDistro) -> String {
        switch distro {
        case .debian13: return "debian-13.iso"
        case .alpine: return "alpine.iso"
        case .ubuntu: return "ubuntu.iso"
        case .minimal: return "minimal.iso"
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
    
    func stopVM(_ vm: VirtualMachine) async throws {
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
            VMStorageManager.shared.cleanupVMDirectory(for: vm.id)
            virtualMachines.removeAll { $0.id == vm.id }
            VMStatePersistence.shared.saveVMs(virtualMachines)
        }
    }
}

enum VMError: Error, LocalizedError {
    case virtualizationNotSupported
    case configurationInvalid(String)
    
    var errorDescription: String? {
        switch self {
        case .virtualizationNotSupported:
            return "Virtualization is not supported on this Mac"
        case .configurationInvalid(let reason):
            return "Invalid VM configuration: \(reason)"
        }
    }
}
