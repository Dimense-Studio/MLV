import Foundation
import AppKit

// MARK: - Errors

enum TalosSetupServiceError: LocalizedError {
    case talosctlNotFound
    case configFileNotFound(String)
    case commandFailed(exitCode: Int32, output: String)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .talosctlNotFound:
            return "talosctl not found in PATH. Install with: brew install siderolabs/tap/talosctl"
        case .configFileNotFound(let name):
            return "Config file not found: \(name)"
        case .commandFailed(let code, let output):
            return "talosctl exited \(code): \(output.prefix(300))"
        case .alreadyRunning:
            return "A Talos setup operation is already in progress."
        }
    }
}

// MARK: - TalosSetupService

/// Manual/UI-driven Talos cluster configuration.
/// Accepts explicit IP lists, applies configs, optionally bootstraps and fetches kubeconfig.
@Observable
final class TalosSetupService {
    static let shared = TalosSetupService()

    // MARK: Published state

    var isRunning: Bool = false
    var logs: [String] = []
    var lastError: String?
    var lastWorkspacePath: String = ""

    // MARK: Private state

    /// Resolved talosctl path — cached after the first successful lookup.
    private var resolvedTalosctl: String?
    private var currentTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public Interface

    func clearLogs() {
        logs.removeAll()
        lastError = nil
    }

    func openWorkspaceInFinder() {
        guard !lastWorkspacePath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: lastWorkspacePath))
    }

    /// Cancel any in-progress setup.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        appendLog("Setup cancelled.")
    }

    /// Configure a cluster: generate config, apply to nodes, optionally bootstrap and fetch kubeconfig.
    func configureCluster(
        clusterName: String,
        endpoint: String,
        controlPlaneIPs: [String],
        workerIPs: [String],
        shouldBootstrap: Bool,
        shouldFetchKubeconfig: Bool
    ) async {
        guard !isRunning else {
            appendLog("⚠️ Another Talos setup is already running.")
            lastError = TalosSetupServiceError.alreadyRunning.errorDescription
            return
        }

        isRunning = true
        lastError = nil

        do {
            try Task.checkCancellation()
            try await ensureTalosctlAvailable()

            let workspace = try createWorkspace(clusterName: clusterName)
            lastWorkspacePath = workspace.path
            appendLog("Workspace: \(workspace.path)")

            try Task.checkCancellation()
            try await generateConfig(clusterName: clusterName, endpoint: endpoint, workspace: workspace)

            try Task.checkCancellation()
            try await applyConfig(to: controlPlaneIPs, fileName: "controlplane.yaml", workspace: workspace)

            try Task.checkCancellation()
            try await applyConfig(to: workerIPs, fileName: "worker.yaml", workspace: workspace)

            if shouldBootstrap, let bootstrapIP = controlPlaneIPs.first {
                try Task.checkCancellation()
                try await bootstrapCluster(bootstrapIP: bootstrapIP, workspace: workspace)
            }

            if shouldFetchKubeconfig, let controlPlaneIP = controlPlaneIPs.first {
                try Task.checkCancellation()
                try await fetchKubeconfig(controlPlaneIP: controlPlaneIP, workspace: workspace)
            }

            appendLog("✅ Talos setup completed successfully.")
        } catch is CancellationError {
            appendLog("Setup cancelled.")
        } catch {
            lastError = error.localizedDescription
            appendLog("❌ Setup failed: \(error.localizedDescription)")
        }

        isRunning = false
    }

    // MARK: - Setup Steps

    private func ensureTalosctlAvailable() async throws {
        // Fast path: already resolved
        if let cached = resolvedTalosctl,
           FileManager.default.isExecutableFile(atPath: cached) {
            return
        }

        // Try `which` first so we respect any user-managed PATH
        let whichResult = try await runCommand(executable: "/usr/bin/which", arguments: ["talosctl"])
        if whichResult.succeeded,
           let found = whichResult.output
               .split(whereSeparator: \.isNewline)
               .map(String.init)
               .first?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !found.isEmpty {
            resolvedTalosctl = found
            appendLog("talosctl found at \(found)")
            return
        }

        // Fallback to known install locations
        if let fallback = Self.talosctlCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            resolvedTalosctl = fallback
            appendLog("talosctl resolved at \(fallback)")
            return
        }

        throw TalosSetupServiceError.talosctlNotFound
    }

    private func createWorkspace(clusterName: String) throws -> URL {
        let base = try baseWorkspaceURL()
        let name = sanitize(clusterName)
        let stamp = Self.timestampFormatter.string(from: Date())
        let dir = base.appendingPathComponent("\(name)-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func generateConfig(clusterName: String, endpoint: String, workspace: URL) async throws {
        appendLog("Generating Talos config files…")

        let patchFile = workspace.appendingPathComponent("dns-patch.yaml")
        let patch = """
---
machine:
    network:
        nameservers:
            - 8.8.8.8
            - 1.1.1.1
            - 8.8.4.4
"""
        try patch.write(to: patchFile, atomically: true, encoding: .utf8)

        try await runTalosctl(arguments: [
            "gen", "config",
            clusterName,
            endpoint,
            "--output-dir",   workspace.path,
            "--force",
            "--install-disk", "/dev/vda",
            "--config-patch", "@\(patchFile.path)"
        ])

        appendLog("Config generated (DNS: 8.8.8.8, 1.1.1.1, 8.8.4.4)")
    }

    /// Apply a YAML config to every node in the list, with exponential-backoff retry.
    private func applyConfig(to nodes: [String], fileName: String, workspace: URL) async throws {
        guard !nodes.isEmpty else {
            appendLog("No nodes for \(fileName) — skipping.")
            return
        }

        let filePath = workspace.appendingPathComponent(fileName).path
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw TalosSetupServiceError.configFileNotFound(fileName)
        }

        for node in nodes {
            try Task.checkCancellation()
            appendLog("Applying \(fileName) to \(node)…")
            try await applyConfigToNode(node: node, filePath: filePath)
        }
    }

    private func applyConfigToNode(node: String, filePath: String) async throws {
        let transientPhrases = [
            "connection refused", "timeout", "i/o timeout",
            "no such host", "no route to host", "unavailable"
        ]

        var lastError: Error?
        for attempt in 1...6 {
            try Task.checkCancellation()
            do {
                try await runTalosctl(arguments: [
                    "apply-config",
                    "--insecure",
                    "--nodes", node,
                    "--file",  filePath
                ])
                appendLog("Config applied to \(node) (attempt \(attempt))")
                return
            } catch {
                lastError = error
                let desc = error.localizedDescription.lowercased()
                let isTransient = transientPhrases.contains(where: desc.contains)
                guard isTransient && attempt < 6 else { throw error }
                let delaySec = min(UInt64(1) << attempt, 32) // 2, 4, 8, 16, 32 s
                appendLog("Attempt \(attempt) failed, retrying in \(delaySec)s…")
                try await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
            }
        }
        throw lastError!
    }

    private func bootstrapCluster(bootstrapIP: String, workspace: URL) async throws {
        appendLog("Bootstrapping cluster via \(bootstrapIP)…")
        try await runTalosctl(arguments: [
            "bootstrap",
            "--nodes",       bootstrapIP,
            "--endpoints",   bootstrapIP,
            "--talosconfig", workspace.appendingPathComponent("talosconfig").path
        ])
        appendLog("Bootstrap complete.")
    }

    private func fetchKubeconfig(controlPlaneIP: String, workspace: URL) async throws {
        appendLog("Fetching kubeconfig from \(controlPlaneIP)…")
        let kubeconfigPath = workspace.appendingPathComponent("kubeconfig").path
        try await runTalosctl(arguments: [
            "kubeconfig",
            kubeconfigPath,
            "--nodes",       controlPlaneIP,
            "--endpoints",   controlPlaneIP,
            "--talosconfig", workspace.appendingPathComponent("talosconfig").path
        ])
        appendLog("Kubeconfig saved to \(kubeconfigPath)")
        appendLog("To use: export KUBECONFIG=\(kubeconfigPath)")
    }

    // MARK: - Command Execution

    @discardableResult
    private func runTalosctl(arguments: [String]) async throws -> CommandResult {
        let executable = resolvedTalosctl ?? "talosctl"
        appendLog("$ talosctl \(arguments.joined(separator: " "))")
        let result = try await runCommand(executable: executable, arguments: arguments)
        guard result.succeeded else {
            throw TalosSetupServiceError.commandFailed(
                exitCode: result.exitCode,
                output: result.output
            )
        }
        return result
    }

    private func runCommand(executable: String, arguments: [String]) async throws -> CommandResult {
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
                let lock = NSLock()

                handle.readabilityHandler = { fh in
                    let data = fh.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    lock.withLock { collected += chunk }
                    let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        DispatchQueue.main.async { self?.appendLog(trimmed) }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    handle.readabilityHandler = nil

                    let tail = handle.readDataToEndOfFile()
                    if !tail.isEmpty, let s = String(data: tail, encoding: .utf8) {
                        lock.withLock { collected += s }
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            DispatchQueue.main.async { self?.appendLog(trimmed) }
                        }
                    }

                    let output = lock.withLock { collected }
                    continuation.resume(returning: CommandResult(output: output, exitCode: process.terminationStatus))
                } catch {
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Helpers

    private func baseWorkspaceURL() throws -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = appSupport
            .appendingPathComponent("MLV",        isDirectory: true)
            .appendingPathComponent("TalosSetup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged: [String] = []
        for p in Self.preferredPaths + existing where !merged.contains(p) {
            merged.append(p)
        }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    /// Replace any character that isn't alphanumeric, `-`, or `_` with `-`.
    private func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base    = trimmed.isEmpty ? "talos-cluster" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return base.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
    }

    private func appendLog(_ message: String) {
        let lines = message
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return }
        // Always mutate on MainActor — callers from background use DispatchQueue.main.async
        if Thread.isMainThread {
            logs.append(contentsOf: lines)
        } else {
            DispatchQueue.main.async { self.logs.append(contentsOf: lines) }
        }
    }

    // MARK: - Constants

    private struct CommandResult {
        let output: String
        let exitCode: Int32
        var succeeded: Bool { exitCode == 0 }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let preferredPaths: [String] = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin",    "/usr/local/sbin",
        "/usr/bin",          "/bin",
        "/usr/sbin",         "/sbin"
    ]

    private static let talosctlCandidates: [String] = [
        "/opt/homebrew/bin/talosctl",
        "/usr/local/bin/talosctl"
    ]
}

// MARK: - NSLock convenience

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
