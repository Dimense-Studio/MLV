import Foundation
import CryptoKit
import AppKit

/// Manages direct IP peer connections without WireGuard tunneling.
/// Uses device IP addresses for RPC communication.
@Observable
final class WireGuardManager {
    struct HostInfo: Codable, Hashable {
        let id: String
        let name: String
        let publicKey: String  // Kept for backward compatibility but not used for crypto
        let endpointHost: String
        let endpointPort: Int
        let addressCIDR: String  // Device IP address (not WireGuard)
        let advertisedRoutes: [String]
        let cpuCount: Int
        let memoryGB: Int
        let freeDiskGB: Int
        let primaryInterfaceType: HostResources.NetworkInterface.InterfaceType?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case publicKey
            case endpointHost
            case endpointPort
            case addressCIDR
            case advertisedRoutes
            case cpuCount
            case memoryGB
            case freeDiskGB
        }

        init(id: String, name: String, publicKey: String, endpointHost: String, endpointPort: Int, addressCIDR: String, advertisedRoutes: [String], cpuCount: Int, memoryGB: Int, freeDiskGB: Int, primaryInterfaceType: HostResources.NetworkInterface.InterfaceType? = nil) {
            self.id = id
            self.name = name
            self.publicKey = publicKey
            self.endpointHost = endpointHost
            self.endpointPort = endpointPort
            self.addressCIDR = addressCIDR
            self.advertisedRoutes = advertisedRoutes
            self.cpuCount = cpuCount
            self.memoryGB = memoryGB
            self.freeDiskGB = freeDiskGB
            self.primaryInterfaceType = primaryInterfaceType
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            publicKey = try container.decode(String.self, forKey: .publicKey)
            endpointHost = try container.decode(String.self, forKey: .endpointHost)
            endpointPort = try container.decode(Int.self, forKey: .endpointPort)
            addressCIDR = try container.decode(String.self, forKey: .addressCIDR)
            advertisedRoutes = try container.decode([String].self, forKey: .advertisedRoutes)
            cpuCount = try container.decode(Int.self, forKey: .cpuCount)
            memoryGB = try container.decode(Int.self, forKey: .memoryGB)
            freeDiskGB = try container.decode(Int.self, forKey: .freeDiskGB)
            primaryInterfaceType = nil
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(publicKey, forKey: .publicKey)
            try container.encode(endpointHost, forKey: .endpointHost)
            try container.encode(endpointPort, forKey: .endpointPort)
            try container.encode(addressCIDR, forKey: .addressCIDR)
            try container.encode(advertisedRoutes, forKey: .advertisedRoutes)
            try container.encode(cpuCount, forKey: .cpuCount)
            try container.encode(memoryGB, forKey: .memoryGB)
            try container.encode(freeDiskGB, forKey: .freeDiskGB)
        }

        func jsonData() -> Data {
            (try? JSONEncoder().encode(self)) ?? Data()
        }

        static func fromJSON(data: Data) -> HostInfo? {
            try? JSONDecoder().decode(HostInfo.self, from: data)
        }
    }

    struct Peer: Identifiable, Hashable, Codable {
        let id: String
        let name: String
        let publicKey: String
        let endpointHost: String
        let endpointPort: Int
        let addressCIDR: String
        let allowedIPs: [String]
    }

    static let shared = WireGuardManager()

    private let keyNodeID = "MLV_Node_ID"
    private let keyPeers = "MLV_Peers_DirectIP"
    private let keyLastEndpoint = "MLV_LastEndpointHost"

    var peers: [Peer] = []

    private init() {
        loadPeers()
    }

    private var nodeID: String {
        if let existing = UserDefaults.standard.string(forKey: keyNodeID), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: keyNodeID)
        return created
    }

    var hostInfo: HostInfo {
        let id = nodeID
        let name = Host.current().localizedName ?? "MLV"

        // Use priority-based interface selection: Thunderbolt > Ethernet > WiFi
        let best = HostResources.bestAvailableInterface()
        let epHost = best?.ipv4 ?? "127.0.0.1"
        let epPort = rpcPort

        // Use the same priority-based IP for the address
        let deviceIP = best?.ipv4 ?? "127.0.0.1"
        let primaryType = best?.type ?? .unknown

        // Get VM routes for reference
        let vmRoutes = VMManager.shared.virtualMachines
            .filter { $0.state == .running || $0.state == .starting }
            .compactMap { vm -> String? in
                guard !vm.ipAddress.isEmpty && vm.ipAddress != "Detecting..." else { return nil }
                return vm.ipAddress + "/32"
            }

        // Also advertise all active interface IPs for fallback connectivity
        let allActiveIPs = HostResources.activeInterfacesWithPriority()
            .compactMap { $0.1 }
            .filter { $0 != deviceIP }

        return HostInfo(
            id: id,
            name: name,
            publicKey: id,
            endpointHost: epHost,
            endpointPort: epPort,
            addressCIDR: deviceIP + "/32",
            advertisedRoutes: Array(Set(vmRoutes + allActiveIPs.map { $0 + "/32" })).sorted(),
            cpuCount: HostResources.cpuCount,
            memoryGB: HostResources.totalMemoryGB,
            freeDiskGB: HostResources.freeDiskSpaceGB,
            primaryInterfaceType: primaryType
        )
    }

    var publicKeyShort: String {
        String(nodeID.prefix(10))
    }

    var listenPort: Int {
        rpcPort
    }

    var publicKeyBase64: String {
        nodeID
    }

    var rpcPort: Int {
        7124
    }

    /// Starts peer discovery and pairing process.
    func startDiscovery() {
        DiscoveryManager.shared.start(myInfo: hostInfo)
    }

    func pair(
        discovered: DiscoveryManager.DiscoveredHost,
        completion: ((Bool, String?) -> Void)? = nil
    ) {
        DiscoveryManager.shared.requestPeerInfo(discovered) { info in
            guard let info else {
                DispatchQueue.main.async {
                    let failure = DiscoveryManager.shared.pairStatusByID[discovered.id] ?? "Pair failed"
                    completion?(false, failure)
                }
                return
            }
            DispatchQueue.main.async {
                self.addOrUpdatePeer(from: info)
                completion?(true, nil)
            }
        }
    }
    
    func addOrUpdatePeer(from info: HostInfo) {
        let updated = Peer(
            id: info.id,
            name: info.name,
            publicKey: info.publicKey,
            endpointHost: info.endpointHost,
            endpointPort: info.endpointPort,
            addressCIDR: info.addressCIDR,
            allowedIPs: info.advertisedRoutes
        )
        
        if let idx = peers.firstIndex(where: { $0.id == info.id }) {
            peers[idx] = updated
        } else {
            peers.append(updated)
        }
        persistPeers()
    }

    func removePeer(id: String) {
        let before = peers.count
        peers.removeAll { $0.id == id }
        if peers.count != before {
            persistPeers()
        }
    }

    /// Removes peers not in the provided set of IDs
    func removeStalePeers(currentIDs: Set<String>) {
        let before = peers.count
        peers.removeAll { !currentIDs.contains($0.id) }
        if peers.count != before {
            persistPeers()
        }
    }

    // MARK: - Deprecated methods (no-op or minimal)
    
    func exportConfig() -> String {
        return "# Direct IP mode - no WireGuard config needed"
    }
    
    func writeConfigToDisk() -> URL? {
        return nil
    }
    
    func copyConfigToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportConfig(), forType: .string)
    }
    
    func openConfigInWireGuard() {
        // No-op in direct IP mode
    }
    
    func revealConfigInFinder() {
        // No-op in direct IP mode
    }
    
    func deriveClusterSymmetricKey(peerPublicKeyBase64: String) -> SymmetricKey? {
        // In direct IP mode, we don't use encryption
        // Return a static key for backward compatibility
        return SymmetricKey(data: Data(repeating: 0, count: 32))
    }

    private func loadPeers() {
        guard let data = UserDefaults.standard.data(forKey: keyPeers),
              let decoded = try? JSONDecoder().decode([Peer].self, from: data) else {
            peers = []
            return
        }
        peers = decoded
    }

    private func persistPeers() {
        if let data = try? JSONEncoder().encode(peers) {
            UserDefaults.standard.set(data, forKey: keyPeers)
        }
    }
}
