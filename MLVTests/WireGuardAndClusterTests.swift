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
}
