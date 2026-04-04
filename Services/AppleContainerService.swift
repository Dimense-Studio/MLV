import Foundation

@Observable
final class AppleContainerService {
    static let shared = AppleContainerService()

    private let defaultExecutable = "/usr/local/bin/container"
    private let pullPluginCandidates = [
        "/usr/local/libexec/container-plugins/pull",
        "/usr/local/libexec/container/plugins/pull"
    ]
    private let latestReleaseAPI = URL(string: "https://api.github.com/repos/apple/container/releases/latest")!

    private init() {}

    private func performBlocking<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    var isInstalled: Bool {
        if FileManager.default.isExecutableFile(atPath: defaultExecutable) {
            return true
        }
        let result = runProcess(executablePath: "/usr/bin/which", arguments: ["container"], timeout: 2)
        return result.exitCode == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Backward-compatible install hook used by existing settings UI.
    // If CLI is already present, this is a no-op. Otherwise we surface an actionable error.
    func installOrUpdateFromOfficialRelease() async throws {
        if isInstalled { return }
        throw NSError(
            domain: "AppleContainerService",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Apple container CLI is not installed. Install it first, then retry."]
        )
    }

    func startWorkload(name: String, image: String, cpus: Int, memoryGB: Int) throws -> String {
        let executable = try requireExecutable()
        if try workloadExists(name: name, executable: executable) {
            _ = try run(executable: executable, arguments: ["start", name])
            return "Started existing container workload '\(name)'."
        }

        let safeCPUs = max(1, cpus)
        let safeMemory = max(1, memoryGB)
        _ = try run(
            executable: executable,
            arguments: [
                "run", "-d",
                "--name", name,
                "--cpus", String(safeCPUs),
                "--memory", "\(safeMemory)g",
                image
            ]
        )
        return "Created and started container workload '\(name)' from image '\(image)'."
    }

    func stopWorkload(name: String) throws {
        let executable = try requireExecutable()
        guard try workloadExists(name: name, executable: executable) else { return }
        _ = try run(executable: executable, arguments: ["stop", name])
    }

    func deleteWorkload(name: String) throws {
        let executable = try requireExecutable()
        guard try workloadExists(name: name, executable: executable) else { return }
        _ = try run(executable: executable, arguments: ["delete", "--force", name])
    }

    func systemStatusRunning() throws -> Bool {
        let executable = try requireExecutable()
        let result = try run(executable: executable, arguments: ["system", "status"])
        let lower = result.output.lowercased()
        return lower.contains("running") || lower.contains("active")
    }

    func ensureSystemRunning() throws {
        if try systemStatusRunning() { return }
        let executable = try requireExecutable()
        _ = try run(executable: executable, arguments: ["system", "start"])
    }
    
    func pullImage(reference: String) throws {
        let executable = try requireExecutable()
        try ensureSystemRunning()
        let variants: [[String]] = [
            ["pull", reference],
            ["image", "pull", reference]
        ]
        var failures: [String] = []
        for args in variants {
            do {
                _ = try run(executable: executable, arguments: args, timeout: 600)
                return
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if failures.contains(where: { isMissingPullPluginError($0) }) {
            throw pluginMissingError()
        }
        throw NSError(
            domain: "AppleContainerService",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")]
        )
    }

    func pullImage(
        reference: String,
        onProgress: @escaping (_ progress: Double, _ detail: String) -> Void
    ) async throws {
        onProgress(0, "Starting pull...")
        try await performBlocking {
            try self.pullImage(reference: reference)
        }
        onProgress(1, "Image pulled.")
    }

    func pullImageAsync(reference: String) async throws {
        try await performBlocking {
            try self.pullImage(reference: reference)
        }
    }
    
    func listContainerImages() async throws -> [ContainerImageInfo] {
        try await performBlocking {
            try self.listImages()
        }
    }

    func startWorkload(
        name: String,
        image: String,
        cpus: Int,
        memoryGB: Int
    ) async throws -> String {
        try await performBlocking {
            try self.startWorkload(name: name, image: image, cpus: cpus, memoryGB: memoryGB)
        }
    }

    func deleteImageAsync(reference: String) async throws {
        try await performBlocking {
            try self.deleteImage(reference: reference)
        }
    }

    func listImages() throws -> [ContainerImageInfo] {
        let executable = try requireExecutable()
        let variants: [[String]] = [
            ["images", "--format", "json"],
            ["image", "ls", "--format", "json"]
        ]
        var failures: [String] = []
        for args in variants {
            do {
                let result = try run(executable: executable, arguments: args)
                return parseImages(from: result.output)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        throw NSError(
            domain: "AppleContainerService",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")]
        )
    }

    func deleteImage(reference: String) throws {
        let executable = try requireExecutable()
        let variants: [[String]] = [
            ["image", "rm", reference],
            ["rmi", reference]
        ]
        var lastError: Error?
        for args in variants {
            do {
                _ = try run(executable: executable, arguments: args)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(
            domain: "AppleContainerService",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Failed to delete image '\(reference)'."]
        )
    }

    private func workloadExists(name: String, executable: String) throws -> Bool {
        do {
            _ = try run(executable: executable, arguments: ["inspect", name])
            return true
        } catch {
            return false
        }
    }

    private func requireExecutable() throws -> String {
        if FileManager.default.isExecutableFile(atPath: defaultExecutable) {
            return defaultExecutable
        }
        let result = runProcess(executablePath: "/usr/bin/which", arguments: ["container"], timeout: 2)
        if result.exitCode == 0 {
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        throw NSError(domain: "AppleContainerService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple container CLI not found."])
    }

    private func run(executable: String, arguments: [String], timeout: TimeInterval = 30) throws -> (output: String, exitCode: Int32) {
        let result = runProcess(executablePath: executable, arguments: arguments, timeout: timeout)
        if result.exitCode == 0 { return result }
        throw NSError(domain: "AppleContainerService", code: 2, userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "container command failed" : result.output])
    }

    private func isMissingPullPluginError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("plugin 'container-pull' not found")
            || lower.contains("plugin \"container-pull\" not found")
            || lower.contains("container-pull")
    }

    private func pluginMissingError() -> NSError {
        let pluginPaths = pullPluginCandidates.joined(separator: "\n- ")
        let description = """
        Pull plugin not found for Apple container CLI.
        Start services with: container system start
        Ensure plugin exists under:
        - \(pluginPaths)
        """
        return NSError(domain: "AppleContainerService", code: 11, userInfo: [NSLocalizedDescriptionKey: description])
    }
    
    private func parseImages(from output: String) -> [ContainerImageInfo] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let rows = json as? [[String: Any]]
        else {
            return []
        }
        return rows.compactMap { row in
            let reference = (row["name"] as? String) ?? (row["reference"] as? String) ?? ""
            if reference.isEmpty { return nil }
            return ContainerImageInfo(
                reference: reference,
                imageID: (row["id"] as? String) ?? "",
                size: (row["size"] as? String) ?? "",
                created: (row["created"] as? String) ?? ""
            )
        }
    }

    private func runProcess(executablePath: String, arguments: [String], timeout: TimeInterval) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output, process.terminationStatus)
        } catch {
            return (error.localizedDescription, -1)
        }
    }
}

struct ContainerImageInfo: Identifiable, Codable {
    let reference: String
    let imageID: String
    let size: String
    let created: String
    var id: String { reference }
}
