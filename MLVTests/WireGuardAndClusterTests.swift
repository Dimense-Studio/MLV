import XCTest
@testable import MLV

final class WireGuardAndClusterTests: XCTestCase {
    func testWireGuardExportIncludesInterfaceAddressAndAllowedIPs() {
        let wg = WireGuardManager.shared
        let oldPeers = wg.peers
        defer { wg.peers = oldPeers }
        
        wg.peers = [
            WireGuardManager.Peer(
                id: "peer-1",
                name: "Peer One",
                publicKey: WireGuardKeyUtils.generateKeypairBase64().publicKey,
                endpointHost: "10.0.0.2",
                endpointPort: 51820,
                addressCIDR: "10.13.10.2/32",
                allowedIPs: ["10.13.10.2/32"]
            )
        ]
        
        let cfg = wg.exportConfig()
        XCTAssertTrue(cfg.contains("[Interface]"))
        XCTAssertTrue(cfg.contains("Address = "))
        XCTAssertTrue(cfg.contains("[Peer]"))
        XCTAssertTrue(cfg.contains("AllowedIPs = 10.13.10.2/32"))
    }
    
    func testClusterBestNodeSelectsMostFreeDiskThenMemory() {
        let cm = ClusterManager.shared
        let now = Date()
        cm.nodes = [
            .init(id: "a", name: "A", publicKey: "k", endpointHost: "1.1.1.1", endpointPort: 7123, addressCIDR: "10.13.10.10/32", cpuCount: 8, memoryGB: 16, freeDiskGB: 200, lastSeen: now),
            .init(id: "b", name: "B", publicKey: "k2", endpointHost: "2.2.2.2", endpointPort: 7123, addressCIDR: "10.13.10.11/32", cpuCount: 8, memoryGB: 32, freeDiskGB: 150, lastSeen: now)
        ]
        
        let spec = ClusterManager.VMRequestSpec(name: "x", cpus: 4, ramGB: 8, sysDiskGB: 64, dataDiskGB: 64, isMaster: false, distroRawValue: VirtualMachine.LinuxDistro.debian13.rawValue)
        let best = cm.bestNode(for: spec)
        XCTAssertEqual(best?.id, "a")
    }

    func testPollingParserParsesPodsAndContainers() {
        var lines = [
            "10.0.0.5",
            "10.0.0.1",
            "1.1.1.1 8.8.8.8",
            "---PODS_START---",
            "default|api-7f9bb|Running|100m|256Mi",
            "---PODS_END---",
            "---CONTAINERS_START---",
            "web|nginx:1.27|Up 2 minutes|docker",
            "---CONTAINERS_END---"
        ]

        let podLines = VMPollingParser.extractSectionLines(
            from: &lines,
            startMarker: "---PODS_START---",
            endMarker: "---PODS_END---"
        )
        let containerLines = VMPollingParser.extractSectionLines(
            from: &lines,
            startMarker: "---CONTAINERS_START---",
            endMarker: "---CONTAINERS_END---"
        )

        let pods = VMPollingParser.parsePods(from: podLines)
        let containers = VMPollingParser.parseContainers(from: containerLines)

        XCTAssertEqual(pods.count, 1)
        XCTAssertEqual(pods.first?.namespace, "default")
        XCTAssertEqual(pods.first?.name, "api-7f9bb")
        XCTAssertEqual(pods.first?.status, "Running")

        XCTAssertEqual(containers.count, 1)
        XCTAssertEqual(containers.first?.name, "web")
        XCTAssertEqual(containers.first?.image, "nginx:1.27")
        XCTAssertEqual(containers.first?.runtime, "docker")
    }

    func testStorageManagerCreatesSparseDiskWithExpectedSize() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlv-test-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try VMStorageManager.shared.createSparseDisk(at: tempFile, sizeGiB: 1, preallocate: false)
        let attrs = try FileManager.default.attributesOfItem(atPath: tempFile.path)
        let size = attrs[.size] as? NSNumber

        XCTAssertEqual(size?.int64Value, 1_073_741_824)
    }
}
