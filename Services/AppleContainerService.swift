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

    // --- MARK: - Core Capabilities ---

    var isInstalled: Bool {
        if FileManager.default.isExecutableFile(atPath: defaultExecutable) {
            return true
        }
        if let result = try? run(executable: "/usr/bin/which", arguments: ["container"], timeout: 2) {
            return result.exitCode == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
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

    func startWorkload(
        name: String,
        image: String,
        cpus: Int,
        memoryMB: Int,
        mounts: [VirtualMachine.ContainerMount] = [],
        ports: [VirtualMachine.ContainerPort] = []
    ) throws -> String {
        let executable = try requireExecutable()
        
        // 1. If it already exists, try starting it.
        if try workloadExists(name: name, executable: executable) {
            _ = try run(executable: executable, arguments: ["start", name])
            return "Started existing container workload '\(name)'."
        }

        // 2. To avoid stale state or name conflicts, do a preemptive forced delete.
        // If it doesn't exist, this will fail silently via try?.
        _ = try? run(executable: executable, arguments: ["delete", "--force", name])

        let safeCPUs = max(1, cpus)
        let safeMemory = max(50, memoryMB)
        
        // 3. Create the container instance.
        var args = [
            "create",
            "--name", name,
            "--cpus", String(safeCPUs),
            "--memory", "\(safeMemory)M"
        ]
        
        // Add mounts: --mount type=bind,source=/path,target=/path[,readonly]
        for mount in mounts where !mount.hostPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var mountSpec = "type=bind,source=\(mount.hostPath),target=\(mount.containerPath)"
            if mount.isReadOnly {
                mountSpec += ",readonly"
            }
            args.append(contentsOf: ["--mount", mountSpec])
        }
        
        // Add ports: -p [host-ip:]host-port:container-port[/protocol]
        for port in ports {
            let portSpec = "\(port.hostPort):\(port.containerPort)/\(port.protocolName)"
            args.append(contentsOf: ["--publish", portSpec])
        }
        
        args.append(image)
        
        _ = try run(executable: executable, arguments: args)
        
        // 4. Start the created container.
        _ = try run(executable: executable, arguments: ["start", name])
        
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
        let executable = try requireExecutable()
        try ensureSystemRunning()
        
        onProgress(0, "Initiating pull…")
        
        try await performBlocking {
            var lastProgress: Double = 0
            
            let status = try self.runStreaming(
                executable: executable,
                arguments: ["image", "pull", "--progress", "ansi", reference],
                timeout: 600
            ) { output in
                // Parse pattern like [1/2] Fetching image
                if let progress = self.parsePullProgress(from: output) {
                    lastProgress = max(lastProgress, progress)
                    let detail = self.extractStatusDetail(from: output)
                    onProgress(lastProgress, detail)
                }
            }
            
            if status != 0 {
                throw NSError(domain: "AppleContainerService", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to pull image '\(reference)' (exit code \(status))."])
            }
        }
        onProgress(1, "Complete.")
    }

    private func parsePullProgress(from output: String) -> Double? {
        let pattern = #"\[(\d+)/(\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = regex.matches(in: output, options: [], range: range)
        
        // Use the last match in the chunk
        if let match = matches.last, match.numberOfRanges >= 3 {
            if let r1 = Range(match.range(at: 1), in: output),
               let r2 = Range(match.range(at: 2), in: output),
               let cur = Double(output[r1]),
               let total = Double(output[r2]),
               total > 0 {
                return cur / total
            }
        }
        return nil
    }
    
    private func extractStatusDetail(from output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("]") {
                let parts = trimmed.components(separatedBy: "]")
                if parts.count > 1 {
                    return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if !trimmed.isEmpty && trimmed.count > 10 {
                return trimmed
            }
        }
        return ""
    }

    func pullImageAsync(reference: String) async throws {
        try await pullImage(reference: reference) { _, _ in }
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
        memoryMB: Int,
        mounts: [VirtualMachine.ContainerMount] = [],
        ports: [VirtualMachine.ContainerPort] = []
    ) async throws -> String {
        try await performBlocking {
            try self.startWorkload(
                name: name,
                image: image,
                cpus: cpus,
                memoryMB: memoryMB,
                mounts: mounts,
                ports: ports
            )
        }
    }

    func deleteImageAsync(reference: String) async throws {
        try await performBlocking {
            try self.deleteImage(reference: reference)
        }
    }

    // --- MARK: - Stats & Monitoring ---

    func getStats() async throws -> [ContainerStatsInfo] {
        try await performBlocking {
            let executable = try self.requireExecutable()
            let result = try self.run(executable: executable, arguments: ["stats", "--no-stream", "--format", "json"])
            return self.parseStats(from: result.output)
        }
    }

    // --- MARK: - Network Management ---

    func listNetworks() async throws -> [ContainerNetworkInfo] {
        try await performBlocking {
            let executable = try self.requireExecutable()
            let result = try self.run(executable: executable, arguments: ["network", "list", "--format", "json"])
            return self.parseNetworks(from: result.output)
        }
    }

    func createNetwork(name: String, subnet: String? = nil) async throws {
        try await performBlocking {
            let executable = try self.requireExecutable()
            var args = ["network", "create", name]
            if let subnet {
                args.append(contentsOf: ["--subnet", subnet])
            }
            _ = try self.run(executable: executable, arguments: args)
        }
    }

    func deleteNetwork(name: String) async throws {
        try await performBlocking {
            let executable = try self.requireExecutable()
            _ = try self.run(executable: executable, arguments: ["network", "delete", name])
        }
    }

    // --- MARK: - Volume Management ---

    func listVolumes() async throws -> [ContainerVolumeInfo] {
        try await performBlocking {
            let executable = try self.requireExecutable()
            let result = try self.run(executable: executable, arguments: ["volume", "list", "--format", "json"])
            return self.parseVolumes(from: result.output)
        }
    }

    func createVolume(name: String, sizeGB: Int? = nil) async throws {
        try await performBlocking {
            let executable = try self.requireExecutable()
            var args = ["volume", "create", name]
            if let sizeGB {
                args.append(contentsOf: ["-s", "\(sizeGB)G"])
            }
            _ = try self.run(executable: executable, arguments: args)
        }
    }

    func deleteVolume(name: String) async throws {
        try await performBlocking {
            let executable = try self.requireExecutable()
            _ = try self.run(executable: executable, arguments: ["volume", "delete", name])
        }
    }

    func exec(name: String, command: [String]) throws -> (output: String, exitCode: Int32) {
        let executable = try requireExecutable()
        var args = ["exec", name]
        args.append(contentsOf: command)
        return try run(executable: executable, arguments: args)
    }

    func execAsync(name: String, command: [String]) async throws -> (output: String, exitCode: Int32) {
        try await performBlocking {
            try self.exec(name: name, command: command)
        }
    }

    func getContainerIP(name: String) throws -> String? {
        let executable = try requireExecutable()
        let result = try run(executable: executable, arguments: ["list", "--format", "json"])
        
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let rows = json as? [[String: Any]]
        else {
            return nil
        }
        
        for row in rows {
            guard let id = row["id"] as? String, id == name else { continue }
            if let networks = row["networks"] as? [[String: Any]] {
                for net in networks {
                    if let ipv4 = net["ipv4"] as? String, !ipv4.isEmpty { return ipv4 }
                    if let ip = net["ip"] as? String, !ip.isEmpty { return ip }
                    if let address = net["address"] as? String, !address.isEmpty { return address }
                    if let addresses = net["addresses"] as? [String],
                       let first = addresses.first(where: { $0.contains(".") }) {
                        return first.split(separator: "/").first.map(String.init)
                    }
                }
            }
        }
        return nil
    }

    func getContainerIPAsync(name: String) async throws -> String? {
        try await performBlocking {
            try self.getContainerIP(name: name)
        }
    }

    // --- MARK: - Image Management ---

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
            // container inspect returns exit code 0 even if no match, giving "[]" as output.
            let result = try run(executable: executable, arguments: ["inspect", name])
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "[]"
        } catch {
            return false
        }
    }

    private func requireExecutable() throws -> String {
        if FileManager.default.isExecutableFile(atPath: defaultExecutable) {
            return defaultExecutable
        }
        if let result = try? run(executable: "/usr/bin/which", arguments: ["container"], timeout: 2) {
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        throw NSError(domain: "AppleContainerService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple container CLI not found."])
    }

    private func run(executable: String, arguments: [String], timeout: TimeInterval = 30) throws -> (output: String, exitCode: Int32) {
        var output = ""
        let status = try runStreaming(executable: executable, arguments: arguments, timeout: timeout) { str in
            output.append(str)
        }
        if status == 0 { return (output, status) }
        throw NSError(domain: "AppleContainerService", code: 2, userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "container command failed" : output])
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

    private func parseStats(from output: String) -> [ContainerStatsInfo] {
        // Docker/nerdctl/podman output can be a JSON array or newline-delimited JSON objects.
        let rows: [[String: Any]]
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let arr = json as? [[String: Any]] {
            rows = arr
        } else {
            // Fallback: parse NDJSON lines.
            rows = output
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> [String: Any]? in
                    guard let data = String(line).data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data),
                          let dict = obj as? [String: Any] else { return nil }
                    return dict
                }
        }
        if rows.isEmpty { return [] }
        
        func percentDouble(_ raw: Any?) -> Double {
            if let d = raw as? Double { return d }
            if let s = raw as? String {
                return Double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0.0
            }
            return 0.0
        }
        
        return rows.compactMap { row in
            // Docker/nerdctl/podman emit either upper- or lower-cased keys; accept both.
            let name = (row["Name"] as? String) ??
                       (row["name"] as? String) ??
                       (row["ID"] as? String) ??
                       (row["id"] as? String)
            guard let resolvedName = name, !resolvedName.isEmpty else { return nil }
            
            let cpu = percentDouble(row["CPUPerc"] ?? row["cpuPercentage"])
            let memPct = percentDouble(row["MemPerc"] ?? row["memoryPercentage"])
            
            let memUsage = (row["MemUsage"] as? String) ?? (row["memoryUsage"] as? String) ?? "0B"
            let memLimit = (row["MemLimit"] as? String) ?? (row["memoryLimit"] as? String) ?? "0B"
            let netIO = (row["NetIO"] as? String) ?? (row["networkIO"] as? String) ?? "0B / 0B"
            let blockIO = (row["BlockIO"] as? String) ?? (row["blockIO"] as? String) ?? "0B / 0B"
            
            let netParts = netIO.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            let blkParts = blockIO.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            
            let pids = (row["PIDs"] as? Int) ?? (row["processCount"] as? Int) ?? 0
            
            return ContainerStatsInfo(
                id: resolvedName,
                cpuPercentage: cpu,
                memoryUsage: memUsage,
                memoryLimit: memLimit,
                memoryPercentage: memPct,
                networkIn: netParts.first ?? "0B",
                networkOut: netParts.count > 1 ? netParts[1] : "0B",
                blockIn: blkParts.first ?? "0B",
                blockOut: blkParts.count > 1 ? blkParts[1] : "0B",
                processCount: pids
            )
        }
    }

    private func parseNetworks(from output: String) -> [ContainerNetworkInfo] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let rows = json as? [[String: Any]]
        else {
            return []
        }
        return rows.compactMap { row in
            guard let config = row["config"] as? [String: Any],
                  let id = config["id"] as? String
            else { return nil }
            
            let status = row["status"] as? [String: Any]
            return ContainerNetworkInfo(
                id: id,
                mode: (config["mode"] as? String) ?? "nat",
                gateway: (status?["ipv4Gateway"] as? String) ?? "",
                subnet: (status?["ipv4Subnet"] as? String) ?? "",
                state: (row["state"] as? String) ?? "unknown"
            )
        }
    }

    private func parseVolumes(from output: String) -> [ContainerVolumeInfo] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let rows = json as? [[String: Any]]
        else {
            return []
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return ContainerVolumeInfo(
                id: name,
                mountpoint: (row["mountpoint"] as? String) ?? "",
                size: (row["size"] as? String) ?? "0B",
                driver: (row["driver"] as? String) ?? "local"
            )
        }
    }

    private func runStreaming(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 600,
        onOutput: @escaping (String) -> Void
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { return }
            if let str = String(data: data, encoding: .utf8) {
                onOutput(str)
            }
        }
        
        do {
            try process.run()
            
            let start = Date()
            while process.isRunning {
                if Date().timeIntervalSince(start) > timeout {
                    process.terminate()
                    throw NSError(domain: "AppleContainerService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Command timed out."])
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            handle.readabilityHandler = nil
            // Capture any remaining data
            let remaining = try? handle.readToEnd()
            if let remaining, let str = String(data: remaining, encoding: .utf8) {
                onOutput(str)
            }
            
            return process.terminationStatus
        } catch {
            handle.readabilityHandler = nil
            throw error
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

struct ContainerStatsInfo: Identifiable, Codable {
    let id: String
    let cpuPercentage: Double
    let memoryUsage: String
    let memoryLimit: String
    let memoryPercentage: Double
    let networkIn: String
    let networkOut: String
    let blockIn: String
    let blockOut: String
    let processCount: Int
}

struct ContainerNetworkInfo: Identifiable, Codable {
    let id: String
    let mode: String
    let gateway: String
    let subnet: String
    let state: String
}

struct ContainerVolumeInfo: Identifiable, Codable {
    let id: String
    let mountpoint: String
    let size: String
    let driver: String
}
