import Foundation
import AppKit

enum TalosSetupStage: Int, CaseIterable, Identifiable {
    case idle = 0
    case generatingConfig = 1
    case waitingForAPI = 2
    case applyingConfig = 3
    case bootstrapping = 4
    case fetchingKubeconfig = 5
    case waitingForK8sAPI = 6
    case deployingClusterCore = 7
    case completed = 8
    case failed = 9

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .generatingConfig: return "Generating Config"
        case .waitingForAPI: return "Waiting for API"
        case .applyingConfig: return "Applying Config"
        case .bootstrapping: return "Bootstrapping"
        case .fetchingKubeconfig: return "Fetching Kubeconfig"
        case .waitingForK8sAPI: return "Waiting for K8s API"
        case .deployingClusterCore: return "Deploying ClusterCore"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var icon: String {
        switch self {
        case .idle: return "circle.dashed"
        case .generatingConfig: return "doc.badge.gearshape"
        case .waitingForAPI: return "antenna.radiowaves.left.and.right"
        case .applyingConfig: return "arrow.triangle.branch"
        case .bootstrapping: return "bolt.fill"
        case .fetchingKubeconfig: return "key.fill"
        case .waitingForK8sAPI: return "network"
        case .deployingClusterCore: return "server.rack"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var progress: Double {
        switch self {
        case .idle: return 0.0
        case .generatingConfig: return 0.125
        case .waitingForAPI: return 0.25
        case .applyingConfig: return 0.375
        case .bootstrapping: return 0.5
        case .fetchingKubeconfig: return 0.625
        case .waitingForK8sAPI: return 0.75
        case .deployingClusterCore: return 0.875
        case .completed: return 1.0
        case .failed: return 0.0
        }
    }

    /// The setup stages that show in the progress bar (excludes idle/failed/completed)
    static var progressStages: [TalosSetupStage] {
        [.generatingConfig, .waitingForAPI, .applyingConfig, .bootstrapping, .fetchingKubeconfig, .waitingForK8sAPI, .deployingClusterCore]
    }

    /// Talos-only stages (before ClusterCore)
    static var talosStages: [TalosSetupStage] {
        [.generatingConfig, .waitingForAPI, .applyingConfig, .bootstrapping, .fetchingKubeconfig]
    }

    /// ClusterCore stages
    static var clusterCoreStages: [TalosSetupStage] {
        [.waitingForK8sAPI, .deployingClusterCore]
    }
}

/// Automatically configures Talos VMs when they become available on the network.
/// Handles the full setup flow: generate config, apply config, bootstrap, fetch kubeconfig.
@Observable
final class TalosAutoSetupService {
    static let shared = TalosAutoSetupService()

    var isRunning: Bool = false
    var logs: [String] = []
    var currentStage: TalosSetupStage = .idle
    var currentVMName: String = ""
    var pendingClusterCoreVM: VirtualMachine?
    var lastClusterCoreVM: VirtualMachine?
    var clusterCoreDeployedVMs: Set<UUID> = []
    private var setupTasks: [UUID: Task<Void, Never>] = [:]
    private var completedVMs: Set<UUID> = []
    private let setupLock = NSLock()

    // Worker config received from a control plane (local or remote)
    private var _workerConfig: ClusterManager.WorkerConfigPayload?
    private let workerConfigLock = NSLock()

    private init() {
        // Auto-start disabled - manual trigger only via "Auto Setup All" button
        // startMonitoring()
    }

    // MARK: - Worker Config Sharing

    /// Called when a control plane pushes its worker config (local or via RPC)
    @MainActor
    func receiveWorkerConfig(_ config: ClusterManager.WorkerConfigPayload) {
        workerConfigLock.lock()
        _workerConfig = config
        workerConfigLock.unlock()
        appendLog("[Cluster] Worker config received for cluster '\(config.clusterName)' (control plane: \(config.controlPlaneIP))")
    }

    /// Returns the stored worker config if available
    func availableWorkerConfig() async -> ClusterManager.WorkerConfigPayload? {
        workerConfigLock.lock()
        defer { workerConfigLock.unlock() }
        return _workerConfig
    }

    func clearLogs() {
        logs.removeAll()
    }

    func appendLog(_ message: String) {
        let lines = message
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        DispatchQueue.main.async { [weak self] in
            self?.logs.append(contentsOf: lines)
        }
    }

    /// Start monitoring VMs for Talos auto-setup
    private func startMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkVMsForSetup()
        }
    }

    /// Check running VMs and trigger setup for Talos VMs with valid IPs
    private func checkVMsForSetup() {
        @MainActor
        func check() {
            for vm in VMManager.shared.virtualMachines {
                guard vm.selectedDistro == .talos,
                      vm.state == .running,
                      !isSetupCompleted(for: vm.id),
                      !isSetupInProgress(for: vm.id) else { continue }

                let ip = vm.ipAddress
                guard isValidIP(ip) else { continue }

                // Trigger async setup
                setupTasks[vm.id] = Task { [weak self] in
                    await self?.performSetup(for: vm, ip: ip)
                }
            }
        }

        if Thread.isMainThread {
            check()
        } else {
            DispatchQueue.main.async { check() }
        }
    }

    /// Check if IP is valid (not detecting/empty and looks like an IP)
    private func isValidIP(_ ip: String) -> Bool {
        guard ip != "Detecting...",
              !ip.isEmpty,
              ip.contains(".") else { return false }

        // Basic IPv4 validation
        let components = ip.split(separator: ".")
        guard components.count == 4 else { return false }

        for component in components {
            guard let num = Int(component), num >= 0, num <= 255 else { return false }
        }

        return true
    }

    private func isSetupInProgress(for vmID: UUID) -> Bool {
        setupLock.lock()
        defer { setupLock.unlock() }
        return setupTasks[vmID] != nil
    }

    private func isSetupCompleted(for vmID: UUID) -> Bool {
        setupLock.lock()
        defer { setupLock.unlock() }
        return completedVMs.contains(vmID)
    }

    private func markSetupCompleted(for vmID: UUID) {
        setupLock.lock()
        completedVMs.insert(vmID)
        setupTasks.removeValue(forKey: vmID)
        setupLock.unlock()
    }

    /// Perform the full Talos setup for a VM — routes to master or worker path based on isMaster
    @MainActor
    private func performSetup(for vm: VirtualMachine, ip: String) async {
        isRunning = true
        currentVMName = vm.name
        currentStage = .idle

        do {
            try await ensureTalosctlAvailable()
            if vm.isMaster {
                try await performMasterSetup(for: vm, ip: ip)
            } else {
                try await performWorkerSetup(for: vm, ip: ip)
            }
        } catch {
            currentStage = .failed
            vm.addLog("Talos auto-setup failed: \(error.localizedDescription)", isError: true)
            appendLog("[\(vm.name)] Setup failed: \(error.localizedDescription)")
            setupLock.lock()
            setupTasks.removeValue(forKey: vm.id)
            setupLock.unlock()
        }

        isRunning = false
    }

    /// Full control-plane setup: gen config, apply, bootstrap, fetch kubeconfig, broadcast worker config
    @MainActor
    private func performMasterSetup(for vm: VirtualMachine, ip: String) async throws {
        appendLog("[\(vm.name)] Starting control-plane setup at \(ip)...")

        let workspace = try createWorkspaceDirectory(for: vm)
        appendLog("[\(vm.name)] Workspace: \(workspace.path)")

        currentStage = .generatingConfig
        try await generateConfig(for: vm, endpoint: "https://\(ip):6443", workspace: workspace)

        currentStage = .waitingForAPI
        appendLog("[\(vm.name)] Waiting for Talos API to be ready...")
        try await waitForTalosAPI(ip: ip, vm: vm)

        currentStage = .applyingConfig
        try await applyConfig(to: [ip], fileName: "controlplane.yaml", workspace: workspace, vm: vm)

        currentStage = .bootstrapping
        try await bootstrapCluster(bootstrapIP: ip, workspace: workspace, vm: vm)

        currentStage = .fetchingKubeconfig
        try await fetchKubeconfig(controlPlaneIP: ip, workspace: workspace, vm: vm)

        // Broadcast worker.yaml + talosconfig to all paired MLV nodes and store locally
        await broadcastWorkerConfig(clusterName: vm.name, controlPlaneIP: ip, workspace: workspace)

        markSetupCompleted(for: vm.id)
        vm.talosSetupCompleted = true
        vm.addLog("Talos control-plane setup completed")
        appendLog("[\(vm.name)] Control-plane setup complete!")

        currentStage = .fetchingKubeconfig
        pendingClusterCoreVM = vm
        appendLog("[\(vm.name)] Control plane ready - awaiting ClusterCore decision...")

        AppNotifications.shared.notify(
            id: "talos-setup-\(vm.id)",
            title: "Talos Control Plane Ready",
            body: "\(vm.name) is ready at \(ip)",
            minimumInterval: 1
        )
    }

    /// Worker setup: wait for worker config from master, apply it, done
    @MainActor
    private func performWorkerSetup(for vm: VirtualMachine, ip: String) async throws {
        appendLog("[\(vm.name)] Starting worker setup at \(ip)...")

        // Wait for worker config (master may not have bootstrapped yet)
        let config = try await waitForWorkerConfig(vm: vm)

        let workspace = try createWorkspaceDirectory(for: vm)
        appendLog("[\(vm.name)] Workspace: \(workspace.path)")

        // Write received worker.yaml and talosconfig to workspace
        let workerYAMLURL = workspace.appendingPathComponent("worker.yaml")
        let talosconfigURL = workspace.appendingPathComponent("talosconfig")
        try config.workerYAML.write(to: workerYAMLURL, atomically: true, encoding: .utf8)
        try config.talosconfigYAML.write(to: talosconfigURL, atomically: true, encoding: .utf8)
        appendLog("[\(vm.name)] Worker config written from control plane '\(config.clusterName)'")

        currentStage = .waitingForAPI
        appendLog("[\(vm.name)] Waiting for Talos maintenance API...")
        try await waitForTalosAPI(ip: ip, vm: vm)

        currentStage = .applyingConfig
        try await applyConfig(to: [ip], fileName: "worker.yaml", workspace: workspace, vm: vm)

        // Workers don't bootstrap or fetch kubeconfig — they join the existing cluster
        markSetupCompleted(for: vm.id)
        vm.talosSetupCompleted = true
        currentStage = .completed
        vm.addLog("Talos worker joined cluster '\(config.clusterName)'")
        appendLog("[\(vm.name)] Worker joined cluster '\(config.clusterName)' at \(config.controlPlaneIP)")

        AppNotifications.shared.notify(
            id: "talos-setup-\(vm.id)",
            title: "Worker Node Ready",
            body: "\(vm.name) joined cluster at \(config.controlPlaneIP)",
            minimumInterval: 1
        )
    }

    /// Wait up to 10 minutes for worker config to arrive (local or remote)
    private func waitForWorkerConfig(vm: VirtualMachine) async throws -> ClusterManager.WorkerConfigPayload {
        appendLog("[\(vm.name)] Waiting for control-plane worker config...")
        for attempt in 1...120 { // 120 x 5s = 10 minutes
            // Check local store first
            workerConfigLock.lock()
            let local = _workerConfig
            workerConfigLock.unlock()
            if let config = local {
                appendLog("[\(vm.name)] Worker config available (local)")
                return config
            }
            // Try to fetch from any paired node
            for node in ClusterManager.shared.nodes {
                if let config = try? await ClusterManager.shared.fetchWorkerConfig(from: node) {
                    workerConfigLock.lock()
                    _workerConfig = config
                    workerConfigLock.unlock()
                    appendLog("[\(vm.name)] Worker config fetched from '\(node.name)'")
                    return config
                }
            }
            appendLog("[\(vm.name)] Waiting for worker config... (\(attempt)/120)")
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw NSError(domain: "TalosAutoSetupService", code: 20, userInfo: [NSLocalizedDescriptionKey: "No worker config available after 10 minutes. Ensure control plane is set up first."])
    }

    /// After master setup, store worker config locally and push to all paired remote MLV nodes
    private func broadcastWorkerConfig(clusterName: String, controlPlaneIP: String, workspace: URL) async {
        let workerYAMLURL = workspace.appendingPathComponent("worker.yaml")
        let talosconfigURL = workspace.appendingPathComponent("talosconfig")
        guard let workerYAML = try? String(contentsOf: workerYAMLURL, encoding: .utf8),
              let talosconfigYAML = try? String(contentsOf: talosconfigURL, encoding: .utf8) else {
            appendLog("[Cluster] Warning: could not read worker.yaml or talosconfig for broadcast")
            return
        }
        let config = ClusterManager.WorkerConfigPayload(
            clusterName: clusterName,
            controlPlaneIP: controlPlaneIP,
            workerYAML: workerYAML,
            talosconfigYAML: talosconfigYAML
        )
        // Store locally so local worker VMs can use it immediately
        workerConfigLock.lock()
        _workerConfig = config
        workerConfigLock.unlock()
        appendLog("[Cluster] Worker config stored locally for cluster '\(clusterName)'")

        // Push to all paired remote MLV nodes
        let nodes = ClusterManager.shared.nodes
        for node in nodes {
            do {
                try await ClusterManager.shared.sendWorkerConfig(config, to: node)
                appendLog("[Cluster] Worker config sent to '\(node.name)'")
            } catch {
                appendLog("[Cluster] Failed to send worker config to '\(node.name)': \(error.localizedDescription)")
            }
        }
        if nodes.isEmpty {
            appendLog("[Cluster] No paired nodes — worker config stored locally only")
        }
    }

    /// User chose to deploy ClusterCore on the pending control plane VM
    @MainActor
    func deployClusterCoreAfterSetup() {
        guard let vm = pendingClusterCoreVM else { return }
        pendingClusterCoreVM = nil
        isRunning = true
        lastClusterCoreVM = vm

        Task {
            appendLog("[\(vm.name)] Deploying ClusterCore...")

            do {
                // Find ClusterCore manifest (local or download from GitHub)
                let manifestPath = await findClusterCoreManifest()
                guard let path = manifestPath else {
                    throw NSError(domain: "TalosAutoSetupService", code: 10, userInfo: [NSLocalizedDescriptionKey: "ClusterCore manifest not found and download failed. Check internet connection."])
                }

                // Wait for Kubernetes API
                currentStage = .waitingForK8sAPI
                appendLog("[\(vm.name)] Waiting for Kubernetes API to be ready...")
                appendLog("[\(vm.name)] (This can take 1-3 minutes after bootstrap)")
                try await TalosPodMonitor.shared.waitForKubernetesAPI(for: vm)

                // Generate password and pre-create secret BEFORE applying deployment
                // so the pod never starts with an empty DASHBOARD_PASSWORD
                let password = generateDashboardPassword()
                appendLog("[\(vm.name)] Pre-creating app-secrets with dashboard password...")
                try await TalosPodMonitor.shared.createNamespacesAndSecret(for: vm, password: password)

                // Now apply the full manifest (pod will start with correct secret)
                currentStage = .deployingClusterCore
                appendLog("[\(vm.name)] Applying ClusterCore manifests...")
                try await TalosPodMonitor.shared.applyManifest(for: vm, manifestPath: path)
                appendLog("[\(vm.name)] ClusterCore manifests applied successfully")

                vm.clusterCoreDashboardPassword = password
                appendLog("[\(vm.name)] ✅ Dashboard password set — save this:")
                appendLog("[\(vm.name)] 🔑 PASSWORD: \(password)")
                appendLog("[\(vm.name)] 🌐 URL: http://\(vm.ipAddress):30005")

                // Small delay then mark complete
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                clusterCoreDeployedVMs.insert(vm.id)
                vm.clusterCoreDeployed = true
                currentStage = .completed
                appendLog("[\(vm.name)] ClusterCore deployment complete!")

                // Refresh pods
                let pods = await TalosPodMonitor.shared.fetchPods(for: vm)
                vm.pods = pods

                AppNotifications.shared.notify(
                    id: "clustercore-\(vm.id)",
                    title: "ClusterCore Deployed",
                    body: "\(vm.name) has ClusterCore running",
                    minimumInterval: 1
                )

            } catch {
                currentStage = .failed
                appendLog("[\(vm.name)] ClusterCore deployment failed: \(error.localizedDescription)")
                // Restore so the user can retry from the prompt
                pendingClusterCoreVM = vm
            }

            isRunning = false
        }
    }

    /// User chose to skip ClusterCore deployment
    @MainActor
    func skipClusterCore() {
        pendingClusterCoreVM = nil
        lastClusterCoreVM = nil
        currentStage = .completed
        isRunning = false
    }

    private func findClusterCoreManifest() async -> String? {
        // Cache location
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MLV/ClusterCore")
        let cachedFile = cacheDir.appendingPathComponent("k8sdevops.yaml")

        // Try local clone first (for development)
        let localCandidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/Dimense/ClusterCore/cluster/manifests/k8sdevops.yaml").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Projects/ClusterCore/cluster/manifests/k8sdevops.yaml").path
        ]
        if let local = localCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            // Copy to cache so retries always use this version
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: cachedFile)
            try? FileManager.default.copyItem(atPath: local, toPath: cachedFile.path)
            return local
        }

        // Download from GitHub
        let remoteURL = "https://raw.githubusercontent.com/Dimense-Studio/ClusterCore/master/cluster/manifests/k8sdevops.yaml"

        do {
            let (data, response) = try await URLSession.shared.data(from: URL(string: remoteURL)!)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                appendLog("Failed to download ClusterCore manifest (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                return nil
            }

            // Ensure cache dir exists
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try data.write(to: cachedFile)
            appendLog("ClusterCore manifest downloaded from GitHub")
            return cachedFile.path
        } catch {
            appendLog("Failed to download ClusterCore manifest: \(error.localizedDescription)")

            // Fallback to cached version if available
            if FileManager.default.fileExists(atPath: cachedFile.path) {
                appendLog("Using cached ClusterCore manifest")
                return cachedFile.path
            }
            return nil
        }
    }

    private func generateDashboardPassword() -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<16).compactMap { _ in chars.randomElement() })
    }

    /// Restore completed setup state from persistence (called on app start)
    func restoreCompleted(for vm: VirtualMachine) {
        setupLock.lock()
        completedVMs.insert(vm.id)
        setupLock.unlock()
    }

    /// Restore ClusterCore deployed state from persistence (called on app start)
    func restoreClusterCoreDeployed(for vm: VirtualMachine) {
        clusterCoreDeployedVMs.insert(vm.id)
    }

    /// Reset setup state for a VM (e.g., when VM is restarted)
    func resetSetup(for vmID: UUID) {
        setupLock.lock()
        completedVMs.remove(vmID)
        setupTasks.removeValue(forKey: vmID)
        setupLock.unlock()
    }

    /// Force retry setup for a specific VM
    func retrySetup(for vm: VirtualMachine) {
        resetSetup(for: vm.id)
        let ip = vm.ipAddress
        guard isValidIP(ip) else {
            appendLog("[\(vm.name)] Cannot retry - no valid IP")
            return
        }
        setupTasks[vm.id] = Task { [weak self] in
            await self?.performSetup(for: vm, ip: ip)
        }
    }

    // MARK: - Talos Setup Steps

    private func ensureTalosctlAvailable() async throws {
        let whichResult = try await runCommand(executable: "/usr/bin/which", arguments: ["talosctl"])
        if whichResult.exitCode != 0 {
            throw NSError(
                domain: "TalosAutoSetupService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "talosctl not found. Install: brew install siderolabs/tap/talosctl"]
            )
        }
    }

    private func createWorkspaceDirectory(for vm: VirtualMachine) throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = appSupport
            .appendingPathComponent("MLV", isDirectory: true)
            .appendingPathComponent("TalosAutoSetup", isDirectory: true)
            .appendingPathComponent(vm.id.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func generateConfig(for vm: VirtualMachine, endpoint: String, workspace: URL) async throws {
        appendLog("[\(vm.name)] Generating Talos config...")

        // Create patch file: DNS + allow scheduling on control-plane (single-node cluster)
        let dnsPatchFile = workspace.appendingPathComponent("dns-patch.yaml")
        let dnsPatch = """
---
machine:
    network:
        nameservers:
            - 8.8.8.8
            - 1.1.1.1
            - 8.8.4.4
cluster:
    allowSchedulingOnControlPlanes: true
"""
        try dnsPatch.write(to: dnsPatchFile, atomically: true, encoding: .utf8)

        let args = [
            "gen", "config",
            vm.name,
            endpoint,
            "--output-dir", workspace.path,
            "--force",
            "--install-disk", "/dev/vda",
            "--kubernetes-version", "1.33.0",
            "--config-patch", "@\(dnsPatchFile.path)"
        ]

        _ = try await runTalosctl(arguments: args)

        appendLog("[\(vm.name)] Config generated with VDA disk and DNS")
    }

    private func applyConfig(to nodes: [String], fileName: String, workspace: URL, vm: VirtualMachine) async throws {
        guard !nodes.isEmpty else { return }

        let filePath = workspace.appendingPathComponent(fileName).path
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw NSError(domain: "TalosAutoSetupService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Config file not found: \(fileName)"])
        }

        for node in nodes {
            appendLog("[\(vm.name)] Applying \(fileName) to \(node)...")

            // Retry logic with exponential backoff
            var lastError: Error?
            for attempt in 1...5 {
                do {
                    _ = try await runTalosctl(
                        arguments: [
                            "apply-config",
                            "--insecure",
                            "--nodes", node,
                            "--file", filePath
                        ]
                    )
                    appendLog("[\(vm.name)] Config applied successfully (attempt \(attempt))")
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    let errorString = (error as NSError).localizedDescription.lowercased()

                    // Check if this is a connection/DNS/TLS error that might be transient
                    if errorString.contains("connection refused") ||
                       errorString.contains("timeout") ||
                       errorString.contains("i/o timeout") ||
                       errorString.contains("no such host") ||
                       errorString.contains("no route to host") ||
                       errorString.contains("certificate required") ||
                       errorString.contains("tls:") ||
                       errorString.contains("unavailable") {
                        let waitTime = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000 // 2, 4, 8, 16 seconds
                        appendLog("[\(vm.name)] Attempt \(attempt) failed, retrying in \(waitTime/1_000_000_000)s...")
                        try await Task.sleep(nanoseconds: waitTime)
                    } else {
                        throw error // Non-retryable error
                    }
                }
            }

            if let error = lastError {
                throw error
            }
        }
    }

    /// Wait for Talos API to be ready (in maintenance mode, accepting --insecure connections)
    private func waitForTalosAPI(ip: String, vm: VirtualMachine, maxAttempts: Int = 90) async throws {
        // Grace period: DHCP assigns IP before Talos OS boots and brings up the NIC.
        // "no route to host" = ARP fails because the kernel hasn't started networking yet.
        // Talos on Apple Silicon VMs typically needs 20-45s from DHCP lease to maintenance API ready.
        appendLog("[\(vm.name)] Initial grace period (30s) for Talos to boot and bring up network...")
        try await Task.sleep(nanoseconds: 30_000_000_000)

        appendLog("[\(vm.name)] Checking Talos API readiness at \(ip):50000...")

        let executable = try resolveTalosctl()

        for attempt in 1...maxAttempts {
            // Use runCommand directly to get full output regardless of exit code
            let result = try await runCommand(
                executable: executable,
                arguments: ["version", "--insecure", "--nodes", ip]
            )

            let output = result.output.lowercased()

            // Any server response indicates Talos API is reachable (in maintenance mode)
            // "not implemented in maintenance mode" = ready to accept apply-config
            // "connection refused" / "no route to host" = still booting
            if output.contains("server:") && output.contains("maintenance mode") {
                appendLog("[\(vm.name)] Talos API ready (maintenance mode) - attempt \(attempt)")
                return
            }

            if output.contains("server:") && result.exitCode == 0 {
                appendLog("[\(vm.name)] Talos API ready - attempt \(attempt)")
                return
            }

            // Still booting - expected errors
            if output.contains("connection refused") ||
               output.contains("no route to host") ||
               output.contains("i/o timeout") ||
               output.contains("timeout") ||
               output.contains("unavailable") {
                // Expected during boot - continue waiting silently
            }

            let waitTime: UInt64 = 2_000_000_000 // 2 seconds between attempts
            appendLog("[\(vm.name)] API not ready, waiting 2s... (\(attempt)/\(maxAttempts))")
            try await Task.sleep(nanoseconds: waitTime)
        }

        throw NSError(
            domain: "TalosAutoSetupService",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Talos API did not become ready after \(maxAttempts) attempts"]
        )
    }

    private func bootstrapCluster(bootstrapIP: String, workspace: URL, vm: VirtualMachine) async throws {
        appendLog("[\(vm.name)] Bootstrapping cluster...")

        let talosconfigPath = workspace.appendingPathComponent("talosconfig").path

        // Wait for Talos to fully boot after apply-config (needs 30-60s)
        appendLog("[\(vm.name)] Waiting 30s for Talos to reboot...")
        try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds initial

        // Wait for Talos API to be responsive on port 50000
        // After apply-config, the node is in configured mode and requires TLS (not --insecure)
        appendLog("[\(vm.name)] Checking Talos API health...")
        var apiReady = false
        for healthAttempt in 1...20 {
            appendLog("[\(vm.name)] API health check \(healthAttempt)/20...")
            do {
                // Try with talosconfig (configured mode, TLS)
                _ = try await runTalosctl(
                    arguments: [
                        "version",
                        "--nodes", bootstrapIP,
                        "--endpoints", bootstrapIP,
                        "--talosconfig", talosconfigPath
                    ]
                )
                apiReady = true
                appendLog("[\(vm.name)] Talos API is ready!")
                break
            } catch {
                let errorString = (error as NSError).localizedDescription.lowercased()
                // "certificate required" or "tls" means API is up but still transitioning
                // "connection refused" / "unavailable" means still rebooting
                if errorString.contains("certificate required") || errorString.contains("tls:") {
                    // API is up but still in transition - try with --insecure as fallback
                    let insecureResult = try? await runCommand(
                        executable: try resolveTalosctl(),
                        arguments: [
                            "version", "--insecure",
                            "--nodes", bootstrapIP,
                            "--endpoints", bootstrapIP
                        ]
                    )
                    if let result = insecureResult, result.output.lowercased().contains("server:") {
                        apiReady = true
                        appendLog("[\(vm.name)] Talos API is ready (transitioning from maintenance mode)!")
                        break
                    }
                }
                appendLog("[\(vm.name)] API not ready (attempt \(healthAttempt)): \(error.localizedDescription.prefix(100))")
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3s between checks
            }
        }

        if !apiReady {
            throw NSError(domain: "TalosAutoSetupService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Talos API not ready after 80 seconds"])
        }

        // Retry bootstrap with backoff (up to 10 attempts)
        var lastError: Error?
        for attempt in 1...10 {
            do {
                _ = try await runTalosctl(
                    arguments: [
                        "bootstrap",
                        "--nodes", bootstrapIP,
                        "--endpoints", bootstrapIP,
                        "--talosconfig", talosconfigPath
                    ]
                )
                appendLog("[\(vm.name)] Bootstrap complete")

                // Wait for etcd to be ready after bootstrap
                appendLog("[\(vm.name)] Waiting for etcd to stabilize...")
                try await Task.sleep(nanoseconds: 15_000_000_000) // 15s for etcd

                return
            } catch {
                lastError = error
                let errorString = (error as NSError).localizedDescription.lowercased()
                if errorString.contains("connection refused") || errorString.contains("unavailable") || errorString.contains("timeout") {
                    let waitSeconds = min(attempt * 3, 30) // 3, 6, 9, ... 30 seconds
                    appendLog("[\(vm.name)] Bootstrap attempt \(attempt)/10 failed, retrying in \(waitSeconds)s...")
                    try await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
                } else {
                    throw error
                }
            }
        }

        if let error = lastError {
            throw error
        }
    }

    private func fetchKubeconfig(controlPlaneIP: String, workspace: URL, vm: VirtualMachine) async throws {
        appendLog("[\(vm.name)] Fetching kubeconfig...")

        let kubeconfigPath = workspace.appendingPathComponent("kubeconfig")
        let talosconfigPath = workspace.appendingPathComponent("talosconfig").path

        // Wait for Kubernetes API to be ready after bootstrap (can take 30-60s)
        appendLog("[\(vm.name)] Waiting for Kubernetes API to be ready...")
        try await Task.sleep(nanoseconds: 20_000_000_000) // 20 seconds initial

        // Retry kubeconfig fetch with backoff (up to 15 attempts)
        var lastError: Error?
        for attempt in 1...15 {
            do {
                _ = try await runTalosctl(
                    arguments: [
                        "kubeconfig",
                        kubeconfigPath.path,
                        "--nodes", controlPlaneIP,
                        "--endpoints", controlPlaneIP,
                        "--talosconfig", talosconfigPath,
                        "--force"
                    ]
                )
                lastError = nil
                appendLog("[\(vm.name)] Kubeconfig fetched successfully")
                break
            } catch {
                lastError = error
                let errorString = (error as NSError).localizedDescription.lowercased()
                if errorString.contains("connection refused") || errorString.contains("unavailable") || errorString.contains("timeout") {
                    let waitSeconds = min(attempt * 4, 30) // 4, 8, 12, ... 30 seconds
                    appendLog("[\(vm.name)] Kubeconfig attempt \(attempt)/15 failed, retrying in \(waitSeconds)s...")
                    try await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
                } else {
                    throw error
                }
            }
        }

        if let error = lastError {
            throw error
        }

        // Also save to standard location for easy access
        let standardKubeconfigDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MLV", isDirectory: true)
            .appendingPathComponent("kubeconfigs", isDirectory: true)
        if let kubeconfigDir = standardKubeconfigDir {
            try? FileManager.default.createDirectory(at: kubeconfigDir, withIntermediateDirectories: true)
            let standardPath = kubeconfigDir.appendingPathComponent("\(vm.name)-\(controlPlaneIP).kubeconfig")
            try? FileManager.default.copyItem(at: kubeconfigPath, to: standardPath)
        }

        appendLog("[\(vm.name)] Kubeconfig saved to \(kubeconfigPath.path)")

        // Merge into default kubeconfig if possible
        try? await mergeKubeconfig(kubeconfigPath, vmName: vm.name)
    }

    private func mergeKubeconfig(_ kubeconfigPath: URL, vmName: String) async throws {
        // This is optional - merge the kubeconfig into ~/.kube/config
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultKubeconfig = home.appendingPathComponent(".kube/config")

        guard FileManager.default.fileExists(atPath: defaultKubeconfig.path) else {
            // No existing kubeconfig, copy ours as the default
            try? FileManager.default.createDirectory(at: defaultKubeconfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: kubeconfigPath, to: defaultKubeconfig)
            return
        }

        // Use kubectl to merge configs
        let _ = try? await runCommand(
            executable: "/usr/bin/env",
            arguments: [
                "KUBECONFIG=\(kubeconfigPath.path):\(defaultKubeconfig.path)",
                "kubectl", "config", "view", "--flatten"
            ]
        )

        appendLog("[\(vmName)] Consider merging kubeconfig:")
        appendLog("  export KUBECONFIG=\(kubeconfigPath.path)")
    }

    // MARK: - Command Execution

    private func runTalosctl(arguments: [String]) async throws -> CommandResult {
        let executable = try resolveTalosctl()
        appendLog("$ talosctl \(arguments.joined(separator: " "))")
        let result = try await runCommand(executable: executable, arguments: arguments)
        if result.exitCode != 0 {
            throw NSError(
                domain: "TalosAutoSetupService",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "talosctl failed (exit \(result.exitCode)): \(result.output.prefix(200))"]
            )
        }
        return result
    }

    private func resolveTalosctl() throws -> String {
        let paths = [
            "/opt/homebrew/bin/talosctl",
            "/usr/local/bin/talosctl"
        ]

        if let found = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        return "talosctl"
    }

    private func runCommand(executable: String, arguments: [String]) async throws -> CommandResult {
        let environment = commandEnvironment()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                let handle = pipe.fileHandleForReading
                var collected = ""

                handle.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if data.isEmpty { return }
                    guard let chunk = String(data: data, encoding: .utf8) else { return }
                    collected += chunk
                    DispatchQueue.main.async {
                        self?.appendLog(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    handle.readabilityHandler = nil

                    let remainingData = handle.readDataToEndOfFile()
                    if !remainingData.isEmpty, let remaining = String(data: remainingData, encoding: .utf8) {
                        collected += remaining
                        DispatchQueue.main.async {
                            self?.appendLog(remaining.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }

                    continuation.resume(returning: CommandResult(output: collected, exitCode: process.terminationStatus))
                } catch {
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func commandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? ""
        let inheritedComponents = inheritedPath.split(separator: ":").map(String.init)

        let preferredPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        var mergedPath: [String] = []
        for pathComponent in preferredPaths + inheritedComponents {
            if !mergedPath.contains(pathComponent) {
                mergedPath.append(pathComponent)
            }
        }

        environment["PATH"] = mergedPath.joined(separator: ":")
        return environment
    }

    // MARK: - Talos Update Check

    /// Check for Talos and Kubernetes updates on a running VM
    func checkForTalosUpdate(for vm: VirtualMachine) {
        let ip = vm.ipAddress
        guard isValidIP(ip) else {
            appendLog("[\(vm.name)] Cannot check updates: no valid IP")
            return
        }
        guard vm.state.isRunning else {
            appendLog("[\(vm.name)] Cannot check updates: VM not running")
            return
        }

        Task {
            await performUpdateCheck(ip: ip, vmName: vm.name)
        }
    }

    private func performUpdateCheck(ip: String, vmName: String) async {
        appendLog("[\(vmName)] Checking for Talos updates...")

        do {
            let executable = try resolveTalosctl()

            // Find the talosconfig for this VM's workspace
            let workspaceDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MLV/TalosAutoSetup")
            let talosconfigPath: String?

            if let workspaceDir = workspaceDir,
               let contents = try? FileManager.default.contentsOfDirectory(atPath: workspaceDir.path) {
                var found: String?
                for dir in contents {
                    let configPath = workspaceDir.appendingPathComponent(dir).appendingPathComponent("talosconfig").path
                    if FileManager.default.fileExists(atPath: configPath) {
                        // Check if this talosconfig references our IP
                        if let configData = try? String(contentsOfFile: configPath),
                           configData.contains(ip) {
                            found = configPath
                            break
                        }
                    }
                }
                talosconfigPath = found
            } else {
                talosconfigPath = nil
            }

            // Build version command with talosconfig and endpoints if available
            var versionArgs = ["version", "--nodes", ip, "--endpoints", ip]
            if let configPath = talosconfigPath {
                versionArgs += ["--talosconfig", configPath]
            }

            // Get current Talos version (try with TLS first, fallback to insecure)
            var versionResult = try await runCommand(executable: executable, arguments: versionArgs)
            if versionResult.exitCode != 0 && versionResult.output.lowercased().contains("certificate") {
                // Fallback to insecure for maintenance mode
                let insecureArgs = ["version", "--insecure", "--nodes", ip, "--endpoints", ip]
                versionResult = try await runCommand(executable: executable, arguments: insecureArgs)
            }

            let output = versionResult.output

            // Extract server version from output like "Tag:         v1.12.6"
            var serverVersion = "unknown"
            let lines = output.components(separatedBy: "\n")
            var inServerSection = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("Server:") {
                    inServerSection = true
                    continue
                }
                if inServerSection && trimmed.hasPrefix("Tag:") {
                    serverVersion = trimmed.replacingOccurrences(of: "Tag:", with: "").trimmingCharacters(in: .whitespaces)
                    break
                }
                if inServerSection && !trimmed.isEmpty && !trimmed.hasPrefix("Tag:") && !trimmed.hasPrefix("SHA:") && !trimmed.hasPrefix("Built:") && !trimmed.hasPrefix("Go") && !trimmed.hasPrefix("OS") {
                    inServerSection = false
                }
            }

            appendLog("[\(vmName)] Current Talos version: \(serverVersion)")

            // Get Kubernetes version using kubectl if kubeconfig is available
            var k8sVersion = "unknown"
            let kubeconfigDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MLV/kubeconfigs")
            if let kubeconfigDir = kubeconfigDir,
               let kubectlPath = resolveKubectl(),
               let kubeContents = try? FileManager.default.contentsOfDirectory(atPath: kubeconfigDir.path) {
                for file in kubeContents where file.hasSuffix("-kubeconfig") || file.hasSuffix(".yaml") || file.hasSuffix(".yml") {
                    let kubePath = kubeconfigDir.appendingPathComponent(file).path
                    let k8sResult = try? await runCommand(
                        executable: kubectlPath,
                        arguments: ["version", "--short", "--kubeconfig", kubePath]
                    )
                    if let result = k8sResult, result.exitCode == 0 {
                        // Parse "Server Version: v1.33.0"
                        for line in result.output.components(separatedBy: "\n") {
                            if line.contains("Server Version") {
                                k8sVersion = line.components(separatedBy: ":").last?
                                    .trimmingCharacters(in: .whitespaces) ?? "unknown"
                                break
                            }
                        }
                        if k8sVersion != "unknown" { break }
                    }
                }
            }

            appendLog("[\(vmName)] Current Kubernetes version: \(k8sVersion)")

            // Determine if update is available
            let talosUpToDate = serverVersion.hasPrefix("v1.13")
            let k8sUpToDate = k8sVersion.hasPrefix("v1.35")

            if talosUpToDate && k8sUpToDate {
                appendLog("[\(vmName)] All up to date (Talos \(serverVersion), K8s \(k8sVersion))")
            } else {
                if !talosUpToDate && serverVersion != "unknown" {
                    appendLog("[\(vmName)] Talos update available: \(serverVersion) -> v1.13.0")
                    appendLog("[\(vmName)] Run: talosctl upgrade --nodes \(ip) --image factory.talos.dev/installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:v1.13.0")
                }
                if !k8sUpToDate && k8sVersion != "unknown" {
                    appendLog("[\(vmName)] Kubernetes update available: \(k8sVersion) -> v1.35.4")
                    appendLog("[\(vmName)] Run: talosctl upgrade-k8s --nodes \(ip) --to 1.35.4")
                }
                if serverVersion == "unknown" {
                    appendLog("[\(vmName)] Could not determine current Talos version. Ensure the VM is fully configured and running.")
                }
            }

        } catch {
            appendLog("[\(vmName)] Update check failed: \(error.localizedDescription)")
        }
    }

    private func resolveKubectl() -> String? {
        let paths = [
            "/opt/homebrew/bin/kubectl",
            "/usr/local/bin/kubectl",
            "/usr/bin/kubectl"
        ]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private struct CommandResult {
        let output: String
        let exitCode: Int32
    }
}
