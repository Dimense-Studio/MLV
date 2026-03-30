import Foundation
import Virtualization
import SwiftUI
import AppKit

@MainActor
@Observable
class VMManager {
    static let shared = VMManager()
    var virtualMachines: [VirtualMachine] = []
    
    private var wgControlForwarders: [UUID: UDPPortForwarder] = [:]
    private var wgDataForwarders: [UUID: UDPPortForwarder] = [:]
    private var terminalConsoleServers: [UUID: VMTerminalConsoleServer] = [:]
    private var wgForwarderTargetIP: [UUID: String] = [:]
    private var serialReadPipes: [UUID: Pipe] = [:]
    private var pollBuffers: [UUID: String] = [:]
    
    // Persistent ISO authorization
    private let isoBookmarkKey = "MLV_ISO_Bookmark"
    private let clusterTokenKey = "MLV_Cluster_Token"
    
    var authorizedISOURL: URL? {
        didSet {
            if let url = authorizedISOURL {
                saveBookmark(for: url)
            }
        }
    }
    
    var clusterToken: String {
        get {
            if let token = UserDefaults.standard.string(forKey: clusterTokenKey), !token.isEmpty {
                return token
            }
            let newToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(newToken, forKey: clusterTokenKey)
            return newToken
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            UserDefaults.standard.set(trimmed, forKey: clusterTokenKey)
        }
    }
    
    func getAvailableBridgeInterfaces() -> [VZBridgedNetworkInterface] {
        return VZBridgedNetworkInterface.networkInterfaces
    }

    private init() {
        loadBookmark()
        loadStoredVMs()
        startDataPolling()
    }
    
    private func loadStoredVMs() {
        let metadata = VMStatePersistence.shared.loadVMs()
        self.virtualMachines = metadata.compactMap { meta in
            guard let distro = VirtualMachine.LinuxDistro(rawValue: meta.selectedDistro) else { return nil }
            
            // We use a placeholder URL as the actual ISO will be staged/cached if needed
            let placeholderURL = URL(fileURLWithPath: "/tmp/placeholder.iso")
            
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
        if !AppSettingsStore.shared.autoStartVMsOnLaunch { return }
        
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            
            let targets = self.virtualMachines.filter { $0.autoStartOnLaunch && $0.isInstalled && $0.state == .stopped }
            for vm in targets {
                do {
                    try await self.startVM(vm)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    vm.addLog("Autostart failed: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }
    
    private func startDataPolling() {
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { _ in
            Task { @MainActor in
                for vm in self.virtualMachines where vm.state == .running {
                    self.updateDetectedIPAddress(for: vm)
                    if vm.isInstalled {
                        self.pollVMData(vm)
                        self.evaluateVMHealth(vm)
                    }
                }
            }
        }
    }
    
    private func pollVMData(_ vm: VirtualMachine) {
        guard let pipe = vm.serialWritePipe else { return }
        
        let pollCmd = """
        echo "---POLL_START---"
        ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | head -n 1
        ip route show default | awk '{print $3}' | head -n 1
        cat /etc/resolv.conf | grep nameserver | awk '{print $2}' | xargs echo
        if command -v kubectl >/dev/null; then
          kubectl get pods -A --no-headers -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CPU:.spec.containers[0].resources.requests.cpu,RAM:.spec.containers[0].resources.requests.memory" | head -n 20
        else
          echo "K3S_NOT_READY"
        fi
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
    
    func createLinuxVM(name: String? = nil, cpus: Int = 4, ramGB: Int = 8, sysDiskGB: Int = 64, dataDiskGB: Int = 100, isMaster: Bool = false, distro: VirtualMachine.LinuxDistro = .debian13) async throws -> VirtualMachine {
        if !VZVirtualMachine.isSupported {
            throw VMError.virtualizationNotSupported
        }
        
        let vmName = name ?? "Node \(virtualMachines.count + 1)"
        let placeholderURL = URL(fileURLWithPath: "/tmp/placeholder.iso")
        
        let vm = VirtualMachine(name: vmName, isoURL: placeholderURL, cpus: cpus, ramGB: ramGB, sysDiskGB: sysDiskGB, dataDiskGB: dataDiskGB)
        vm.isMaster = isMaster
        vm.selectedDistro = distro
        vm.networkMode = .nat
        vm.bridgeInterfaceName = nil
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
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.updateDetectedIPAddress(for: vm)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.updateDetectedIPAddress(for: vm)
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
        let lines = rawContent.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if lines.count >= 3 {
            vm.ipAddress = lines[0]
            vm.gateway = lines[1]
            vm.dns = lines[2].components(separatedBy: " ")
            vm.isConnected = true
            ensureWireGuardForwarders(for: vm)
            
            if lines.count > 3 {
                if lines[3].contains("K3S_NOT_READY") {
                    vm.pods = []
                    return
                }
                
                var newPods: [VirtualMachine.Pod] = []
                for i in 3..<lines.count {
                    let parts = lines[i].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 3 {
                        let pod = VirtualMachine.Pod(
                            name: parts[1],
                            status: parts[2],
                            cpu: parts.count > 3 ? parts[3] : "N/A",
                            ram: parts.count > 4 ? parts[4] : "N/A",
                            namespace: parts[0]
                        )
                        newPods.append(pod)
                    }
                }
                vm.pods = newPods
            }
        }
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
            print("Error saving bookmark: \(error)")
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
