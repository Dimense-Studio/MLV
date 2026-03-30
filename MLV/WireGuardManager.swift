import Foundation
import CryptoKit
import AppKit

/// Manages the WireGuard peer mesh which is now fully automatic.
/// It selects the fastest available interface for endpoint hosting,
/// preferring thunderbolt, then ethernet, then wifi.
@Observable
final class WireGuardManager {
    struct HostInfo: Codable, Hashable {
        let id: String
        let name: String
        let publicKey: String
        let endpointHost: String
        let endpointPort: Int
        let addressCIDR: String
        let advertisedRoutes: [String]
        let cpuCount: Int
        let memoryGB: Int
        let freeDiskGB: Int

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
    private let keyPrivateKey = "MLV_WG_PrivateKey"
    private let keyPeers = "MLV_WG_Peers"
    private let keyListenPort = "MLV_WG_ListenPort"
    private let keyInterfaceAddress = "MLV_WG_InterfaceAddressCIDR"
    private let keyLastConfigPath = "MLV_WG_LastConfigPath"

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
        let pub = publicKeyBase64
        let epHost = HostResources.preferredIPv4Address(preferredTypes: [.thunderbolt, .ethernet, .wifi]) ?? "0.0.0.0"
        let epPort = listenPort
        return HostInfo(
            id: id,
            name: name,
            publicKey: pub,
            endpointHost: epHost,
            endpointPort: epPort,
            addressCIDR: interfaceAddressCIDR,
            advertisedRoutes: [],
            cpuCount: HostResources.cpuCount,
            memoryGB: HostResources.totalMemoryGB,
            freeDiskGB: HostResources.freeDiskSpaceGB
        )
    }

    var publicKeyShort: String {
        let pub = publicKeyBase64
        return String(pub.prefix(10))
    }

    var listenPort: Int {
        get {
            let port = UserDefaults.standard.integer(forKey: keyListenPort)
            return port == 0 ? 51820 : port
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyListenPort)
        }
    }

    var publicKeyBase64: String {
        let priv = privateKey
        let pub = priv.publicKey.rawRepresentation
        return Data(pub).base64EncodedString()
    }

    /// Starts peer discovery and pairing process.
    /// Pairing is now always automatic and requires no user action.
    func startDiscovery() {
        let token = VMManager.shared.clusterToken
        DiscoveryManager.shared.onUpdate = { hosts in
            for host in hosts {
                WireGuardManager.shared.pair(discovered: host)
            }
            let ids = Set(hosts.map { $0.id })
            WireGuardManager.shared.removeStalePeers(currentIDs: ids)
        }
        DiscoveryManager.shared.start(myInfo: hostInfo, clusterToken: token)
    }

    func pair(discovered: DiscoveryManager.DiscoveredHost) {
        DiscoveryManager.shared.requestPeerInfo(discovered) { info in
            guard let info else { return }
            DispatchQueue.main.async {
                self.addOrUpdatePeer(from: info)
                DiscoveryManager.shared.removeDiscovered(id: discovered.id)
            }
        }
    }
    
    func addOrUpdatePeer(from info: HostInfo) {
        let allowed = Array(Set(info.advertisedRoutes + [info.addressCIDR])).sorted()
        let updated = Peer(
            id: info.id,
            name: info.name,
            publicKey: info.publicKey,
            endpointHost: info.endpointHost,
            endpointPort: info.endpointPort,
            addressCIDR: info.addressCIDR,
            allowedIPs: allowed
        )
        
        if let idx = peers.firstIndex(where: { $0.id == info.id || $0.publicKey == info.publicKey }) {
            peers[idx] = updated
        } else {
            peers.append(updated)
        }
        persistPeers()
        self.writeConfigToDisk()
    }

    /// Removes peers not in the provided set of IDs
    func removeStalePeers(currentIDs: Set<String>) {
        let before = peers.count
        peers.removeAll { !currentIDs.contains($0.id) }
        if peers.count != before {
            persistPeers()
            writeConfigToDisk()
        }
    }

    func exportConfig() -> String {
        var lines: [String] = []
        lines.append("[Interface]")
        lines.append("PrivateKey = \(privateKeyBase64)")
        lines.append("Address = \(interfaceAddressCIDR)")
        lines.append("ListenPort = \(listenPort)")
        lines.append("")
        for peer in peers {
            lines.append("[Peer]")
            lines.append("PublicKey = \(peer.publicKey)")
            lines.append("AllowedIPs = \(peer.allowedIPs.joined(separator: ", "))")
            if !peer.endpointHost.isEmpty, peer.endpointPort != 0 {
                lines.append("Endpoint = \(peer.endpointHost):\(peer.endpointPort)")
            }
            lines.append("PersistentKeepalive = 25")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
    
    func writeConfigToDisk() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("MLV", isDirectory: true).appendingPathComponent("WireGuard", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        
        let fileURL = dir.appendingPathComponent("MLV.conf")
        do {
            try exportConfig().write(to: fileURL, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(fileURL.path, forKey: keyLastConfigPath)
            return fileURL
        } catch {
            return nil
        }
    }
    
    func copyConfigToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportConfig(), forType: .string)
    }
    
    func openConfigInWireGuard() {
        guard let url = writeConfigToDisk() else { return }
        NSWorkspace.shared.open(url)
    }
    
    func revealConfigInFinder() {
        guard let url = writeConfigToDisk() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var privateKeyBase64: String {
        Data(privateKey.rawRepresentation).base64EncodedString()
    }

    private var privateKey: Curve25519.KeyAgreement.PrivateKey {
        if let data = UserDefaults.standard.data(forKey: keyPrivateKey),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        UserDefaults.standard.set(key.rawRepresentation, forKey: keyPrivateKey)
        return key
    }
    
    func deriveClusterSymmetricKey(peerPublicKeyBase64: String) -> SymmetricKey? {
        guard let peerData = Data(base64Encoded: peerPublicKeyBase64),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else {
            return nil
        }
        let salt = Data(VMManager.shared.clusterToken.utf8)
        let info = Data("MLV_CLUSTER_RPC".utf8)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
    }
    
    private var interfaceAddressCIDR: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: keyInterfaceAddress), !stored.isEmpty {
                return stored
            }
            let rawPub = Data(base64Encoded: publicKeyBase64) ?? Data(publicKeyBase64.utf8)
            let hash = SHA256.hash(data: rawPub)
            var it = hash.makeIterator()
            let firstByte = it.next() ?? 1
            let octet = Int(firstByte) % 253 + 2
            let addr = "10.13.10.\(octet)/32"
            UserDefaults.standard.set(addr, forKey: keyInterfaceAddress)
            return addr
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyInterfaceAddress)
        }
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

