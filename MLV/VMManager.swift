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

    private init() {
        loadBookmark()
        startDataPolling()
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
        
        // Command to get IP, DNS, Gateway, and K8s Pods in one block
        // We use a unique marker to parse the output
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
        
        vm.addLog("Requesting installer diagnostics (Syslog + Preseed)...")
        
        // Comprehensive diagnostic command for installer failures
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
    
    private func parsePollingData(_ output: String, for vm: VirtualMachine) {
        guard let startRange = output.range(of: "---POLL_START---"),
              let endRange = output.range(of: "---POLL_END---") else { return }
        
        let rawContent = output[startRange.upperBound..<endRange.lowerBound]
        let lines = rawContent.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        // Expected format:
        // Line 1: IP
        // Line 2: Gateway
        // Line 3: DNS
        // Remaining: Pods (Namespace Name Status CPU RAM)
        
        if lines.count >= 3 {
            vm.ipAddress = lines[0]
            vm.gateway = lines[1]
            vm.dns = lines[2].components(separatedBy: " ")
            vm.isConnected = true
            
            // Handle Pods
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
    
    private func processInstallerDiagnostics(_ diagBlock: String, for vm: VirtualMachine) {
        let lines = diagBlock.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        vm.addLog("--- INSTALLER DIAGNOSTICS START ---")
        for line in lines {
            // Ignore echo commands and markers
            if line.contains("DIAG_START") || line.contains("DIAG_END") { continue }
            
            if line.hasPrefix("[") && line.hasSuffix("]") {
                vm.addLog("Category: \(line)")
            } else {
                vm.addLog("  \(line)")
            }
        }
        vm.addLog("--- INSTALLER DIAGNOSTICS END ---")
        
        // Detailed Root Cause Analysis
        if diagBlock.contains("could not resolve") {
            vm.addLog("ROOT CAUSE: DNS Resolution Failure. The installer cannot find 'deb.debian.org'. Check host internet and DNS settings.", isError: true)
        } else if diagBlock.contains("404 Not Found") {
            vm.addLog("ROOT CAUSE: Mirror Suite Mismatch (404). The 'testing' or 'trixie' suite might not be available on the selected mirror yet.", isError: true)
        } else if diagBlock.contains("Connection refused") || diagBlock.contains("Connection timed out") {
            vm.addLog("ROOT CAUSE: Network Connectivity Issue. The installer is being blocked by a firewall or NAT gateway.", isError: true)
        } else if diagBlock.contains("User data is not supported") {
            vm.addLog("ADVICE: Ignore DIError code 45; it is a harmless macOS metadata warning and does not affect the Linux install.", isError: false)
        }
        
        if diagBlock.contains("[PRESEED_CONTENT]") {
            let hasOnlineMirror = diagBlock.contains("deb.debian.org") || diagBlock.contains("mirror/http/hostname string deb.debian.org")
            let hasOfflineMirror = diagBlock.contains("apt-setup/no_mirror boolean true") || diagBlock.contains("apt-setup/use_mirror boolean false")
            if !(hasOnlineMirror || hasOfflineMirror) {
                vm.addLog("CRITICAL: Mirror configuration is missing from the injected preseed!", isError: true)
            }
        }
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
    
    // Use the embedded template ISO for Debian 13 only
    private func templateISOURL(for distro: VirtualMachine.LinuxDistro) -> URL? {
        // As per user request: only Debian 13 uses the uploaded/local ISO
        guard distro == .debian13 else { return nil }
        
        let isoName = "debian-13.1.0-arm64-netinst"
        
        // 1. Try Bundle
        if let bundleURL = Bundle.main.url(forResource: isoName, withExtension: "iso") {
            return bundleURL
        }
        
        // 2. Try User-Authorized Bookmark
        if let authorized = authorizedISOURL {
            return authorized
        }
        
        // 3. Try Absolute User Path
        let userName = NSUserName()
        let specificPath = URL(fileURLWithPath: "/Users/\(userName)/Desktop/MLV/MLV/\(isoName).iso")
        if FileManager.default.fileExists(atPath: specificPath.path) {
            return specificPath
        }
        
        return nil
    }

    private func isoCacheDirectory() throws -> URL {
        let containerDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let cacheDir = containerDir.appendingPathComponent("mlv-iso-cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
        }
        return cacheDir
    }

    private func cacheFileName(for distro: VirtualMachine.LinuxDistro) -> String {
        switch distro {
        case .debian13: return "debian-13.1.0-arm64-netinst.iso"
        case .alpine: return "alpine-virt-3.20.0-aarch64.iso"
        case .ubuntu: return "ubuntu-24.04.1-live-server-arm64.iso"
        case .minimal: return "k3os-arm64.iso"
        }
    }

    private func ensureCachedInstallerISO(for vm: VirtualMachine, cacheDir: URL) async throws -> URL {
        let cachedURL = cacheDir.appendingPathComponent(cacheFileName(for: vm.selectedDistro))

        let minBytes: UInt64 = {
            switch vm.selectedDistro {
            case .debian13: return 300 * 1024 * 1024
            case .alpine: return 30 * 1024 * 1024
            case .ubuntu: return 500 * 1024 * 1024
            case .minimal: return 80 * 1024 * 1024
            }
        }()

        if let attrs = try? FileManager.default.attributesOfItem(atPath: cachedURL.path),
           let size = attrs[.size] as? UInt64 {
            if size >= minBytes {
                vm.addLog("Using cached ISO (\(size / 1024 / 1024) MB).")
                return cachedURL
            } else if size > 0 {
                vm.addLog("Cached ISO is too small (\(size / 1024 / 1024) MB). Re-downloading...", isError: true)
                try? FileManager.default.removeItem(at: cachedURL)
            }
        }

        if FileManager.default.fileExists(atPath: cachedURL.path) {
            try? FileManager.default.removeItem(at: cachedURL)
        }

        if vm.selectedDistro == .debian13 {
            guard let local = templateISOURL(for: .debian13) else {
                throw VMError.configurationInvalid("Debian ISO not authorized. Upload Debian ISO first.")
            }
            vm.addLog("Caching Debian ISO for reuse...")
            try streamCopy(from: local, to: cachedURL)
            removeQuarantine(from: cachedURL)
            return cachedURL
        }

        guard let mirror = vm.selectedDistro.mirrorURL else {
            throw VMError.configurationInvalid("No mirror URL available for \(vm.selectedDistro.rawValue).")
        }

        vm.downloadTask = Task {
            try await downloadISO(from: mirror, to: cachedURL, vm: vm)
        }
        try await vm.downloadTask?.value
        vm.downloadTask = nil
        removeQuarantine(from: cachedURL)
        return cachedURL
    }
    
    func createLinuxVM(name: String? = nil, cpus: Int = 4, ramGB: Int = 8, sysDiskGB: Int = 64, dataDiskGB: Int = 100, isMaster: Bool = false, distro: VirtualMachine.LinuxDistro = .debian13, networkType: HostResources.NetworkInterface.InterfaceType = .ethernet, bsdName: String = "en0", networkSpeed: String = "10 Gbps") async throws -> VirtualMachine {
        if !VZVirtualMachine.isSupported {
            throw VMError.virtualizationNotSupported
        }
        
        // 1. Determine ISO Source
        let localISO = templateISOURL(for: distro)
        let mirrorURL = distro.mirrorURL
        
        guard localISO != nil || mirrorURL != nil else {
            throw VMError.configurationInvalid("No ISO source available for \(distro.rawValue).")
        }
        
        let vmName = name ?? "Node \(virtualMachines.count + 1)"
        // If we don't have a local ISO yet, we'll use a placeholder URL and update it during startVM if needed
        let initialISO = localISO ?? mirrorURL!
        
        let vm = VirtualMachine(name: vmName, isoURL: initialISO, cpus: cpus, ramGB: ramGB, sysDiskGB: sysDiskGB, dataDiskGB: dataDiskGB)
        vm.isMaster = isMaster
        vm.selectedDistro = distro
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
    
    private func downloadISO(from url: URL, to destination: URL, vm: VirtualMachine) async throws {
        vm.addLog("Downloading \(vm.selectedDistro.rawValue) ISO from mirror...")
        
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw VMError.configurationInvalid("Mirror download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        
        let totalBytes = httpResponse.expectedContentLength
        var downloadedBytes: Int64 = 0
        let startTime = Date()
        
        // Ensure the file exists before creating FileHandle
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        
        let fileHandle = try FileHandle(forWritingTo: destination)
        try fileHandle.truncate(atOffset: 0)
        
        var buffer = Data()
        let bufferSize = 1024 * 1024 // 1MB buffer
        var lastLogTime = Date()
        
        for try await byte in bytes {
            // Check for cancellation
            if Task.isCancelled {
                try fileHandle.close()
                try? FileManager.default.removeItem(at: destination)
                vm.addLog("Download cancelled by user.", isError: true)
                throw CancellationError()
            }
            
            buffer.append(byte)
            downloadedBytes += 1
            
            if buffer.count >= bufferSize {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                
                let now = Date()
                let timeElapsed = now.timeIntervalSince(startTime)
                let speed = Double(downloadedBytes) / timeElapsed // bytes per second
                let remainingBytes = totalBytes - downloadedBytes
                let eta = remainingBytes > 0 ? Double(remainingBytes) / speed : 0
                
                let progress = Double(downloadedBytes) / Double(totalBytes)
                
                await MainActor.run {
                    let newProgress = 0.05 + (progress * 0.15)
                    vm.deploymentProgress = min(1.0, max(0.0, newProgress))
                    vm.downloadPercent = Int(progress * 100)
                    vm.downloadSpeedMBps = speed / (1024 * 1024)
                    vm.downloadETASeconds = max(0, Int(eta))
                    
                    if now.timeIntervalSince(lastLogTime) >= 2.0 {
                        lastLogTime = now
                        let speedMB = speed / (1024 * 1024)
                        let etaMin = Int(eta) / 60
                        let etaSec = Int(eta) % 60
                        
                        vm.addLog(String(format: "Download: %d%% (%.1f MB/s) ETA: %dm %ds", Int(progress * 100), speedMB, etaMin, etaSec))
                    }
                }
            }
        }
        
        // Write remaining buffer
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }
        
        try fileHandle.close()
        vm.addLog("Download complete.")
        await MainActor.run {
            vm.downloadPercent = 100
            vm.downloadETASeconds = 0
        }
        await MainActor.run {
            AppNotifications.shared.notify(title: "Download Complete", body: "\(vm.name): \(vm.selectedDistro.rawValue) ISO ready")
        }
    }

    private func formatNSError(_ error: Error) -> String {
        let ns = error as NSError
        var parts: [String] = []
        parts.append("description=\(ns.localizedDescription)")
        parts.append("domain=\(ns.domain)")
        parts.append("code=\(ns.code)")
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=(domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription))")
        }
        return parts.joined(separator: " | ")
    }

    private func createUbuntuNoCloudSeedISO(in vmTempDir: URL, vm: VirtualMachine, masterIP: String) throws -> URL {
        let seedDir = vmTempDir.appendingPathComponent("nocloud-seed", isDirectory: true)
        if FileManager.default.fileExists(atPath: seedDir.path) {
            try? FileManager.default.removeItem(at: seedDir)
        }
        try FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true, attributes: nil)

        let host = vm.isMaster ? "mlv-master" : "mlv-node"
        let token = clusterToken
        let k3sJoin = vm.isMaster
        ? "curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 --cluster-init --token \(token) --disable traefik"
        : "curl -sfL https://get.k3s.io | K3S_URL=https://\(masterIP):6443 K3S_TOKEN=\(token) sh -"

        let userData = """
        #cloud-config
        autoinstall:
          version: 1
          identity:
            hostname: \(host)
            username: mlv
            password: "$1$WDmB6AfA$d7Ef1wCrtPJdipFSttNJC."
          ssh:
            install-server: true
            allow-pw: true
          storage:
            layout:
              name: direct
          packages:
            - curl
            - sudo
            - open-iscsi
            - nfs-common
          late-commands:
            - curtin in-target --target=/target -- bash -c "echo 'mlv ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/mlv"
            - curtin in-target --target=/target -- bash -c "echo '\(masterIP) mlv-master' >> /etc/hosts"
            - curtin in-target --target=/target -- bash -c "\(k3sJoin)"
        """

        let metaData = """
        instance-id: \(vm.id.uuidString)
        local-hostname: \(host)
        """

        try userData.write(to: seedDir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try metaData.write(to: seedDir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)

        let seedISOURL = vmTempDir.appendingPathComponent("cidata.iso")
        if FileManager.default.fileExists(atPath: seedISOURL.path) {
            try? FileManager.default.removeItem(at: seedISOURL)
        }

        let result = try runProcess(executable: "/usr/bin/hdiutil", arguments: [
            "makehybrid",
            "-iso",
            "-joliet",
            "-default-volume-name",
            "cidata",
            "-o",
            seedISOURL.path,
            seedDir.path
        ])
        if result.exitCode != 0 {
            throw VMError.configurationInvalid("Failed to create Ubuntu seed ISO: \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }

        return seedISOURL
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

                // Check if this was a clean exit after installation
                // The console parser might have already set isInstalled = true
                if vm.isInstalled {
                    vm.addLog("System rebooting into OS mode...")
                    if vm.pendingAutoStartAfterInstall {
                        vm.pendingAutoStartAfterInstall = false
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            try? await self.startVM(vm)
                        }
                    } else if !vm.userInitiatedStop {
                        Task { @MainActor in
                            AppNotifications.shared.notify(title: "VM Stopped", body: "\(vm.name) stopped unexpectedly")
                        }
                    }
                } else {
                    vm.addLog("Node stopped. If installation finished, it will boot from disk next time.")
                }
                vm.userInitiatedStop = false
            }
            
            vm.addLog("Launching virtualization engine...")
            try await v.start()
            vm.addLog("Virtual Machine process is now running.")
            vm.deploymentProgress = 0.25
            vm.state = .running
        } catch {
            vm.addLog("ERROR: \(formatNSError(error))", isError: true)
            vm.state = .error((error as NSError).localizedDescription)
            AppNotifications.shared.notify(title: "VM Error", body: "\(vm.name): \((error as NSError).localizedDescription)")
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

    private func persistentMACAddress(for vm: VirtualMachine, in directory: URL) throws -> VZMACAddress {
        let macURL = directory.appendingPathComponent("mac-address.txt")

        if let existing = try? String(contentsOf: macURL, encoding: String.Encoding.utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let mac = VZMACAddress(string: existing) {
            return mac
        }

        let generated = String(
            format: "02:%02x:%02x:%02x:%02x:%02x",
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255),
            UInt8.random(in: 0...255)
        )

        try generated.write(to: macURL, atomically: true, encoding: String.Encoding.utf8)

        guard let mac = VZMACAddress(string: generated) else {
            throw VMError.configurationInvalid("Failed to create persistent MAC address")
        }

        return mac
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
        
        let cacheDir = try isoCacheDirectory()
        let cachedISOURL = try await ensureCachedInstallerISO(for: vm, cacheDir: cacheDir)
        
        let stagedISOURL = vmTempDir.appendingPathComponent("installer.iso")
        var needsStaging = true
        if let attrs = try? FileManager.default.attributesOfItem(atPath: stagedISOURL.path),
           let size = attrs[.size] as? UInt64,
           size > 10 * 1024 * 1024 {
            needsStaging = false
            vm.addLog("Staged ISO exists (\(size / 1024 / 1024) MB).")
        } else {
            try? FileManager.default.removeItem(at: stagedISOURL)
        }
        
        if needsStaging {
            vm.addLog("Staging ISO to node storage...")
            vm.deploymentProgress = 0.2
            try streamCopy(from: cachedISOURL, to: stagedISOURL)
            removeQuarantine(from: stagedISOURL)
            
            let attrs = try FileManager.default.attributesOfItem(atPath: stagedISOURL.path)
            let size = attrs[.size] as? UInt64 ?? 0
            vm.addLog("Staging successful (\(size / 1024 / 1024) MB).")
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

        var ubuntuSeedISOURL: URL? = nil
        let masterIP: String = {
            if vm.isMaster { return "192.168.64.2" }
            if let masterVM = virtualMachines.first(where: { $0.isMaster }), masterVM.ipAddress != "Detecting..." {
                return masterVM.ipAddress
            }
            return "192.168.64.2"
        }()

        if vm.isInstalled {
            // Normal boot using EFI
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = variableStore
            config.bootLoader = bootLoader
            vm.addLog("Configured for EFI Disk Boot.")
        } else {
            // First time boot - automated install
            // Branch logic based on Distro
            switch vm.selectedDistro {
            case .debian13:
                vm.addLog("Extracting installer kernel/initrd for \(vm.selectedDistro.rawValue)...")
                vm.deploymentProgress = 0.3
                let (kernelURL, initrdURL) = try await extractKernelAndInitrd(from: stagedISOURL, to: vmTempDir, vm: vm)
                
                vm.addLog("Injecting Debian preseed...")
                try injectPreseed(into: initrdURL, isMaster: vm.isMaster, vm: vm)
                
                let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
                bootLoader.initialRamdiskURL = initrdURL
                bootLoader.commandLine = "auto=true priority=critical console=hvc0 console=tty0 earlycon=virtio_console video=1280x720 DEBIAN_FRONTEND=text preseed/file=/preseed.cfg iommu.passthrough=1 ipv6.disable=1 random.trust_cpu=on systemd.show_status=1 netcfg/link_wait_timeout=10 netcfg/dhcp_timeout=30 hw-detect/load_firmware=false"
                config.bootLoader = bootLoader
                
            case .ubuntu:
                vm.addLog("Configuring Ubuntu Autoinstall via EFI...")
                vm.deploymentProgress = 0.3
                ubuntuSeedISOURL = try createUbuntuNoCloudSeedISO(in: vmTempDir, vm: vm, masterIP: masterIP)
                let bootLoader = VZEFIBootLoader()
                bootLoader.variableStore = variableStore
                config.bootLoader = bootLoader
                
            case .alpine, .minimal:
                vm.addLog("Configuring \(vm.selectedDistro.rawValue) via EFI...")
                vm.deploymentProgress = 0.3
                let bootLoader = VZEFIBootLoader()
                bootLoader.variableStore = variableStore
                config.bootLoader = bootLoader
            }
            
            vm.addLog("Configured for \(vm.selectedDistro.rawValue) Automated Installation.")
        }
        
        // Storage - attach the staged installer ISO plus a writable system disk.
        // If the system is already installed, we detach the ISO to prevent reboot loops.
        var storageDevices: [VZStorageDeviceConfiguration] = []
        
        let systemDiskURL = vmTempDir.appendingPathComponent("system.raw")
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
        storageDevices.append(systemDiskDevice)
        
        // Add a secondary data disk for Longhorn/Storage
        let dataDiskURL = vmTempDir.appendingPathComponent("data.raw")
        if !FileManager.default.fileExists(atPath: dataDiskURL.path) {
            FileManager.default.createFile(atPath: dataDiskURL.path, contents: nil)
            let fileHandle = try? FileHandle(forWritingTo: dataDiskURL)
            try? fileHandle?.truncate(atOffset: UInt64(vm.dataDiskSizeGB) * 1024 * 1024 * 1024)
            try? fileHandle?.close()
        }
        
        if let dataAttachment = try? VZDiskImageStorageDeviceAttachment(url: dataDiskURL, readOnly: false) {
            let dataDevice = VZVirtioBlockDeviceConfiguration(attachment: dataAttachment)
            storageDevices.append(dataDevice)
        }
        
        // Only attach ISO if we are NOT installed
        if !vm.isInstalled {
            let isoAttachment: VZDiskImageStorageDeviceAttachment
            do {
                isoAttachment = try VZDiskImageStorageDeviceAttachment(
                    url: stagedISOURL,
                    readOnly: true
                )
                let isoDevice = VZVirtioBlockDeviceConfiguration(attachment: isoAttachment)
                storageDevices.append(isoDevice)
                vm.addLog("Attached installer ISO for deployment.")
            } catch {
                vm.addLog("Failed to attach ISO: \(error.localizedDescription)", isError: true)
                throw VMError.configurationInvalid("Failed to attach ISO: \(error.localizedDescription)")
            }

            if vm.selectedDistro == .ubuntu, let seedURL = ubuntuSeedISOURL {
                do {
                    let seedAttachment = try VZDiskImageStorageDeviceAttachment(url: seedURL, readOnly: true)
                    let seedDevice = VZVirtioBlockDeviceConfiguration(attachment: seedAttachment)
                    storageDevices.append(seedDevice)
                    vm.addLog("Attached NoCloud seed ISO.")
                } catch {
                    throw VMError.configurationInvalid("Failed to attach Ubuntu seed ISO: \(error.localizedDescription)")
                }
            }
        } else {
            vm.addLog("ISO detached for OS boot.")
        }
        
        config.storageDevices = storageDevices
        
        // Network - High-Performance Private NAT (Standard)
        // Note: Bridged networking requires a restricted Apple entitlement (com.apple.vm.networking)
        // which is only available to organizations with specific managed profiles.
        // NAT provides a private virtual switch (192.168.64.x) where all VMs can talk to each other.
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        vm.connectionType = "Private Cluster NAT"
        
        // Set a MAC address for stability in K8s clusters
        networkDevice.macAddress = try persistentMACAddress(for: vm, in: vmTempDir)
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
                    
                    // Parse polling data from the recent buffer
                    if vm.consoleOutput.contains("---POLL_START---") && vm.consoleOutput.contains("---POLL_END---") {
                        if let startRange = vm.consoleOutput.range(of: "---POLL_START---"),
                           let endRange = vm.consoleOutput.range(of: "---POLL_END---", options: .backwards) {
                            let block = String(vm.consoleOutput[startRange.lowerBound..<endRange.upperBound])
                            self.parsePollingData(block, for: vm)
                            
                            // Remove the parsed block from console output to keep it clean
                            vm.consoleOutput.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: "")
                        }
                    }
                    
                    // Parse Installer Diagnostics
                    if vm.consoleOutput.contains("---DIAG_START---") && vm.consoleOutput.contains("---DIAG_END---") {
                        if let startRange = vm.consoleOutput.range(of: "---DIAG_START---"),
                           let endRange = vm.consoleOutput.range(of: "---DIAG_END---", options: .backwards) {
                            let diagBlock = String(vm.consoleOutput[startRange.upperBound..<endRange.lowerBound])
                            self.processInstallerDiagnostics(diagBlock, for: vm)
                            vm.consoleOutput.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: "")
                        }
                    }
                    
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
                        } else if str.localizedCaseInsensitiveContains("---MLV_INSTALL_BOOT_FAIL---") {
                            vm.addLog("Bootloader install failed. VM will not boot from disk.", isError: true)
                            vm.needsUserInteraction = true
                        } else if str.localizedCaseInsensitiveContains("---MLV_INSTALL_DONE---") {
                            vm.addLog("Deployment finalized. Switching to disk boot.")
                            vm.isInstalled = true
                            vm.pendingAutoStartAfterInstall = true
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
        // Cancel any active download
        vm.downloadTask?.cancel()
        vm.downloadTask = nil
        vm.userInitiatedStop = true
        
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

        vm.addLog("Extracting \(vm.selectedDistro.rawValue) installer contents...")
        
        // Distro-specific installer paths
        var kernelPaths: [String] = []
        var initrdPaths: [String] = []
        
        switch vm.selectedDistro {
        case .debian13:
            kernelPaths = ["install.a64/vmlinuz", "install/vmlinuz"]
            initrdPaths = ["install.a64/initrd.gz", "install/initrd.gz"]
        case .alpine:
            kernelPaths = ["boot/vmlinuz-virt"]
            initrdPaths = ["boot/initramfs-virt"]
        case .ubuntu:
            kernelPaths = ["casper/vmlinuz"]
            initrdPaths = ["casper/initrd"]
        case .minimal:
            kernelPaths = ["k3os/vmlinuz"]
            initrdPaths = ["k3os/initrd"]
        }
        
        // Add defaults as fallbacks
        kernelPaths.append(contentsOf: ["vmlinuz", "install/vmlinuz"])
        initrdPaths.append(contentsOf: ["initrd.gz", "initrd", "install/initrd.gz"])

        // Use 'tar' to extract. bsdtar on macOS can read ISOs and is sandbox-friendly
        // Unlike hdiutil, it doesn't need to 'mount' a device.
        // We use -O to stream to file which is more reliable in some cases
        
        var foundKernel = false
        for path in kernelPaths {
            vm.addLog("Searching for kernel at: \(path)...")
            let result = try runProcess(executable: "/usr/bin/tar", arguments: ["-xf", isoURL.path, "-C", tempDir.path, path])
            if result.exitCode == 0 {
                let extracted = tempDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: extracted.path) {
                    try? FileManager.default.removeItem(at: kernelURL)
                    try FileManager.default.moveItem(at: extracted, to: kernelURL)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kernelURL.path)
                    vm.addLog("Kernel extracted successfully.")
                    foundKernel = true
                    break
                }
            }
        }

        var foundInitrd = false
        for path in initrdPaths {
            vm.addLog("Searching for initrd at: \(path)...")
            let result = try runProcess(executable: "/usr/bin/tar", arguments: ["-xf", isoURL.path, "-C", tempDir.path, path])
            if result.exitCode == 0 {
                let extracted = tempDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: extracted.path) {
                    try? FileManager.default.removeItem(at: initrdURL)
                    try FileManager.default.moveItem(at: extracted, to: initrdURL)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: initrdURL.path)
                    vm.addLog("Initrd extracted successfully.")
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
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: kernelURL.path)
                vm.addLog("Kernel extracted via hdiutil.")
                foundKernel = true
                break
            }
        }

        for path in initrdPaths {
            let src = mountPoint.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: initrdURL)
                try FileManager.default.copyItem(at: src, to: initrdURL)
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: initrdURL.path)
                vm.addLog("Initrd extracted via hdiutil.")
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
        vm.addLog("Generating ultra-robust preseed.cfg...")
        
        // Find Master IP if we are a worker node
        var masterIP = "192.168.64.2" // Default NAT Master IP fallback
        if !isMaster {
            if let masterVM = virtualMachines.first(where: { $0.isMaster }), masterVM.ipAddress != "Detecting..." {
                masterIP = masterVM.ipAddress
                vm.addLog("Found Master Node at: \(masterIP)")
            } else {
                vm.addLog("Master IP not yet detected. Using default NAT gateway fallback: \(masterIP)")
            }
        }
        
        let token = clusterToken
        let k3sCommand = isMaster ? 
            "curl -sfL --connect-timeout 5 --max-time 120 --retry 3 --retry-delay 2 https://get.k3s.io | sh -s - --write-kubeconfig-mode 644 --cluster-init --token \(token) --disable traefik || true" :
            "curl -sfL --connect-timeout 5 --max-time 120 --retry 3 --retry-delay 2 https://get.k3s.io | K3S_URL=https://\(masterIP):6443 K3S_TOKEN=\(token) sh - || true"
            
        let preseed = """
        # Locale & Keyboard
        d-i debian-installer/locale string en_US
        d-i keyboard-configuration/xkb-keymap select us
        
        # --- DIRECT NAT/DHCP REPAIR ---
        d-i preseed/early_command string anna-install busybox-udeb; IFACE=$(list-devices net | head -n 1); ip link set dev "$IFACE" up || true; udhcpc -i "$IFACE" -n -q || true; echo "nameserver 8.8.8.8" > /etc/resolv.conf
        
        # --- ZERO-TOUCH NETWORK & MIRROR CONFIG ---
        d-i debconf/priority string critical
        d-i netcfg/enable_ipv6 boolean false
        d-i netcfg/choose_interface select auto
        d-i netcfg/link_wait_timeout string 10
        d-i netcfg/dhcp_timeout string 30
        d-i netcfg/get_hostname string \(isMaster ? "mlv-master" : "mlv-node")
        d-i netcfg/get_domain string local
        
        # Reliable DNS
        d-i netcfg/get_nameservers string 8.8.8.8
        d-i netcfg/confirm_static boolean true
        
        # --- OFFLINE-FIRST INSTALL (BYPASS MIRROR) ---
        # The 'netinst' ISO is minimal, but we tell it to try to finish
        # even without an internet mirror.
        d-i mirror/country string manual
        d-i mirror/http/hostname string
        d-i mirror/http/directory string
        d-i mirror/http/proxy string
        
        # Don't halt on mirror errors if packages are missing
        d-i mirror/error/ignore boolean true
        
        d-i apt-setup/use_mirror boolean false
        d-i apt-setup/no_mirror boolean true
        d-i apt-setup/non-free-firmware boolean true
        
        # Account Setup
        d-i passwd/root-login boolean false
        d-i passwd/user-fullname string MLV Admin
        d-i passwd/username string mlv
        d-i passwd/user-password password mlv
        d-i passwd/user-password-again password mlv
        d-i clock-setup/utc boolean true
        d-i time/zone string UTC
        d-i clock-setup/ntp boolean true
        
        # Partitioning (Targeting /dev/vda)
        d-i partman-auto/disk string /dev/vda
        d-i partman-auto/method string regular
        d-i partman-auto/expert_recipe string \\
            boot-root :: \\
                538 538 1075 free \\
                    $iflabel{ gpt } \\
                    $reusemethod{ } \\
                    method{ efi } \\
                    format{ } \\
                . \\
                1000 10000 -1 ext4 \\
                    $lvmok{ } \\
                    method{ format } \\
                    format{ } \\
                    use_filesystem{ } \\
                    filesystem{ ext4 } \\
                    mountpoint{ / } \\
                . \\
                100% 512 200% linux-swap \\
                    $lvmok{ } \\
                    method{ swap } \\
                    format{ } \\
                .
        d-i partman-auto/choose_recipe select boot-root
        
        d-i partman-lvm/device_remove_lvm boolean true
        d-i partman-md/device_remove_md boolean true
        d-i partman-lvm/confirm boolean true
        d-i partman-lvm/confirm_nooverwrite boolean true
        
        d-i partman-partitioning/confirm_write_new_label boolean true
        d-i partman/choose_partition select finish
        d-i partman/confirm boolean true
        d-i partman/confirm_nooverwrite boolean true
        d-i partman/confirm_write_new_label boolean true
        d-i partman-basicfilesystems/no_mount_point boolean false
        
        # Minimal Software Selection (only what is on ISO)
        d-i pkgsel/include string sudo grub-efi-arm64
        d-i pkgsel/upgrade select none
        
        # --- LATE COMMAND AUTOMATION ---
        d-i preseed/late_command string cp /mlv-postinstall.sh /target/root/mlv-postinstall.sh; chmod +x /target/root/mlv-postinstall.sh; in-target /root/mlv-postinstall.sh && echo "---MLV_INSTALL_DONE---" > /dev/hvc0 || echo "---MLV_INSTALL_BOOT_FAIL---" > /dev/hvc0

        d-i grub-installer/only_debian boolean true
        d-i grub-installer/with_other_os boolean true
        d-i grub-installer/force-efi-extra-removable boolean true
        d-i grub-installer/update-nvram boolean false
        d-i partman-efi/non_efi_system boolean true
        d-i finish-install/reboot_in_progress note
        d-i cdrom-detect/eject boolean false
        d-i debian-installer/exit/poweroff boolean true
        """
        
        let tempDir = initrdURL.deletingLastPathComponent()
        let preseedFile = tempDir.appendingPathComponent("preseed.cfg")
        try preseed.write(to: preseedFile, atomically: true, encoding: .utf8)
        
        let postinstallScript = """
        #!/bin/bash
        set +e

        IFACE=$(ls /sys/class/net | grep -E "^(en|eth)" | head -n 1)
        if [ -z "$IFACE" ]; then
          IFACE=$(ls /sys/class/net | grep -v lo | head -n 1)
        fi

        if [ -n "$IFACE" ]; then
          ip link set dev "$IFACE" up || true
          dhclient "$IFACE" || true
        fi

        printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
        echo "mlv ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/mlv
        printf 'deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware\n' > /etc/apt/sources.list
        apt-get update || true
        apt-get install -y grub-efi-arm64 grub-efi-arm64-bin grub-common || true

        cat >/usr/local/sbin/mlv-network-repair <<'EOF'
        #!/bin/bash
        IFACE=$(ls /sys/class/net | grep -E "^(en|eth)" | head -n 1)
        if [ -z "$IFACE" ]; then
          IFACE=$(ls /sys/class/net | grep -v lo | head -n 1)
        fi
        if [ -n "$IFACE" ]; then
          ip link set dev "$IFACE" up || true
          dhclient "$IFACE" || true
        fi
        printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
        EOF
        chmod +x /usr/local/sbin/mlv-network-repair

        cat >/etc/systemd/system/mlv-network-repair.service <<'EOF'
        [Unit]
        Description=MLV Network Repair
        After=network-pre.target
        Wants=network-pre.target

        [Service]
        Type=oneshot
        ExecStart=/usr/local/sbin/mlv-network-repair
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
        EOF
        systemctl enable mlv-network-repair.service || true
        systemctl enable serial-getty@hvc0.service || true

        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
          sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=hvc0 console=tty0 systemd.show_status=1"/' /etc/default/grub
        else
          echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=hvc0 console=tty0 systemd.show_status=1"' >> /etc/default/grub
        fi

        if grep -q '^GRUB_TERMINAL=' /etc/default/grub; then
          sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL="console serial"/' /etc/default/grub
        else
          echo 'GRUB_TERMINAL="console serial"' >> /etc/default/grub
        fi

        \(k3sCommand)

        if [ "\(isMaster)" != "true" ]; then
          sed -i "s/mlv-node/mlv-node-$(tr -dc 'a-z0-9' </dev/urandom | head -c 4)/g" /etc/hostname
        fi

        sed -i "s/127.0.1.1.*/127.0.1.1 $(hostname)/g" /etc/hosts
        echo "\(masterIP) mlv-master" >> /etc/hosts

        EFI_DEV=$(blkid -t TYPE=vfat -o device | head -n 1)
        mkdir -p /boot/efi
        if [ -n "$EFI_DEV" ]; then
          mount "$EFI_DEV" /boot/efi || true
        else
          mount /dev/vda1 /boot/efi || true
        fi

        grub-install --target=arm64-efi --removable --no-nvram --efi-directory=/boot/efi
        update-grub
        test -f /boot/efi/EFI/BOOT/BOOTAA64.EFI
        """
        let postinstallFile = tempDir.appendingPathComponent("mlv-postinstall.sh")
        try postinstallScript.write(to: postinstallFile, atomically: true, encoding: .utf8)
        
        // Create a CPIO archive containing the preseed.cfg
        vm.addLog("Creating CPIO archive...")
        let cpioURL = tempDir.appendingPathComponent("preseed.cpio")
        
        // We use quoted paths to handle spaces in 'Application Support'
        let shellCmd = "cd \"\(tempDir.path)\" && printf 'preseed.cfg\nmlv-postinstall.sh\n' | cpio -o -H newc > \"\(cpioURL.path)\""
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
