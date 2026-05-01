import Foundation
import Network
import AppKit
import SwiftUI
import Combine

/// Real-time network topology monitoring with actual reachability testing.
/// Replaces fake hash-based metrics with real ping/latency measurements.
final class NetworkTopologyMonitor: ObservableObject {
    static let shared = NetworkTopologyMonitor()

    struct NodeMetrics: Identifiable, Equatable {
        let id: String
        var name: String
        var latencyMS: Int = 0
        var throughputMbps: Int = 0
        var isReachable: Bool = false
        var lastChecked: Date = Date.distantPast
        var checkCount: Int = 0
        var averageLatency: Double = 0
    }

    @Published private(set) var metrics: [String: NodeMetrics] = [:]
    private var timer: Timer?
    private let monitorQueue = DispatchQueue(label: "com.mlv.network-topology", qos: .utility)
    private var pingTasks: [String: Task<Void, Never>] = [:]

    private init() {
        startMonitoring()
    }

    // MARK: - Public API

    func metrics(for nodeID: String, name: String) -> NodeMetrics {
        if var existing = metrics[nodeID] {
            // Update name if changed
            if existing.name != name {
                existing.name = name
                metrics[nodeID] = existing
            }
            return existing
        }
        // Create new entry with unknown state
        let new = NodeMetrics(id: nodeID, name: name)
        metrics[nodeID] = new
        // Trigger immediate check on background queue
        Task { [weak self] in
            await self?.checkNode(nodeID)
        }
        return new
    }

    func isNodeReachable(_ nodeID: String) -> Bool {
        metrics[nodeID]?.isReachable ?? false
    }

    func refreshNow() {
        checkAllNodes()
    }

    // MARK: - Monitoring Loop

    private func startMonitoring() {
        // Check every 10 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkAllNodes()
        }
        // Initial check
        checkAllNodes()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        pingTasks.values.forEach { $0.cancel() }
        pingTasks.removeAll()
    }

    private func checkAllNodes() {
        Task {
            let ids = Array(metrics.keys)
            for id in ids {
                await checkNode(id)
            }
        }
    }

    private func checkNode(_ nodeID: String) async {
        // Cancel existing check for this node
        pingTasks[nodeID]?.cancel()

        guard metrics[nodeID] != nil else { return }

        // Get the actual IP address for the node
        let ip = await resolveIP(for: nodeID)
        guard !ip.isEmpty else {
            await updateMetrics(nodeID, isReachable: false, latency: 0)
            return
        }

        // Perform actual ping
        let result = await ping(host: ip, count: 3)

        guard !Task.isCancelled else { return }

        let avgLatency = result.latencies.isEmpty ? 0 : Int(result.latencies.reduce(0, +) / Double(result.latencies.count))
        let isReachable = result.received > 0
        let packetLoss = result.sent > 0 ? Double(result.sent - result.received) / Double(result.sent) : 1.0

        // Calculate throughput estimate based on latency and packet loss
        let throughput = estimateThroughput(latency: avgLatency, packetLoss: packetLoss)

        await updateMetrics(
            nodeID,
            isReachable: isReachable,
            latency: avgLatency,
            throughput: throughput
        )
    }

    @MainActor
    private func updateMetrics(_ nodeID: String, isReachable: Bool, latency: Int, throughput: Int = 0) {
        guard var node = metrics[nodeID] else { return }

        node.isReachable = isReachable
        node.latencyMS = latency
        node.throughputMbps = throughput
        node.lastChecked = Date()
        node.checkCount += 1

        // Running average for stability
        if node.checkCount == 1 {
            node.averageLatency = Double(latency)
        } else {
            node.averageLatency = (node.averageLatency * 0.7) + (Double(latency) * 0.3)
        }

        metrics[nodeID] = node
    }

    // MARK: - Network Testing

    private func resolveIP(for nodeID: String) async -> String {
        // Check WireGuard peers first
        if let peer = WireGuardManager.shared.peers.first(where: { $0.id == nodeID }) {
            return peer.addressCIDR.split(separator: "/").first.map(String.init) ?? ""
        }

        // Check discovered hosts
        if let host = DiscoveryManager.shared.discovered.first(where: { $0.id == nodeID }) {
            return host.addressCIDR.split(separator: "/").first.map(String.init) ?? ""
        }

        // Local host
        if nodeID == WireGuardManager.shared.hostInfo.id {
            return "127.0.0.1"
        }

        return ""
    }

    private func ping(host: String, count: Int) async -> (sent: Int, received: Int, latencies: [Double]) {
        return await withCheckedContinuation { continuation in
            monitorQueue.async {
                var latencies: [Double] = []
                var received = 0

                for i in 0..<count {
                    let start = Date()
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/sbin/ping")
                    task.arguments = ["-c", "1", "-W", "2", host]

                    let pipe = Pipe()
                    task.standardOutput = pipe
                    task.standardError = pipe

                    do {
                        try task.run()
                        task.waitUntilExit()

                        if task.terminationStatus == 0 {
                            received += 1
                            let elapsed = Date().timeIntervalSince(start) * 1000
                            latencies.append(elapsed)
                        }
                    } catch {
                        // Ping failed
                    }

                    if i < count - 1 {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }

                continuation.resume(returning: (sent: count, received: received, latencies: latencies))
            }
        }
    }

    private func estimateThroughput(latency: Int, packetLoss: Double) -> Int {
        // Simple estimation based on latency and packet loss
        // Lower latency + no loss = higher throughput
        let baseThroughput = max(0, 500 - latency * 2)
        let lossPenalty = Int(packetLoss * 300)
        return max(10, baseThroughput - lossPenalty)
    }

    // MARK: - Connection Quality

    func connectionQuality(for nodeID: String) -> ConnectionQuality {
        guard let node = metrics[nodeID] else { return .unknown }
        guard node.isReachable else { return .offline }

        if node.latencyMS < 20 { return .excellent }
        if node.latencyMS < 50 { return .good }
        if node.latencyMS < 100 { return .fair }
        return .poor }

    enum ConnectionQuality: String {
        case excellent = "Excellent"
        case good = "Good"
        case fair = "Fair"
        case poor = "Poor"
        case offline = "Offline"
        case unknown = "Unknown"

        var color: Color {
            switch self {
            case .excellent: return .green
            case .good: return .cyan
            case .fair: return .yellow
            case .poor: return .orange
            case .offline: return .red
            case .unknown: return .gray
            }
        }
    }
}
