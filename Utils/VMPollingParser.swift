import Foundation

enum VMPollingParser {
    static func extractSectionLines(
        from lines: inout [String],
        startMarker: String,
        endMarker: String
    ) -> [String] {
        guard let startIndex = lines.firstIndex(of: startMarker) else { return [] }
        guard let endIndex = lines[(startIndex + 1)...].firstIndex(of: endMarker), endIndex > startIndex else {
            lines.remove(at: startIndex)
            return []
        }

        let section = Array(lines[(startIndex + 1)..<endIndex])
        lines.removeSubrange(startIndex...endIndex)
        return section
    }

    static func parsePods(from lines: [String]) -> [VirtualMachine.Pod] {
        guard !lines.contains(where: { $0.contains("K3S_NOT_READY") }) else { return [] }
        var pods: [VirtualMachine.Pod] = []
        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            pods.append(
                VirtualMachine.Pod(
                    name: parts[safe: 1] ?? "unknown",
                    status: parts[safe: 2] ?? "Unknown",
                    cpu: parts[safe: 3].flatMap { $0.isEmpty ? nil : $0 } ?? "N/A",
                    ram: parts[safe: 4].flatMap { $0.isEmpty ? nil : $0 } ?? "N/A",
                    namespace: parts[safe: 0] ?? "default"
                )
            )
        }
        return pods
    }

    static func parseContainers(from lines: [String]) -> [VirtualMachine.Container] {
        guard !lines.contains(where: { $0.contains("CONTAINERS_NOT_READY") }) else { return [] }
        var containers: [VirtualMachine.Container] = []
        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            containers.append(
                VirtualMachine.Container(
                    name: parts[safe: 0] ?? "container",
                    image: parts[safe: 1] ?? "unknown",
                    status: parts[safe: 2] ?? "Unknown",
                    runtime: parts[safe: 3].flatMap { $0.isEmpty ? nil : $0 } ?? "docker"
                )
            )
        }
        return containers
    }
}
