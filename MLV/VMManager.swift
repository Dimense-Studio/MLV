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
        if let token = UserDefaults.standard.string(forKey: clusterTokenKey) {
            return token
        }
        let newToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(newToken, forKey: clusterTokenKey)
        return newToken
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
                for vm in self.virtualMachines where vm.state == .running && vm.isInstalled {
                    self.pollVMData(vm)
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
    
    func fetchInstallerLogs(for vm: VirtualMachine) {
        guard let pipe = vm.serialWritePipe else { return }
        vm.addLog("Requesting installer diagnostics...")
        
        let logCmd = """
        echo "---DIAG_START---"
        echo "[NETWORK_STATE]"
        ip -4 addr show
        ip route show
        ping -c 1 8.8.8.8 | grep "received"
        echo "[PRESEED_CONTENT]"
        cat /tmp/preseed.cfg
        echo "[SYSLOG_ERRORS]"
        grep -E "mirror|netcfg|wget|error|fail|warning" /var/log/syslog | tail -n 100
        echo "---DIAG_END---"
        """
        
        if let data = (logCmd + "\n").data(using: .utf8) {
            try? pipe.fileHandleForWriting.write(contentsOf: data)
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
                
                if vm.selectedDistro == .debian13 || vm.selectedDistro == .alpine {
                    let (kernelURL, initrdURL) = try await extractKernelAndInitrd(from: stagedISOURL, to: vmDir, vm: vm)
                    if vm.selectedDistro == .debian13 {
                        try injectPreseed(into: initrdURL, isMaster: vm.isMaster, vm: vm)
                    }
                }
                
                if vm.selectedDistro == .ubuntu {
                    let masterIP = virtualMachines.first(where: { $0.isMaster })?.ipAddress ?? "192.168.64.2"
                    _ = try createUbuntuNoCloudSeedISO(in: vmDir, vm: vm, masterIP: masterIP)
                }
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
                    self.processConsoleOutput(str, for: vm)
                }
            }
        }
    }
    
    private func processConsoleOutput(_ str: String, for vm: VirtualMachine) {
        // Handle polling data
        if vm.consoleOutput.contains("---POLL_START---") && vm.consoleOutput.contains("---POLL_END---") {
            if let startRange = vm.consoleOutput.range(of: "---POLL_START---"),
               let endRange = vm.consoleOutput.range(of: "---POLL_END---", options: .backwards) {
                let block = String(vm.consoleOutput[startRange.lowerBound..<endRange.upperBound])
                self.parsePollingData(block, for: vm)
                vm.consoleOutput.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: "")
            }
        }
        
        // Handle diagnostics
        if vm.consoleOutput.contains("---DIAG_START---") && vm.consoleOutput.contains("---DIAG_END---") {
            if let startRange = vm.consoleOutput.range(of: "---DIAG_START---"),
               let endRange = vm.consoleOutput.range(of: "---DIAG_END---", options: .backwards) {
                let diagBlock = String(vm.consoleOutput[startRange.upperBound..<endRange.lowerBound])
                self.processInstallerDiagnostics(diagBlock, for: vm)
                vm.consoleOutput.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: "")
            }
        }
        
        // Handle installation progress
        if !vm.isInstalled {
            if str.localizedCaseInsensitiveContains("---MLV_INSTALL_DONE---") {
                vm.addLog("Installation finished! Rebooting into OS.")
                vm.isInstalled = true
                vm.pendingAutoStartAfterInstall = true
                vm.stage = .rebooting
                Task { try? await vm.vzVirtualMachine?.stop() }
            } else if str.localizedCaseInsensitiveContains("---MLV_INSTALL_BOOT_FAIL---") {
                vm.addLog("Installation failed at bootloader step.", isError: true)
                vm.stage = .error
            }
        }
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

    private func ensureWireGuardForwarders(for vm: VirtualMachine) {
        guard vm.networkMode == .nat else { return }
        let guestIP = vm.ipAddress
        if guestIP == "Detecting..." || guestIP.isEmpty { return }
        
        if vm.wgControlHostForwardPort > 0, wgControlForwarders[vm.id] == nil {
            do {
                let fwd = try UDPPortForwarder(listenPort: vm.wgControlHostForwardPort, targetIP: guestIP, targetPort: vm.wgControlListenPort)
                try fwd.start()
                wgControlForwarders[vm.id] = fwd
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
                vm.addLog("WireGuard data UDP forwarder active on host port \(vm.wgDataHostForwardPort).")
            } catch {
                vm.addLog("Failed to start WG data UDP forwarder: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func processInstallerDiagnostics(_ diagBlock: String, for vm: VirtualMachine) {
        vm.addLog("Installer Diagnostics received.")
        if diagBlock.contains("could not resolve") {
            vm.addLog("ROOT CAUSE: DNS Failure.", isError: true)
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
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VMError.configurationInvalid("Download failed")
        }
        
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let fileHandle = try FileHandle(forWritingTo: destination)
        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1024 * 1024 {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll()
            }
        }
        if !buffer.isEmpty { try fileHandle.write(contentsOf: buffer) }
        try fileHandle.close()
    }

    private func streamCopy(from source: URL, to destination: URL) throws {
        let didStartAccess = source.startAccessingSecurityScopedResource()
        defer { if didStartAccess { source.stopAccessingSecurityScopedResource() } }
        
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
    }

    private func extractKernelAndInitrd(from isoURL: URL, to tempDir: URL, vm: VirtualMachine) async throws -> (kernelURL: URL, initrdURL: URL) {
        let kernelURL = tempDir.appendingPathComponent("vmlinuz")
        let initrdURL = tempDir.appendingPathComponent("initrd.gz")
        
        if FileManager.default.fileExists(atPath: kernelURL.path) && FileManager.default.fileExists(atPath: initrdURL.path) {
            return (kernelURL, initrdURL)
        }

        vm.addLog("Extracting installer contents...")
        
        let kernelPaths = vm.selectedDistro == .debian13 ? ["install.a64/vmlinuz", "install/vmlinuz"] : ["boot/vmlinuz-virt"]
        let initrdPaths = vm.selectedDistro == .debian13 ? ["install.a64/initrd.gz", "install/initrd.gz"] : ["boot/initramfs-virt"]
        
        var foundKernel = false
        for path in kernelPaths {
            let result = try runProcess(executable: "/usr/bin/tar", arguments: ["-xf", isoURL.path, "-C", tempDir.path, path])
            if result.exitCode == 0 {
                let extracted = tempDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: extracted.path) {
                    try? FileManager.default.removeItem(at: kernelURL)
                    try FileManager.default.moveItem(at: extracted, to: kernelURL)
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
                    foundInitrd = true
                    break
                }
            }
        }
        
        if foundKernel && foundInitrd {
            return (kernelURL, initrdURL)
        }
        
        throw VMError.configurationInvalid("Failed to extract installer resources.")
    }

    private func injectPreseed(into initrdURL: URL, isMaster: Bool, vm: VirtualMachine) throws {
        let token = clusterToken
        let masterIP = virtualMachines.first(where: { $0.isMaster })?.ipAddress ?? "192.168.64.2"
        let k3sCommand = isMaster ? 
            "curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 --cluster-init --token \(token) --disable traefik" :
            "curl -sfL https://get.k3s.io | K3S_URL=https://\(masterIP):6443 K3S_TOKEN=\(token) sh -"

        let preseed = """
        d-i debian-installer/locale string en_US
        d-i keyboard-configuration/xkb-keymap select us
        d-i netcfg/choose_interface select auto
        d-i netcfg/link_wait_timeout string 60
        d-i netcfg/dhcp_timeout string 60
        d-i netcfg/dhcpv6_timeout string 1
        d-i netcfg/get_nameservers string 8.8.8.8 1.1.1.1
        d-i netcfg/get_domain string local
        d-i netcfg/get_hostname string \(isMaster ? "mlv-master" : "mlv-node")
        d-i mirror/country string manual
        d-i mirror/http/hostname string deb.debian.org
        d-i mirror/http/directory string /debian
        d-i mirror/http/proxy string
        d-i mirror/suite string trixie
        d-i mirror/udeb/suite string trixie
        d-i apt-setup/use_mirror boolean true
        d-i apt-setup/cdrom/set-first boolean false
        d-i apt-setup/services-select multiselect security, updates
        d-i apt-setup/security_host string security.debian.org
        d-i apt-setup/security_path string /debian-security
        d-i apt-setup/non-free-firmware boolean true
        d-i apt-setup/contrib boolean true
        d-i apt-setup/non-free boolean true
        d-i passwd/user-fullname string MLV Admin
        d-i passwd/username string mlv
        d-i passwd/user-password password mlv
        d-i passwd/user-password-again password mlv
        d-i partman-auto/disk string /dev/vda
        d-i partman-auto/method string regular
        d-i partman/confirm_write_new_label boolean true
        d-i partman/choose_partition select finish
        d-i partman/confirm boolean true
        d-i partman/confirm_nooverwrite boolean true
        d-i pkgsel/include string sudo grub-efi-arm64
        d-i preseed/late_command string in-target bash -c "cat > /etc/apt/sources.list <<'EOF'\ndeb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware\ndeb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware\ndeb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware\nEOF"; in-target bash -c "\(k3sCommand)"; echo "---MLV_INSTALL_DONE---" > /dev/hvc0
        d-i finish-install/reboot_in_progress note
        d-i debian-installer/exit/poweroff boolean true
        """
        
        let tempDir = initrdURL.deletingLastPathComponent()
        let preseedFile = tempDir.appendingPathComponent("preseed.cfg")
        try preseed.write(to: preseedFile, atomically: true, encoding: .utf8)
        
        let shellCmd = "cd \"\(tempDir.path)\" && echo preseed.cfg | cpio -o -H newc > preseed.cpio && cat \"\(initrdURL.path)\" preseed.cpio > initrd_combined.gz"
        _ = try runProcess(executable: "/bin/sh", arguments: ["-c", shellCmd])
        
        try? FileManager.default.removeItem(at: initrdURL)
        try FileManager.default.moveItem(at: tempDir.appendingPathComponent("initrd_combined.gz"), to: initrdURL)
    }

    private func createUbuntuNoCloudSeedISO(in vmTempDir: URL, vm: VirtualMachine, masterIP: String) throws -> URL {
        let seedDir = vmTempDir.appendingPathComponent("nocloud-seed")
        try? FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
        
        let userData = "#cloud-config\nautoinstall:\n  version: 1\n  identity:\n    hostname: \(vm.name)\n    username: mlv\n    password: \"$1$WDmB6AfA$d7Ef1wCrtPJdipFSttNJC.\""
        try userData.write(to: seedDir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try "instance-id: \(vm.id.uuidString)".write(to: seedDir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        
        let seedISOURL = vmTempDir.appendingPathComponent("cidata.iso")
        _ = try runProcess(executable: "/usr/bin/hdiutil", arguments: ["makehybrid", "-iso", "-joliet", "-o", seedISOURL.path, seedDir.path])
        return seedISOURL
    }

    private func runProcess(executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        try process.run()
        process.waitUntilExit()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(exitCode: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }
    
    func stopVM(_ vm: VirtualMachine) async throws {
        vm.userInitiatedStop = true
        try await vm.vzVirtualMachine?.stop()
        vm.state = .stopped
        wgControlForwarders[vm.id]?.stop()
        wgControlForwarders[vm.id] = nil
        wgDataForwarders[vm.id]?.stop()
        wgDataForwarders[vm.id] = nil
        terminalConsoleServers[vm.id]?.stop()
        terminalConsoleServers[vm.id] = nil
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
