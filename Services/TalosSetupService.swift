import Foundation
import AppKit

@Observable
final class TalosSetupService {
    static let shared = TalosSetupService()

    var isRunning: Bool = false
    var logs: [String] = []
    var lastError: String?
    var lastWorkspacePath: String = ""
    private var talosctlExecutablePath: String?

    private init() {}

    func clearLogs() {
        logs.removeAll()
        lastError = nil
    }

    func openWorkspaceInFinder() {
        guard !lastWorkspacePath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: lastWorkspacePath))
    }

    func configureCluster(
        clusterName: String,
        endpoint: String,
        controlPlaneIPs: [String],
        workerIPs: [String],
        shouldBootstrap: Bool,
        shouldFetchKubeconfig: Bool
    ) async {
        if isRunning {
            appendLog("Another Talos setup operation is already running.")
            return
        }

        isRunning = true
        lastError = nil

        do {
            try await ensureTalosctlAvailable()

            let workspace = try createWorkspaceDirectory(clusterName: clusterName)
            lastWorkspacePath = workspace.path
            appendLog("Workspace: \(workspace.path)")

            try await generateConfig(clusterName: clusterName, endpoint: endpoint, workspace: workspace)
            try await applyConfig(to: controlPlaneIPs, fileName: "controlplane.yaml", workspace: workspace)
            try await applyConfig(to: workerIPs, fileName: "worker.yaml", workspace: workspace)

            if shouldBootstrap, let bootstrapIP = controlPlaneIPs.first {
                try await bootstrapCluster(bootstrapIP: bootstrapIP, workspace: workspace)
            }

            if shouldFetchKubeconfig, let controlPlaneIP = controlPlaneIPs.first {
                try await fetchKubeconfig(controlPlaneIP: controlPlaneIP, workspace: workspace)
            }

            appendLog("Talos setup completed successfully.")
        } catch {
            lastError = error.localizedDescription
            appendLog("Talos setup failed: \(error.localizedDescription)")
        }

        isRunning = false
    }

    private func createWorkspaceDirectory(clusterName: String) throws -> URL {
        let base = try baseWorkspaceDirectory()
        let sanitized = sanitizeClusterName(clusterName)
        let timestamp = Self.timestampFormatter.string(from: Date())
        let dir = base.appendingPathComponent("\(sanitized)-\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func baseWorkspaceDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = appSupport
            .appendingPathComponent("MLV", isDirectory: true)
            .appendingPathComponent("TalosSetup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func generateConfig(clusterName: String, endpoint: String, workspace: URL) async throws {
        appendLog("Generating Talos config files...")

        // Create DNS patch file to fix DNS resolution issues
        let dnsPatchFile = workspace.appendingPathComponent("dns-patch.yaml")
        let dnsPatch = """
---
machine:
    network:
        nameservers:
            - 8.8.8.8
            - 1.1.1.1
            - 8.8.4.4
"""
        try dnsPatch.write(to: dnsPatchFile, atomically: true, encoding: .utf8)

        _ = try await runTalosctl(
            arguments: [
                "gen", "config",
                clusterName,
                endpoint,
                "--output-dir", workspace.path,
                "--force",
                "--install-disk", "/dev/vda",
                "--config-patch", "@\(dnsPatchFile.path)"
            ]
        )

        appendLog("Config generated with DNS settings (8.8.8.8, 1.1.1.1)")
    }

    private func applyConfig(to nodes: [String], fileName: String, workspace: URL) async throws {
        guard !nodes.isEmpty else {
            appendLog("No nodes specified for \(fileName); skipping.")
            return
        }

        let filePath = workspace.appendingPathComponent(fileName).path
        for node in nodes {
            appendLog("Applying \(fileName) to \(node)...")

            // Retry logic for transient failures
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
                    appendLog("Config applied successfully (attempt \(attempt))")
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    let errorString = "\(error)"

                    // Check for retryable errors
                    if errorString.contains("connection refused") ||
                       errorString.contains("timeout") ||
                       errorString.contains("i/o timeout") ||
                       errorString.contains("no such host") {
                        let waitSeconds = min(attempt * 2, 15) // 2, 4, 6, 8, 15 seconds
                        appendLog("Attempt \(attempt) failed, retrying in \(waitSeconds)s...")
                        try await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
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

    private func bootstrapCluster(bootstrapIP: String, workspace: URL) async throws {
        appendLog("Bootstrapping cluster via \(bootstrapIP)...")
        _ = try await runTalosctl(
            arguments: [
                "bootstrap",
                "--nodes", bootstrapIP,
                "--endpoints", bootstrapIP,
                "--talosconfig", workspace.appendingPathComponent("talosconfig").path
            ]
        )
    }

    private func fetchKubeconfig(controlPlaneIP: String, workspace: URL) async throws {
        appendLog("Fetching kubeconfig from \(controlPlaneIP)...")
        _ = try await runTalosctl(
            arguments: [
                "kubeconfig",
                workspace.appendingPathComponent("kubeconfig").path,
                "--nodes", controlPlaneIP,
                "--endpoints", controlPlaneIP,
                "--talosconfig", workspace.appendingPathComponent("talosconfig").path
            ]
        )
    }

    private func ensureTalosctlAvailable() async throws {
        let whichResult = try await runCommand(executable: "/usr/bin/which", arguments: ["talosctl"])
        let resolvedFromPath = whichResult.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if whichResult.exitCode == 0, let resolvedFromPath, !resolvedFromPath.isEmpty {
            talosctlExecutablePath = resolvedFromPath
            return
        }

        if let fallback = Self.talosctlFallbackPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            talosctlExecutablePath = fallback
            appendLog("Resolved talosctl at \(fallback).")
            return
        }

        talosctlExecutablePath = nil
        if whichResult.exitCode != 0 || whichResult.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(
                domain: "TalosSetupService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "talosctl not found in PATH. Install it first (for example: brew install siderolabs/tap/talosctl)."]
            )
        }
    }

    private func runTalosctl(arguments: [String]) async throws -> CommandResult {
        let executable = talosctlExecutablePath ?? "talosctl"
        appendLog("$ \(executable) \(arguments.joined(separator: " "))")
        let result = try await runCommand(executable: executable, arguments: arguments)
        if result.exitCode != 0 {
            throw NSError(
                domain: "TalosSetupService",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "talosctl command failed (exit \(result.exitCode))."]
            )
        }
        return result
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
                        self?.appendLog(chunk)
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
                            self?.appendLog(remaining)
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
        let inheritedComponents = inheritedPath
            .split(separator: ":")
            .map(String.init)

        var mergedPath: [String] = []
        for pathComponent in Self.preferredPathComponents + inheritedComponents {
            if !mergedPath.contains(pathComponent) {
                mergedPath.append(pathComponent)
            }
        }

        environment["PATH"] = mergedPath.joined(separator: ":")
        return environment
    }

    private func sanitizeClusterName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "talos-cluster" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return fallback.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.map(String.init).joined()
    }

    private func appendLog(_ message: String) {
        let lines = message
            .split(whereSeparator: \ .isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            return
        }

        logs.append(contentsOf: lines)
    }

    private struct CommandResult {
        let output: String
        let exitCode: Int32
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let preferredPathComponents: [String] = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    private static let talosctlFallbackPaths: [String] = [
        "/opt/homebrew/bin/talosctl",
        "/usr/local/bin/talosctl"
    ]
}
