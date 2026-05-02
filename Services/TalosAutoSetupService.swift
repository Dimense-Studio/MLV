import Foundation
import AppKit

// MARK: - Version Targets (update these when new releases ship)

private enum TalosVersionTargets {
    static let talosLatest      = "v1.13.0"
    static let talosPrefix      = "v1.13"
    static let kubernetesLatest = "v1.35.4"
    static let kubernetesPrefix = "v1.35"
    static let kubernetesInstall = "1.33.0"   // version passed to gen config
}

// MARK: - Setup Stage

enum TalosSetupStage: Int, CaseIterable, Identifiable {
    case idle               = 0
    case generatingConfig   = 1
    case waitingForAPI      = 2
    case applyingConfig     = 3
    case bootstrapping      = 4
    case fetchingKubeconfig = 5
    case waitingForK8sAPI   = 6
    case deployingClusterCore = 7
    case completed          = 8
    case failed             = 9

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .idle:               return "Idle"
        case .generatingConfig:   return "Generating Config"
        case .waitingForAPI:      return "Waiting for API"
        case .applyingConfig:     return "Applying Config"
        case .bootstrapping:      return "Bootstrapping"
        case .fetchingKubeconfig: return "Fetching Kubeconfig"
        case .waitingForK8sAPI:   return "Waiting for K8s API"
        case .deployingClusterCore: return "Deploying ClusterCore"
        case .completed:          return "Completed"
        case .failed:             return "Failed"
        }
    }

    var icon: String {
        switch self {
        case .idle:               return "circle.dashed"
        case .generatingConfig:   return "doc.badge.gearshape"
        case .waitingForAPI:      return "antenna.radiowaves.left.and.right"
        case .applyingConfig:     return "arrow.triangle.branch"
        case .bootstrapping:      return "bolt.fill"
        case .fetchingKubeconfig: return "key.fill"
        case .waitingForK8sAPI:   return "network"
        case .deployingClusterCore: return "server.rack"
        case .completed:          return "checkmark.circle.fill"
        case .failed:             return "xmark.circle.fill"
        }
    }

    var progress: Double {
        switch self {
        case .idle:               return 0.0
        case .generatingConfig:   return 0.125
        case .waitingForAPI:      return 0.25
        case .applyingConfig:     return 0.375
        case .bootstrapping:      return 0.5
        case .fetchingKubeconfig: return 0.625
        case .waitingForK8sAPI:   return 0.75
        case .deployingClusterCore: return 0.875
        case .completed:          return 1.0
        case .failed:             return 0.0
        }
    }

    /// Stages shown in the progress bar (excludes idle / failed / completed)
    static var progressStages: [TalosSetupStage] {
        [.generatingConfig, .waitingForAPI, .applyingConfig, .bootstrapping,
         .fetchingKubeconfig, .waitingForK8sAPI, .deployingClusterCore]
    }

    static var talosStages: [TalosSetupStage] {
        [.generatingConfig, .waitingForAPI, .applyingConfig, .bootstrapping, .fetchingKubeconfig]
    }

    static var clusterCoreStages: [TalosSetupStage] {
        [.waitingForK8sAPI, .deployingClusterCore]
    }
}

// MARK: - Errors

enum TalosSetupError: LocalizedError {
    case talosctlNotFound
    case configFileNotFound(String)
    case apiTimeout(Int)
    case workerConfigTimeout
    case workerStuckInstalling
    case clusterCoreManifestUnavailable
    case bootstrapTimeout

    var errorDescription: String? {
        switch self {
        case .talosctlNotFound:
            return "talosctl not found. Install with: brew install siderolabs/tap/talosctl"
        case .configFileNotFound(let name):
            return "Config file not found: \(name)"
        case .apiTimeout(let attempts):
            return "Talos API did not become ready after \(attempts) attempts."
        case .workerConfigTimeout:
            return "No worker config available after 10 minutes. Ensure the control plane is set up first."
        case .workerStuckInstalling:
            return "Worker remained in INSTALLING state too long. Check worker logs and control-plane reachability."
        case .clusterCoreManifestUnavailable:
            return "ClusterCore manifest not found and download failed. Check internet connection."
        case .bootstrapTimeout:
            return "Talos API not ready after bootstrap grace period."
        }
    }
}

// MARK: - Command Result

private struct CommandResult {
    let output: String
    let exitCode: Int32
    var succeeded: Bool { exitCode == 0 }
}

// MARK: - Per-VM Setup State

/// Thread-safe state machine for one VM's setup lifecycle.
private final class VMSetupState: @unchecked Sendable {
    enum Phase { case idle, inProgress, completed, failed }

    private let lock = NSLock()
    private var _phase: Phase = .idle
    private var _task: Task<Void, Never>?

    var phase: Phase {
        lock.withLock { _phase }
    }
    var isSettled: Bool {
        let p = phase; return p == .completed || p == .failed
    }
    var isActive: Bool {
        phase == .inProgress
    }

    func tryBegin(task: Task<Void, Never>) -> Bool {
        lock.withLock {
            guard _phase == .idle else { return false }
            _phase = .inProgress
            _task = task
            return true
        }
    }

    func markCompleted() {
        lock.withLock { _phase = .completed; _task = nil }
    }

    func markFailed() {
        lock.withLock { _phase = .failed; _task = nil }
    }

    func reset() {
        lock.withLock { _phase = .idle; _task = nil }
    }

    func cancel() {
        lock.withLock { _task?.cancel(); _task = nil; _phase = .idle }
    }
}

// MARK: - TalosAutoSetupService

/// Automatically configures Talos VMs when they become available on the network.
/// Handles the full setup flow for both control-plane and worker nodes.
/// Thread-safe across multiple simultaneous VM setups.
@Observable
final class TalosAutoSetupService {
    static let shared = TalosAutoSetupService()

    // MARK: Published state (always mutated on MainActor)
    var isRunning: Bool = false
    var logs: [String] = []
    var currentStage: TalosSetupStage = .idle
    var currentVMName: String = ""
    var pendingClusterCoreVM: VirtualMachine?
    var lastClusterCoreVM: VirtualMachine?
    var clusterCoreDeployedVMs: Set<UUID> = []

    // MARK: Private state
    /// Per-VM setup lifecycle tracking — keyed by VM UUID
    private var vmStates: [UUID: VMSetupState] = [:]
    private let vmStatesLock = NSLock()

    /// Worker config shared between control-plane broadcast and worker consumers
    private var _workerConfig: ClusterManager.WorkerConfigPayload?
    private let workerConfigLock = NSLock()

    private init() {}

    // MARK: - Worker Config

    @MainActor
    func receiveWorkerConfig(_ config: ClusterManager.WorkerConfigPayload) {
        workerConfigLock.withLock { _workerConfig = config }
        appendLog("[Cluster] Worker config received for '\(config.clusterName)' (CP: \(config.controlPlaneIP))")
    }

    func availableWorkerConfig() -> ClusterManager.WorkerConfigPayload? {
        workerConfigLock.withLock { _workerConfig }
    }

    // MARK: - Logging

    func clearLogs() {
        DispatchQueue.main.async { self.logs.removeAll() }
    }

    func appendLog(_ message: String) {
        let lines = message
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { self.logs.append(contentsOf: lines) }
    }

    // MARK: - VM State Accessors

    private func state(for vmID: UUID) -> VMSetupState {
        vmStatesLock.withLock {
            if let existing = vmStates[vmID] { return existing }
            let s = VMSetupState()
            vmStates[vmID] = s
            return s
        }
    }

    // MARK: - Public Interface

    /// Trigger setup for a single VM if not already running or complete.
    func triggerSetup(for vm: VirtualMachine) {
        let s = state(for: vm.id)
        guard !s.isActive, !s.isSettled else { return }
        let ip = vm.ipAddress
        guard isValidIP(ip) else {
            appendLog("[\(vm.name)] Cannot start setup — no valid IP (\(ip))")
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSetup(for: vm, ip: ip)
        }
        guard s.tryBegin(task: task) else {
            task.cancel()
            return
        }
    }

    /// Force-reset a VM so it can be set up again.
    func resetSetup(for vmID: UUID) {
        state(for: vmID).reset()
    }

    /// Retry setup for a VM (resets first).
    func retrySetup(for vm: VirtualMachine) {
        resetSetup(for: vm.id)
        triggerSetup(for: vm)
    }

    /// Restore persisted completed state (called on app launch).
    func restoreCompleted(for vm: VirtualMachine) {
        state(for: vm.id).markCompleted()
    }

    /// Restore persisted ClusterCore deployed state (called on app launch).
    func restoreClusterCoreDeployed(for vm: VirtualMachine) {
        clusterCoreDeployedVMs.insert(vm.id)
    }

    // MARK: - Setup Entry Point

    @MainActor
    private func performSetup(for vm: VirtualMachine, ip: String) async {
        isRunning = true
        currentVMName = vm.name
        currentStage = .idle

        let s = state(for: vm.id)

        do {
            try await ensureTalosctlAvailable()
            if vm.isMaster {
                try await performMasterSetup(for: vm, ip: ip)
            } else {
                try await performWorkerSetup(for: vm, ip: ip)
            }
            s.markCompleted()
        } catch is CancellationError {
            appendLog("[\(vm.name)] Setup cancelled")
            s.reset()
        } catch {
            currentStage = .failed
            vm.addLog("Talos auto-setup failed: \(error.localizedDescription)", isError: true)
            appendLog("[\(vm.name)] ❌ Setup failed: \(error.localizedDescription)")
            s.markFailed()
        }

        isRunning = false
    }

    // MARK: - Control-Plane Setup

    @MainActor
    private func performMasterSetup(for vm: VirtualMachine, ip: String) async throws {
        appendLog("[\(vm.name)] Starting control-plane setup at \(ip)…")

        let workspace = try createWorkspace(for: vm)
        appendLog("[\(vm.name)] Workspace: \(workspace.path)")

        currentStage = .generatingConfig
        try await generateConfig(for: vm, endpoint: "https://\(ip):6443", workspace: workspace)

        currentStage = .waitingForAPI
        try await waitForTalosAPI(ip: ip, vm: vm)

        currentStage = .applyingConfig
        try await applyConfig(to: ip, fileName: "controlplane.yaml", workspace: workspace, vm: vm)

        currentStage = .bootstrapping
        try await bootstrapCluster(bootstrapIP: ip, workspace: workspace, vm: vm)

        currentStage = .fetchingKubeconfig
        try await fetchKubeconfig(controlPlaneIP: ip, workspace: workspace, vm: vm)

        // Broadcast worker config so worker VMs (local or remote) can proceed
        await broadcastWorkerConfig(clusterName: vm.name, controlPlaneIP: ip, workspace: workspace)

        vm.talosSetupCompleted = true
        vm.addLog("Talos control-plane setup completed")
        appendLog("[\(vm.name)] ✅ Control-plane setup complete!")

        pendingClusterCoreVM = vm
        appendLog("[\(vm.name)] Control plane ready — awaiting ClusterCore decision…")

        AppNotifications.shared.notify(
            id: "talos-setup-\(vm.id)",
            title: "Talos Control Plane Ready",
            body: "\(vm.name) is ready at \(ip)",
            minimumInterval: 1
        )
    }

    // MARK: - Worker Setup

    @MainActor
    private func performWorkerSetup(for vm: VirtualMachine, ip: String) async throws {
        appendLog("[\(vm.name)] Starting worker setup at \(ip)…")

        let initialConfig = try await waitForWorkerConfig(vm: vm)
        let config = await reconcileWorkerConfigForActiveControlPlane(initialConfig, vm: vm)
        let workspace = try createWorkspace(for: vm)

        // Write the received configs to disk for talosctl
        let workerYAMLURL   = workspace.appendingPathComponent("worker.yaml")
        let talosconfigURL  = workspace.appendingPathComponent("talosconfig")
        try config.workerYAML.write(to: workerYAMLURL,   atomically: true, encoding: .utf8)
        try config.talosconfigYAML.write(to: talosconfigURL, atomically: true, encoding: .utf8)
        appendLog("[\(vm.name)] Worker config written from control plane '\(config.clusterName)'")
        appendLog("[\(vm.name)] Worker target: worker=\(ip), control-plane=\(config.controlPlaneIP)")

        currentStage = .waitingForAPI
        try await waitForTalosAPI(ip: ip, vm: vm)

        currentStage = .applyingConfig
        try await applyConfig(to: ip, fileName: "worker.yaml", workspace: workspace, vm: vm)
        try await waitForWorkerReady(workerIP: ip, config: config, workspace: workspace, vm: vm)

        vm.talosSetupCompleted = true
        currentStage = .completed
        vm.addLog("Talos worker joined cluster '\(config.clusterName)'")
        appendLog("[\(vm.name)] ✅ Worker joined cluster '\(config.clusterName)' at \(config.controlPlaneIP)")

        AppNotifications.shared.notify(
            id: "talos-setup-\(vm.id)",
            title: "Worker Node Ready",
            body: "\(vm.name) joined cluster at \(config.controlPlaneIP)",
            minimumInterval: 1
        )
    }

    // MARK: - Worker Ready Wait

    /// Polls the worker's machine status until it leaves the INSTALLING phase.
    /// Issues a single reboot after ~90 s if still stuck, then keeps waiting.
    private func waitForWorkerReady(
        workerIP: String,
        config: ClusterManager.WorkerConfigPayload,
        workspace: URL,
        vm: VirtualMachine
    ) async throws {
        let talosconfigPath = workspace.appendingPathComponent("talosconfig").path
        let maxAttempts = 120  // 120 × 5 s = 10 minutes
        let rebootAfterAttempt = 18 // ~90 s grace before reboot
        var rebootIssued = false
        var loggedRouteHint = false

        appendLog("[\(vm.name)] Waiting for worker Talos install to finish…")

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()

            do {
                let result = try await runTalosctl(arguments: [
                    "get", "machinestatus",
                    "--nodes",      workerIP,
                    "--endpoints",  config.controlPlaneIP,
                    "--talosconfig", talosconfigPath
                ], logCommand: false)

                let outputLower = result.output.lowercased()
                if !loggedRouteHint &&
                    (outputLower.contains("no route to host") || outputLower.contains("connection error")) {
                    appendLog("[\(vm.name)] ⚠️ Worker can't reach control plane at \(config.controlPlaneIP) (Talos API ports 50000/50001)")
                    appendLog("[\(vm.name)] Ensure both VMs are on the same virtual network segment")
                    loggedRouteHint = true
                }

                if result.output.uppercased().contains("INSTALLING") {
                    appendLog("[\(vm.name)] Worker still installing… (\(attempt)/\(maxAttempts))")

                    if attempt >= rebootAfterAttempt && !rebootIssued {
                        appendLog("[\(vm.name)] Worker appears stuck — issuing reboot…")
                        _ = try? await runTalosctl(arguments: [
                            "reboot",
                            "--nodes",      workerIP,
                            "--endpoints",  config.controlPlaneIP,
                            "--talosconfig", talosconfigPath
                        ], logCommand: true)
                        rebootIssued = true
                    }
                } else {
                    appendLog("[\(vm.name)] Worker Talos install finished")
                    return
                }
            } catch {
                let message = error.localizedDescription.lowercased()
                if !loggedRouteHint &&
                    (message.contains("no route to host") || message.contains("connection error")) {
                    appendLog("[\(vm.name)] ⚠️ Worker can't reach control plane at \(config.controlPlaneIP) (Talos API ports 50000/50001)")
                    appendLog("[\(vm.name)] Ensure both VMs are on the same virtual network segment")
                    loggedRouteHint = true
                }
                appendLog("[\(vm.name)] Waiting for worker API… (\(attempt)/\(maxAttempts))")
            }

            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        let controlPlanePorts = await verifyControlPlaneReachability(config.controlPlaneIP)
        if !controlPlanePorts.port50000 || !controlPlanePorts.port50001 {
            appendLog("[\(vm.name)] ⚠️ Control-plane endpoint check failed for \(config.controlPlaneIP) (50000=\(controlPlanePorts.port50000), 50001=\(controlPlanePorts.port50001))")
        }

        throw TalosSetupError.workerStuckInstalling
    }

    private func verifyControlPlanePort(_ ip: String, port: String) async -> Bool {
        let result = try? await runCommand(
            executable: "/usr/bin/nc",
            arguments: ["-z", "-w", "3", ip, port],
            logOutput: false
        )
        return result?.succeeded == true
    }

    private func verifyControlPlaneReachability(_ ip: String) async -> (port50000: Bool, port50001: Bool) {
        async let p50000 = verifyControlPlanePort(ip, port: "50000")
        async let p50001 = verifyControlPlanePort(ip, port: "50001")
        return await (p50000, p50001)
    }

    @MainActor
    private func reconcileWorkerConfigForActiveControlPlane(
        _ config: ClusterManager.WorkerConfigPayload,
        vm: VirtualMachine
    ) async -> ClusterManager.WorkerConfigPayload {
        guard let activeControlPlaneIP = activeLocalControlPlaneIP() else {
            return config
        }
        guard activeControlPlaneIP != config.controlPlaneIP else {
            return config
        }

        appendLog("[\(vm.name)] ⚠️ Worker config control-plane IP drift detected (\(config.controlPlaneIP) -> \(activeControlPlaneIP)); refreshing endpoint")
        let refreshed = ClusterManager.WorkerConfigPayload(
            clusterName: config.clusterName,
            controlPlaneIP: activeControlPlaneIP,
            workerYAML: config.workerYAML,
            talosconfigYAML: config.talosconfigYAML
        )
        workerConfigLock.withLock { _workerConfig = refreshed }
        return refreshed
    }

    @MainActor
    private func activeLocalControlPlaneIP() -> String? {
        VMManager.shared.virtualMachines.first(where: {
            $0.isMaster && $0.state.isRunning && isValidIP($0.ipAddress)
        })?.ipAddress
    }

    // MARK: - Wait for Worker Config

    private func waitForWorkerConfig(vm: VirtualMachine) async throws -> ClusterManager.WorkerConfigPayload {
        appendLog("[\(vm.name)] Waiting for control-plane worker config…")

        for attempt in 1...120 { // 120 × 5 s = 10 minutes
            try Task.checkCancellation()

            // 1. Local store (fastest path — set after local master setup)
            if let config = availableWorkerConfig() {
                appendLog("[\(vm.name)] Worker config available locally")
                return config
            }

            // 2. Remote paired nodes
            for node in ClusterManager.shared.nodes {
                if let config = try? await ClusterManager.shared.fetchWorkerConfig(from: node) {
                    workerConfigLock.withLock { _workerConfig = config }
                    appendLog("[\(vm.name)] Worker config fetched from '\(node.name)'")
                    return config
                }
            }

            appendLog("[\(vm.name)] Waiting for worker config… (\(attempt)/120)")
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        throw TalosSetupError.workerConfigTimeout
    }

    // MARK: - Broadcast Worker Config

    private func broadcastWorkerConfig(clusterName: String, controlPlaneIP: String, workspace: URL) async {
        let workerYAMLURL  = workspace.appendingPathComponent("worker.yaml")
        let talosconfigURL = workspace.appendingPathComponent("talosconfig")

        guard let workerYAML       = try? String(contentsOf: workerYAMLURL,  encoding: .utf8),
              let talosconfigYAML  = try? String(contentsOf: talosconfigURL, encoding: .utf8)
        else {
            appendLog("[Cluster] ⚠️ Could not read worker.yaml / talosconfig for broadcast")
            return
        }

        let config = ClusterManager.WorkerConfigPayload(
            clusterName:     clusterName,
            controlPlaneIP:  controlPlaneIP,
            workerYAML:      workerYAML,
            talosconfigYAML: talosconfigYAML
        )

        workerConfigLock.withLock { _workerConfig = config }
        appendLog("[Cluster] Worker config stored locally for '\(clusterName)'")

        let nodes = ClusterManager.shared.nodes
        if nodes.isEmpty {
            appendLog("[Cluster] No paired nodes — worker config stored locally only")
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for node in nodes {
                group.addTask { [weak service = self] in
                    guard let service else { return }
                    do {
                        try await ClusterManager.shared.sendWorkerConfig(config, to: node)
                        await MainActor.run {
                            service.appendLog("[Cluster] Worker config sent to '\(node.name)'")
                        }
                    } catch {
                        await MainActor.run {
                            service.appendLog("[Cluster] Failed to send worker config to '\(node.name)': \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - ClusterCore Deployment

    @MainActor
    func deployClusterCoreAfterSetup() {
        guard let vm = pendingClusterCoreVM else { return }
        pendingClusterCoreVM = nil
        lastClusterCoreVM = vm
        isRunning = true

        Task {
            defer { isRunning = false }

            appendLog("[\(vm.name)] Deploying ClusterCore…")

            do {
                guard let manifestPath = await findClusterCoreManifest() else {
                    throw TalosSetupError.clusterCoreManifestUnavailable
                }

                currentStage = .waitingForK8sAPI
                appendLog("[\(vm.name)] Waiting for Kubernetes API (may take 1–3 min after bootstrap)…")
                try await TalosPodMonitor.shared.waitForKubernetesAPI(for: vm)

                // Pre-create secret BEFORE the pod starts, so it never runs without a password
                let password = generateDashboardPassword()
                appendLog("[\(vm.name)] Pre-creating app-secrets with dashboard password…")
                try await TalosPodMonitor.shared.createNamespacesAndSecret(for: vm, password: password)

                currentStage = .deployingClusterCore
                appendLog("[\(vm.name)] Applying ClusterCore manifests…")
                try await TalosPodMonitor.shared.applyManifest(for: vm, manifestPath: manifestPath)

                vm.clusterCoreDashboardPassword = password
                appendLog("[\(vm.name)] ✅ Dashboard password set — save this:")
                appendLog("[\(vm.name)] 🔑 PASSWORD: \(password)")
                appendLog("[\(vm.name)] 🌐 URL:      http://\(vm.ipAddress):30005")

                try await Task.sleep(nanoseconds: 2_000_000_000)

                clusterCoreDeployedVMs.insert(vm.id)
                vm.clusterCoreDeployed = true
                currentStage = .completed
                appendLog("[\(vm.name)] ✅ ClusterCore deployment complete!")

                vm.pods = await TalosPodMonitor.shared.fetchPods(for: vm)

                AppNotifications.shared.notify(
                    id: "clustercore-\(vm.id)",
                    title: "ClusterCore Deployed",
                    body: "\(vm.name) has ClusterCore running",
                    minimumInterval: 1
                )
            } catch {
                currentStage = .failed
                appendLog("[\(vm.name)] ❌ ClusterCore deployment failed: \(error.localizedDescription)")
                pendingClusterCoreVM = vm  // allow retry
            }
        }
    }

    @MainActor
    func skipClusterCore() {
        pendingClusterCoreVM = nil
        lastClusterCoreVM = nil
        currentStage = .completed
        isRunning = false
    }

    // MARK: - Setup Steps

    private func ensureTalosctlAvailable() async throws {
        let result = try await runCommand(executable: "/usr/bin/which", arguments: ["talosctl"])
        if !result.succeeded {
            throw TalosSetupError.talosctlNotFound
        }
    }

    private func createWorkspace(for vm: VirtualMachine) throws -> URL {
        let root = try applicationSupportURL()
            .appendingPathComponent("TalosAutoSetup", isDirectory: true)
            .appendingPathComponent(vm.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func generateConfig(for vm: VirtualMachine, endpoint: String, workspace: URL) async throws {
        appendLog("[\(vm.name)] Generating Talos config…")

        // DNS + allow scheduling on control-plane (single-node clusters)
        let patchContent = """
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
        let patchFile = workspace.appendingPathComponent("dns-patch.yaml")
        try patchContent.write(to: patchFile, atomically: true, encoding: .utf8)

        _ = try await runTalosctl(arguments: [
            "gen", "config",
            vm.name,
            endpoint,
            "--output-dir",         workspace.path,
            "--force",
            "--install-disk",       "/dev/vda",
            "--kubernetes-version", TalosVersionTargets.kubernetesInstall,
            "--config-patch",       "@\(patchFile.path)"
        ])

        appendLog("[\(vm.name)] Config generated (/dev/vda, DNS servers set)")
    }

    /// Apply a config YAML to a single node with exponential-backoff retry.
    private func applyConfig(to nodeIP: String, fileName: String, workspace: URL, vm: VirtualMachine) async throws {
        let filePath = workspace.appendingPathComponent(fileName).path
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw TalosSetupError.configFileNotFound(fileName)
        }

        appendLog("[\(vm.name)] Applying \(fileName) to \(nodeIP)…")

        let transientPhrases = [
            "connection refused", "timeout", "i/o timeout",
            "no such host", "no route to host",
            "certificate required", "tls:", "unavailable"
        ]

        var lastError: Error?
        for attempt in 1...6 {
            try Task.checkCancellation()
            do {
                _ = try await runTalosctl(arguments: [
                    "apply-config",
                    "--insecure",
                    "--nodes", nodeIP,
                    "--file",  filePath
                ])
                appendLog("[\(vm.name)] \(fileName) applied (attempt \(attempt))")
                return
            } catch {
                lastError = error
                let desc = error.localizedDescription.lowercased()
                let isTransient = transientPhrases.contains(where: desc.contains)
                guard isTransient && attempt < 6 else { throw error }
                let delaySec = min(UInt64(1) << attempt, 32) // 2, 4, 8, 16, 32 s
                appendLog("[\(vm.name)] Attempt \(attempt) failed, retrying in \(delaySec)s…")
                try await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
            }
        }
        throw lastError!
    }

    /// Poll until the Talos maintenance API responds.
    /// Starts probing immediately; "connection refused" / "no route" are silently retried.
    private func waitForTalosAPI(ip: String, vm: VirtualMachine, maxAttempts: Int = 90) async throws {
        appendLog("[\(vm.name)] Polling Talos API at \(ip):50000 (may take 20–45 s on first boot)…")

        let executable = try resolveTalosctl()
        var quietAttempts = 0

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()

            let result = try await runCommand(
                executable: executable,
                arguments: ["version", "--insecure", "--nodes", ip],
                logOutput: false
            )
            let output = result.output.lowercased()

            if (output.contains("server:") && output.contains("maintenance mode")) ||
               (output.contains("server:") && result.succeeded) {
                appendLog("[\(vm.name)] Talos API ready (attempt \(attempt))")
                return
            }

            // Noisy during boot — suppress individual attempt logs for the first 30 s
            quietAttempts += 1
            if quietAttempts % 10 == 0 {
                appendLog("[\(vm.name)] Still waiting for Talos API… (\(attempt)/\(maxAttempts))")
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        throw TalosSetupError.apiTimeout(maxAttempts)
    }

    private func bootstrapCluster(bootstrapIP: String, workspace: URL, vm: VirtualMachine) async throws {
        appendLog("[\(vm.name)] Bootstrapping cluster…")

        let talosconfigPath = workspace.appendingPathComponent("talosconfig").path

        // After apply-config the node reboots into configured mode — wait for it
        appendLog("[\(vm.name)] Waiting 30 s for node to reboot into configured mode…")
        try await Task.sleep(nanoseconds: 30_000_000_000)

        // Verify the API is reachable with TLS (configured mode), fall back to insecure
        appendLog("[\(vm.name)] Verifying post-reboot API health…")
        var apiReady = false
        let executable = try resolveTalosctl()

        for attempt in 1...20 {
            try Task.checkCancellation()

            let tlsResult = try? await runCommand(
                executable: executable,
                arguments: ["version", "--nodes", bootstrapIP,
                            "--endpoints", bootstrapIP,
                            "--talosconfig", talosconfigPath],
                logOutput: false
            )
            if tlsResult?.succeeded == true {
                apiReady = true
                appendLog("[\(vm.name)] Post-reboot API ready (attempt \(attempt))")
                break
            }

            // Fallback: check insecure (node may still be transitioning from maintenance)
            let insecureResult = try? await runCommand(
                executable: executable,
                arguments: ["version", "--insecure",
                            "--nodes", bootstrapIP, "--endpoints", bootstrapIP],
                logOutput: false
            )
            if insecureResult?.output.lowercased().contains("server:") == true {
                apiReady = true
                appendLog("[\(vm.name)] Post-reboot API ready via insecure path (attempt \(attempt))")
                break
            }

            appendLog("[\(vm.name)] API check \(attempt)/20 — waiting 3 s…")
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }

        guard apiReady else { throw TalosSetupError.bootstrapTimeout }

        // Bootstrap with backoff retry
        var lastError: Error?
        for attempt in 1...10 {
            try Task.checkCancellation()
            do {
                _ = try await runTalosctl(arguments: [
                    "bootstrap",
                    "--nodes",       bootstrapIP,
                    "--endpoints",   bootstrapIP,
                    "--talosconfig", talosconfigPath
                ])
                appendLog("[\(vm.name)] Bootstrap complete — waiting 15 s for etcd…")
                try await Task.sleep(nanoseconds: 15_000_000_000)
                return
            } catch {
                lastError = error
                let desc = error.localizedDescription.lowercased()
                let isTransient = ["connection refused", "unavailable", "timeout"].contains(where: desc.contains)
                guard isTransient && attempt < 10 else { throw error }
                let delaySec = min(attempt * 3, 30)
                appendLog("[\(vm.name)] Bootstrap attempt \(attempt)/10 failed, retrying in \(delaySec)s…")
                try await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
            }
        }
        throw lastError!
    }

    private func fetchKubeconfig(controlPlaneIP: String, workspace: URL, vm: VirtualMachine) async throws {
        appendLog("[\(vm.name)] Fetching kubeconfig (waiting 20 s for K8s API)…")
        try await Task.sleep(nanoseconds: 20_000_000_000)

        let kubeconfigURL   = workspace.appendingPathComponent("kubeconfig")
        let talosconfigPath = workspace.appendingPathComponent("talosconfig").path

        var lastError: Error?
        for attempt in 1...15 {
            try Task.checkCancellation()
            do {
                _ = try await runTalosctl(arguments: [
                    "kubeconfig",
                    kubeconfigURL.path,
                    "--nodes",       controlPlaneIP,
                    "--endpoints",   controlPlaneIP,
                    "--talosconfig", talosconfigPath,
                    "--force"
                ])
                lastError = nil
                appendLog("[\(vm.name)] Kubeconfig fetched")
                break
            } catch {
                lastError = error
                let delaySec = min(attempt * 4, 30)
                appendLog("[\(vm.name)] Kubeconfig attempt \(attempt)/15 failed, retrying in \(delaySec)s…")
                try await Task.sleep(nanoseconds: UInt64(delaySec) * 1_000_000_000)
            }
        }
        if let error = lastError { throw error }

        // Copy to named location for easy external access
        saveKubeconfigCopy(from: kubeconfigURL, vmName: vm.name, ip: controlPlaneIP)

        // Best-effort merge hint (does not fail setup if kubectl absent)
        appendLog("[\(vm.name)] Kubeconfig saved. To use:")
        appendLog("  export KUBECONFIG=\(kubeconfigURL.path)")
    }

    private func saveKubeconfigCopy(from src: URL, vmName: String, ip: String) {
        guard let dir = try? applicationSupportURL()
                .appendingPathComponent("kubeconfigs", isDirectory: true)
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(vmName)-\(ip).kubeconfig")
        try? FileManager.default.copyItem(at: src, to: dest)
    }

    // MARK: - ClusterCore Manifest

    private func findClusterCoreManifest() async -> String? {
        let cacheDir  = (try? applicationSupportURL().appendingPathComponent("ClusterCore"))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MLV/ClusterCore")
        let cachedFile = cacheDir.appendingPathComponent("k8sdevops.yaml")

        // Development / local clone paths
        let home = FileManager.default.homeDirectoryForCurrentUser
        let localCandidates = [
            home.appendingPathComponent("Desktop/Dimense/ClusterCore/cluster/manifests/k8sdevops.yaml"),
            home.appendingPathComponent("Projects/ClusterCore/cluster/manifests/k8sdevops.yaml")
        ]
        if let local = localCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            // Keep cache in sync with local copy
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: cachedFile)
            try? FileManager.default.copyItem(at: local, to: cachedFile)
            appendLog("[ClusterCore] Using local manifest at \(local.path)")
            return local.path
        }

        // GitHub download
        let remoteURLString = "https://raw.githubusercontent.com/Dimense-Studio/ClusterCore/master/cluster/manifests/k8sdevops.yaml"
        guard let remoteURL = URL(string: remoteURLString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                appendLog("[ClusterCore] Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                return fallbackCachedManifest(at: cachedFile)
            }
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try data.write(to: cachedFile)
            appendLog("[ClusterCore] Manifest downloaded from GitHub")
            return cachedFile.path
        } catch {
            appendLog("[ClusterCore] Download error: \(error.localizedDescription)")
            return fallbackCachedManifest(at: cachedFile)
        }
    }

    private func fallbackCachedManifest(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        appendLog("[ClusterCore] Using cached manifest")
        return url.path
    }

    // MARK: - Password Generator

    /// Generates a 16-character random password.
    /// Excludes visually ambiguous characters: l, 1, I, O, 0.
    private func generateDashboardPassword() -> String {
        let chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<16).compactMap { _ in chars.randomElement() })
    }

    // MARK: - Update Check

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
        Task { await performUpdateCheck(ip: ip, vmName: vm.name) }
    }

    private func performUpdateCheck(ip: String, vmName: String) async {
        appendLog("[\(vmName)] Checking for Talos / Kubernetes updates…")

        do {
            let executable = try resolveTalosctl()
            let talosconfigPath = findTalosconfig(forIP: ip)

            var versionArgs = ["version", "--nodes", ip, "--endpoints", ip]
            if let configPath = talosconfigPath { versionArgs += ["--talosconfig", configPath] }

            var versionResult = try await runCommand(executable: executable, arguments: versionArgs, logOutput: false)

            // Fallback to insecure if TLS fails (node may still be in maintenance mode)
            if !versionResult.succeeded && versionResult.output.lowercased().contains("certificate") {
                versionResult = try await runCommand(
                    executable: executable,
                    arguments: ["version", "--insecure", "--nodes", ip, "--endpoints", ip],
                    logOutput: false
                )
            }

            let serverVersion = parseServerTag(from: versionResult.output)
            appendLog("[\(vmName)] Talos version: \(serverVersion)")

            let k8sVersion = await fetchKubernetesServerVersion(vmName: vmName)
            appendLog("[\(vmName)] Kubernetes version: \(k8sVersion)")

            let talosUpToDate = serverVersion.hasPrefix(TalosVersionTargets.talosPrefix)
            let k8sUpToDate   = k8sVersion.hasPrefix(TalosVersionTargets.kubernetesPrefix)

            if talosUpToDate && k8sUpToDate {
                appendLog("[\(vmName)] ✅ All up to date (Talos \(serverVersion), K8s \(k8sVersion))")
                return
            }
            if !talosUpToDate && serverVersion != "unknown" {
                appendLog("[\(vmName)] Talos update: \(serverVersion) → \(TalosVersionTargets.talosLatest)")
                appendLog("[\(vmName)] Run: talosctl upgrade --nodes \(ip) --image factory.talos.dev/installer/376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba:\(TalosVersionTargets.talosLatest)")
            }
            if !k8sUpToDate && k8sVersion != "unknown" {
                appendLog("[\(vmName)] K8s update: \(k8sVersion) → \(TalosVersionTargets.kubernetesLatest)")
                appendLog("[\(vmName)] Run: talosctl upgrade-k8s --nodes \(ip) --to \(TalosVersionTargets.kubernetesLatest)")
            }
            if serverVersion == "unknown" {
                appendLog("[\(vmName)] ⚠️ Could not determine Talos version — is the VM fully configured?")
            }
        } catch {
            appendLog("[\(vmName)] Update check failed: \(error.localizedDescription)")
        }
    }

    /// Scan workspace directories to find a talosconfig that references `ip`.
    private func findTalosconfig(forIP ip: String) -> String? {
        guard let workspaceDir = try? applicationSupportURL().appendingPathComponent("TalosAutoSetup"),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: workspaceDir.path)
        else { return nil }

        for entry in entries {
            let candidate = workspaceDir.appendingPathComponent(entry).appendingPathComponent("talosconfig").path
            if FileManager.default.fileExists(atPath: candidate),
               let content = try? String(contentsOfFile: candidate),
               content.contains(ip) {
                return candidate
            }
        }
        return nil
    }

    /// Parse "Tag:   v1.x.y" from the server section of `talosctl version` output.
    private func parseServerTag(from output: String) -> String {
        var inServer = false
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Server:") { inServer = true; continue }
            if inServer {
                if t.hasPrefix("Tag:") {
                    return t.replacingOccurrences(of: "Tag:", with: "").trimmingCharacters(in: .whitespaces)
                }
                // Leave server section when we hit a non-metadata line
                let metaKeys = ["SHA:", "Built:", "Go ", "OS/"]
                if !t.isEmpty && !metaKeys.contains(where: t.hasPrefix) { inServer = false }
            }
        }
        return "unknown"
    }

    private func fetchKubernetesServerVersion(vmName: String) async -> String {
        guard let kubectlPath = resolveKubectl(),
              let kubeconfigDir = try? applicationSupportURL().appendingPathComponent("kubeconfigs"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: kubeconfigDir.path)
        else { return "unknown" }

        for file in files where file.hasSuffix(".kubeconfig") || file.hasSuffix(".yaml") {
            let kubePath = kubeconfigDir.appendingPathComponent(file).path
            if let result = try? await runCommand(
                executable: kubectlPath,
                arguments: ["version", "--short", "--kubeconfig", kubePath],
                logOutput: false
            ), result.succeeded {
                for line in result.output.components(separatedBy: "\n")
                where line.contains("Server Version") {
                    return line.components(separatedBy: ":").last?
                        .trimmingCharacters(in: .whitespaces) ?? "unknown"
                }
            }
        }
        return "unknown"
    }

    // MARK: - Command Execution

    /// Run talosctl, throw on non-zero exit.
    @discardableResult
    private func runTalosctl(
        arguments: [String],
        logCommand: Bool = true
    ) async throws -> CommandResult {
        let executable = try resolveTalosctl()
        if logCommand { appendLog("$ talosctl \(arguments.joined(separator: " "))") }
        let result = try await runCommand(executable: executable, arguments: arguments)
        guard result.succeeded else {
            throw NSError(
                domain: "TalosAutoSetupService",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey:
                    "talosctl exited \(result.exitCode): \(result.output.prefix(300))"]
            )
        }
        return result
    }

    private func runCommand(
        executable: String,
        arguments: [String],
        logOutput: Bool = true
    ) async throws -> CommandResult {
        let env = buildEnvironment()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments    = arguments
                process.environment  = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError  = pipe

                let handle = pipe.fileHandleForReading
                var collected = ""
                let collectLock = NSLock()

                handle.readabilityHandler = { fh in
                    let data = fh.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    collectLock.withLock { collected += chunk }
                    if logOutput {
                        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { self?.appendLog(trimmed) }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    handle.readabilityHandler = nil

                    let tail = handle.readDataToEndOfFile()
                    if !tail.isEmpty, let s = String(data: tail, encoding: .utf8) {
                        collectLock.withLock { collected += s }
                        if logOutput {
                            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { self?.appendLog(trimmed) }
                        }
                    }

                    let output = collectLock.withLock { collected }
                    continuation.resume(returning: CommandResult(output: output, exitCode: process.terminationStatus))
                } catch {
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    private func resolveTalosctl() throws -> String {
        let candidates = ["/opt/homebrew/bin/talosctl", "/usr/local/bin/talosctl"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        throw TalosSetupError.talosctlNotFound
    }

    private func resolveKubectl() -> String? {
        let candidates = [
            "/opt/homebrew/bin/kubectl",
            "/usr/local/bin/kubectl",
            "/usr/bin/kubectl"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func applicationSupportURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw CocoaError(.fileNoSuchFile) }
        return base.appendingPathComponent("MLV", isDirectory: true)
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let preferredPaths = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged: [String] = []
        for p in preferredPaths + existing where !merged.contains(p) { merged.append(p) }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// Basic IPv4 validation — rejects placeholders like "Detecting…"
    private func isValidIP(_ ip: String) -> Bool {
        guard !ip.isEmpty, ip != "Detecting...", ip.contains(".") else { return false }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
    }
}

// MARK: - NSLock convenience

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
