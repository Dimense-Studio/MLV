import Foundation
import AppKit
import Darwin
import Network

/// Monitors Kubernetes pods on Talos VMs by running kubectl on the host
/// using the kubeconfig generated during auto-setup.
@Observable
final class TalosPodMonitor {
    static let shared = TalosPodMonitor()

    var isMonitoring: Bool = false

    private var timer: Timer?
    private let pollingInterval: TimeInterval = 10.0

    private init() {}

    // MARK: - Kubeconfig Discovery

    /// Find the most recent kubeconfig for a Talos VM
    func kubeconfigPath(for vm: VirtualMachine) -> String? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        // Check VM-specific workspace first
        let vmWorkspace = appSupport
            .appendingPathComponent("MLV", isDirectory: true)
            .appendingPathComponent("TalosAutoSetup", isDirectory: true)
            .appendingPathComponent(vm.id.uuidString, isDirectory: true)
        let vmKubeconfig = vmWorkspace.appendingPathComponent("kubeconfig")
        if FileManager.default.fileExists(atPath: vmKubeconfig.path) {
            return vmKubeconfig.path
        }

        // Check standard kubeconfigs directory
        let kubeconfigDir = appSupport
            .appendingPathComponent("MLV", isDirectory: true)
            .appendingPathComponent("kubeconfigs", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: kubeconfigDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            // Find kubeconfig matching this VM's name
            if let match = files.first(where: { $0.lastPathComponent.hasPrefix(vm.name) && $0.pathExtension == "kubeconfig" }) {
                return match.path
            }
        }

        // Check default ~/.kube/config
        let defaultKubeconfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube/config")
        if FileManager.default.fileExists(atPath: defaultKubeconfig.path) {
            return defaultKubeconfig.path
        }

        return nil
    }

    // MARK: - Pod Polling from Host

    /// Fetch pods from a Talos cluster via kubectl on the host
    func fetchPods(for vm: VirtualMachine) async -> [VirtualMachine.Pod] {
        guard let kubeconfig = kubeconfigPath(for: vm) else { return [] }

        let result = await runKubectl(
            arguments: [
                "get", "pods", "-A",
                "--no-headers",
                "-o", "custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CPU:.spec.containers[0].resources.requests.cpu,RAM:.spec.containers[0].resources.requests.memory",
                "--kubeconfig", kubeconfig
            ]
        )

        guard result.exitCode == 0 else { return [] }

        var pods: [VirtualMachine.Pod] = []
        for line in result.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3 else { continue }
            pods.append(VirtualMachine.Pod(
                name: parts[1],
                status: parts[2],
                cpu: parts.count > 3 ? parts[3] : "N/A",
                ram: parts.count > 4 ? parts[4] : "N/A",
                namespace: parts[0]
            ))
        }
        return pods
    }

    /// Fetch nodes from a Talos cluster via kubectl on the host
    func fetchNodes(for vm: VirtualMachine) async -> [(name: String, status: String, roles: String)] {
        guard let kubeconfig = kubeconfigPath(for: vm) else { return [] }

        let result = await runKubectl(
            arguments: [
                "get", "nodes",
                "--no-headers",
                "-o", "custom-columns=NAME:.metadata.name,STATUS:.status.conditions[?(@.type==\"Ready\")].status,ROLES:.metadata.labels",
                "--kubeconfig", kubeconfig
            ]
        )

        guard result.exitCode == 0 else { return [] }

        var nodes: [(name: String, status: String, roles: String)] = []
        for line in result.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            let roles = parts.count > 2 ? parts[2...].joined(separator: " ") : ""
            nodes.append((name: parts[0], status: parts[1], roles: roles))
        }
        return nodes
    }

    // MARK: - ClusterCore Deploy

    /// Wait for the Kubernetes API to accept connections on port 6443
    func waitForKubernetesAPI(for vm: VirtualMachine) async throws {
        guard let kubeconfig = kubeconfigPath(for: vm) else {
            throw NSError(domain: "TalosPodMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No kubeconfig found for \(vm.name)"])
        }
        let serverIP = extractServerIP(from: kubeconfig)
        var apiReady = false
        for _ in 1...60 {
            if let ip = serverIP {
                if await isTCPPortOpenAsync(host: ip, port: 6443) {
                    apiReady = true
                    break
                }
            } else {
                let versionResult = await runKubectl(
                    arguments: ["version", "--client", "--request-timeout", "3s"]
                )
                if versionResult.exitCode == 0 {
                    apiReady = true
                    break
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        if !apiReady {
            throw NSError(domain: "TalosPodMonitor", code: 3, userInfo: [NSLocalizedDescriptionKey: "Kubernetes API not ready after 300 seconds"])
        }
    }

    /// Create production/internal namespaces and app-secrets with the real password
    /// before the Deployment is applied, so the pod starts with a valid secret.
    func createNamespacesAndSecret(for vm: VirtualMachine, password: String) async throws {
        guard let kubeconfig = kubeconfigPath(for: vm) else {
            throw NSError(domain: "TalosPodMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No kubeconfig found for \(vm.name)"])
        }
        let bootstrap = """
apiVersion: v1
kind: Namespace
metadata:
  name: production
---
apiVersion: v1
kind: Namespace
metadata:
  name: internal
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: production
  annotations:
    helm.sh/resource-policy: keep
type: Opaque
stringData:
  DASHBOARD_PASSWORD: "\(password)"
  DATABASE_URL: ""
  JWT_SECRET: ""
  SESSION_SECRET: ""
"""
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("clustercore-bootstrap-\(vm.id).yaml")
        try bootstrap.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let result = await runKubectl(arguments: [
            "apply", "-f", tmpFile.path,
            "--kubeconfig", kubeconfig,
            "--request-timeout", "15s"
        ])
        if result.exitCode != 0 && !result.output.lowercased().contains("created") && !result.output.lowercased().contains("unchanged") {
            throw NSError(domain: "TalosPodMonitor", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to bootstrap namespaces/secret: \(result.output)"])
        }
    }

    /// Apply a manifest file with retries
    func applyManifest(for vm: VirtualMachine, manifestPath: String) async throws {
        guard let kubeconfig = kubeconfigPath(for: vm) else {
            throw NSError(domain: "TalosPodMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No kubeconfig found for \(vm.name)"])
        }
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            throw NSError(domain: "TalosPodMonitor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Manifest not found: \(manifestPath)"])
        }
        var lastApplyError: Error?
        for attempt in 1...10 {
            let result = await runKubectl(arguments: [
                "apply", "-f", manifestPath,
                "--kubeconfig", kubeconfig,
                "--request-timeout", "30s"
            ])
            let output = result.output
            let outputLower = output.lowercased()
            let hasAppliedResources = outputLower.contains("created") || outputLower.contains("configured") || outputLower.contains("unchanged")
            if result.exitCode == 0 || hasAppliedResources {
                lastApplyError = nil
                break
            }
            let isConnectionError = outputLower.contains("connection refused") || outputLower.contains("eof") ||
                                    outputLower.contains("unable to connect") || outputLower.contains("no such host") ||
                                    outputLower.contains("i/o timeout")
            if isConnectionError {
                lastApplyError = NSError(domain: "TalosPodMonitor", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: "kubectl apply connection error (attempt \(attempt)/10): \(output)"])
                try await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            throw NSError(domain: "TalosPodMonitor", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: "kubectl apply failed:\n\(output)"])
        }
        if let error = lastApplyError { throw error }
    }

    // MARK: - Pod Actions

    func deletePod(name: String, namespace: String, for vm: VirtualMachine) async -> String {
        guard let kubeconfig = kubeconfigPath(for: vm) else { return "No kubeconfig found" }
        let result = await runKubectl(arguments: [
            "delete", "pod", name,
            "-n", namespace,
            "--kubeconfig", kubeconfig,
            "--request-timeout", "15s"
        ])
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func restartPod(name: String, namespace: String, for vm: VirtualMachine) async -> String {
        guard let kubeconfig = kubeconfigPath(for: vm) else { return "No kubeconfig found" }
        // Deleting a managed pod causes the controller to recreate it — this is the standard restart
        let result = await runKubectl(arguments: [
            "delete", "pod", name,
            "-n", namespace,
            "--kubeconfig", kubeconfig,
            "--request-timeout", "15s"
        ])
        let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "Pod deleted — controller will recreate it" : out
    }

    func fetchPodLogs(name: String, namespace: String, for vm: VirtualMachine, tail: Int = 200) async -> String {
        guard let kubeconfig = kubeconfigPath(for: vm) else { return "No kubeconfig found" }
        let result = await runKubectl(arguments: [
            "logs", name,
            "-n", namespace,
            "--tail", "\(tail)",
            "--kubeconfig", kubeconfig,
            "--request-timeout", "30s"
        ])
        let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "(no logs)" : out
    }

    func execShell(name: String, namespace: String, for vm: VirtualMachine) {
        guard let kubeconfig = kubeconfigPath(for: vm) else { return }
        let script = """
        tell application "Terminal"
            activate
            do script "kubectl exec -it \(name) -n \(namespace) --kubeconfig '\(kubeconfig)' -- sh"
        end tell
        """
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
        }
    }

    // MARK: - Monitoring Loop

    func startMonitoring() {
        guard timer == nil else { return }
        isMonitoring = true

        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.pollAllTalosVMs()
        }

        // Initial poll
        pollAllTalosVMs()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    @MainActor
    private func pollAllTalosVMs() {
        let talosVMs = VMManager.shared.virtualMachines.filter {
            $0.selectedDistro == .talos && $0.state == .running
        }

        for vm in talosVMs {
            Task { [weak self] in
                guard let self else { return }
                let pods = await self.fetchPods(for: vm)
                await MainActor.run {
                    vm.pods = pods
                }
            }
        }
    }

    // MARK: - Command Execution

    private func runKubectl(arguments: [String]) async -> CommandResult {
        let environment = commandEnvironment()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.resolveKubectl())
                process.arguments = arguments
                process.environment = environment

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    continuation.resume(returning: CommandResult(output: output, exitCode: process.terminationStatus))
                } catch {
                    continuation.resume(returning: CommandResult(output: error.localizedDescription, exitCode: -1))
                }
            }
        }
    }

    /// Extract the server IP from a kubeconfig file (looks for "server: https://<IP>:6443")
    private func extractServerIP(from kubeconfigPath: String) -> String? {
        guard let contents = try? String(contentsOfFile: kubeconfigPath, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("server:") {
                // e.g. "server: https://192.168.64.141:6443"
                let value = trimmed.dropFirst("server:".count).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value) {
                    return url.host
                }
            }
        }
        return nil
    }

    /// Async TCP port probe using Network framework — doesn't block cooperative thread pool
    private func isTCPPortOpenAsync(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
            let connection = NWConnection(to: endpoint, using: .tcp)
            var resumed = false

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    if !resumed { resumed = true; continuation.resume(returning: true) }
                case .failed:
                    if !resumed { resumed = true; continuation.resume(returning: false) }
                case .cancelled:
                    if !resumed { resumed = true; continuation.resume(returning: false) }
                case .waiting:
                    // waiting means connection refused / no route
                    connection.cancel()
                    if !resumed { resumed = true; continuation.resume(returning: false) }
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            // Timeout guard
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                connection.cancel()
                if !resumed { resumed = true; continuation.resume(returning: false) }
            }
        }
    }

    private func resolveKubectl() -> String {
        let paths = [
            "/opt/homebrew/bin/kubectl",
            "/usr/local/bin/kubectl",
            "/usr/bin/kubectl"
        ]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "kubectl"
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

    private struct CommandResult {
        let output: String
        let exitCode: Int32
    }
}
