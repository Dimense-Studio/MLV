import Foundation
import CryptoKit

@Observable
final class WireGuardManager {
    struct HostInfo: Codable, Hashable {
        let id: String
        let name: String
        let publicKey: String
        let endpointHost: String
        let endpointPort: Int
        let vmSubnet: String

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
        let vmSubnet: String
    }

    static let shared = WireGuardManager()

    private let keyPrivateKey = "MLV_WG_PrivateKey"
    private let keyPeers = "MLV_WG_Peers"
    private let keyListenPort = "MLV_WG_ListenPort"

    var peers: [Peer] = []

    private init() {
        loadPeers()
    }

    var hostInfo: HostInfo {
        let id = Host.current().localizedName ?? "MLV Host"
        let name = Host.current().localizedName ?? "MLV"
        let pub = publicKeyBase64
        let epHost = HostResources.getNetworkInterfaces().compactMap { HostResources.ipAddress(for: $0.bsdName) }.first ?? "0.0.0.0"
        let epPort = listenPort
        let subnet = "192.168.64.0/24"
        return HostInfo(id: id, name: name, publicKey: pub, endpointHost: epHost, endpointPort: epPort, vmSubnet: subnet)
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

    func startDiscovery() {
        DiscoveryManager.shared.start(myInfo: hostInfo)
    }

    func pair(discovered: DiscoveryManager.DiscoveredHost) {
        DiscoveryManager.shared.requestPeerInfo(discovered) { info in
            guard let info else { return }
            DispatchQueue.main.async {
                if self.peers.contains(where: { $0.publicKey == info.publicKey }) { return }
                self.peers.append(Peer(id: info.id, name: info.name, publicKey: info.publicKey, endpointHost: info.endpointHost, endpointPort: info.endpointPort, vmSubnet: info.vmSubnet))
                self.persistPeers()
            }
        }
    }

    func exportConfig() -> String {
        var lines: [String] = []
        lines.append("[Interface]")
        lines.append("PrivateKey = \(privateKeyBase64)")
        lines.append("ListenPort = \(listenPort)")
        lines.append("")
        for peer in peers {
            lines.append("[Peer]")
            lines.append("PublicKey = \(peer.publicKey)")
            lines.append("AllowedIPs = \(peer.vmSubnet)")
            if !peer.endpointHost.isEmpty, peer.endpointPort != 0 {
                lines.append("Endpoint = \(peer.endpointHost):\(peer.endpointPort)")
            }
            lines.append("PersistentKeepalive = 25")
            lines.append("")
        }
        return lines.joined(separator: "\n")
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
