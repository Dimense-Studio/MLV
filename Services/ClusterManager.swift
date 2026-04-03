import CryptoKit
import Foundation
import Network
import SwiftUI

@Observable
final class ClusterManager {
    static let shared = ClusterManager()
    
    struct Node: Identifiable, Hashable {
        let id: String
        let name: String
        let publicKey: String
        let endpointHost: String
        let endpointPort: Int
        let addressCIDR: String
        let cpuCount: Int
        let memoryGB: Int
        let freeDiskGB: Int
        let lastSeen: Date
    }
    
    struct VMRequestSpec: Codable, Hashable {
        let name: String
        let cpus: Int
        let ramGB: Int
        let sysDiskGB: Int
        let dataDiskGB: Int
        let isMaster: Bool
        let distroRawValue: String
    }
    
    struct VMInfo: Codable, Hashable, Identifiable {
        let id: UUID
        let name: String
        let state: String
        let cpuCount: Int
        let memoryGB: Int
    }
    
    struct RPCRequest: Codable {
        let id: String
        let type: String
        let payload: Data?
        let metadata: [String: String]?

        init(id: String, type: String, payload: Data?, metadata: [String: String]? = nil) {
            self.id = id
            self.type = type
            self.payload = payload
            self.metadata = metadata
        }
    }
    
    struct RPCResponse: Codable {
        let id: String
        let ok: Bool
        let payload: Data?
        let errorMessage: String?
        let metadata: [String: String]?

        init(id: String, ok: Bool, payload: Data?, errorMessage: String?, metadata: [String: String]? = nil) {
            self.id = id
            self.ok = ok
            self.payload = payload
            self.errorMessage = errorMessage
            self.metadata = metadata
        }
    }
    
    struct Envelope: Codable {
        let senderID: String
        let senderPublicKey: String
        let sealedBoxCombined: Data
    }

    struct BandwidthTestResult: Codable {
        let receiverID: String
        let receiverName: String
        let mbps: Double
    }
    
    private let rpcPort: NWEndpoint.Port = 7124
    private let maxRPCPayloadBytes = 160 * 1024 * 1024
    private let rpcReplyMaxBytes = 4 * 1024 * 1024
    private var listener: NWListener?
    private static let bandwidthBlob100MB = Data(repeating: 0xA5, count: 100 * 1024 * 1024)
    
    var nodes: [Node] = []
    
    private init() {}
    
    func start() {
        startListener()
        WireGuardManager.shared.startDiscovery()
        DiscoveryManager.shared.onUpdate = { [weak self] hosts in
            guard let self else { return }
            let ids = Set(hosts.map(\.id))
            WireGuardManager.shared.removeStalePeers(currentIDs: ids)
            for host in hosts {
                self.refreshNodeInfo(for: host)
            }
        }
    }
    
    private func refreshNodeInfo(for host: DiscoveryManager.DiscoveredHost) {
        DiscoveryManager.shared.requestPeerInfo(host) { info in
            guard let info else { return }
            DispatchQueue.main.async {
                WireGuardManager.shared.addOrUpdatePeer(from: info)
                let node = Node(
                    id: info.id,
                    name: info.name,
                    publicKey: info.publicKey,
                    endpointHost: info.endpointHost,
                    endpointPort: info.endpointPort,
                    addressCIDR: info.addressCIDR,
                    cpuCount: info.cpuCount,
                    memoryGB: info.memoryGB,
                    freeDiskGB: info.freeDiskGB,
                    lastSeen: Date()
                )
                var byId = Dictionary(uniqueKeysWithValues: self.nodes.map { ($0.id, $0) })
                byId[node.id] = node
                self.nodes = Array(byId.values).sorted { $0.name < $1.name }
            }
        }
    }
    
    func bestNode(for spec: VMRequestSpec) -> Node? {
        let eligible = nodes.filter { $0.freeDiskGB >= (spec.sysDiskGB + spec.dataDiskGB) && $0.memoryGB >= spec.ramGB }
        return eligible.sorted { a, b in
            if a.freeDiskGB != b.freeDiskGB { return a.freeDiskGB > b.freeDiskGB }
            if a.memoryGB != b.memoryGB { return a.memoryGB > b.memoryGB }
            return a.cpuCount > b.cpuCount
        }.first
    }
    
    func createVMOnNode(_ node: Node, spec: VMRequestSpec) async throws -> UUID {
        let requestID = UUID().uuidString
        let payload = try JSONEncoder().encode(spec)
        let req = RPCRequest(id: requestID, type: "createVM", payload: payload)
        let resp = try await send(req, to: node)
        guard resp.ok, let data = resp.payload else {
            throw NSError(domain: "ClusterRPC", code: 1, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage ?? "Remote VM creation failed"])
        }
        let created = try JSONDecoder().decode(UUID.self, from: data)
        return created
    }
    
    func listVMs(on node: Node) async throws -> [VMInfo] {
        let requestID = UUID().uuidString
        let req = RPCRequest(id: requestID, type: "listVMs", payload: nil)
        let resp = try await send(req, to: node)
        guard resp.ok, let data = resp.payload else {
            throw NSError(domain: "ClusterRPC", code: 2, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage ?? "Remote list failed"])
        }
        return try JSONDecoder().decode([VMInfo].self, from: data)
    }

    func runBandwidthTest(to peer: WireGuardManager.Peer, senderName: String) async throws -> BandwidthTestResult {
        let node = Node(
            id: peer.id,
            name: peer.name,
            publicKey: peer.publicKey,
            endpointHost: peer.endpointHost,
            endpointPort: peer.endpointPort,
            addressCIDR: peer.addressCIDR,
            cpuCount: 0,
            memoryGB: 0,
            freeDiskGB: 0,
            lastSeen: Date()
        )

        let req = RPCRequest(
            id: UUID().uuidString,
            type: "bandwidthTest",
            payload: Self.bandwidthBlob100MB,
            metadata: [
                "senderID": WireGuardManager.shared.hostInfo.id,
                "senderName": senderName,
                "startedAt": String(Date().timeIntervalSince1970)
            ]
        )
        let resp = try await send(req, to: node)
        guard resp.ok, let data = resp.payload else {
            throw NSError(domain: "ClusterRPC", code: 6, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage ?? "Bandwidth test failed"])
        }
        return try JSONDecoder().decode(BandwidthTestResult.self, from: data)
    }
    
    private func startListener() {
        if listener != nil { return }
        let params = NWParameters.tcp
        do {
            let listener = try NWListener(using: params, on: rpcPort)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: .global(qos: .utility))
                self.receiveAll(connection: connection, maximumBytes: self.maxRPCPayloadBytes) { data in
                    Task { @MainActor in
                        guard let data,
                              let env = try? JSONDecoder().decode(Envelope.self, from: data),
                              let sealed = try? ChaChaPoly.SealedBox(combined: env.sealedBoxCombined),
                              let key = WireGuardManager.shared.deriveClusterSymmetricKey(peerPublicKeyBase64: env.senderPublicKey),
                              let decrypted = try? ChaChaPoly.open(sealed, using: key),
                              let req = try? self.decodeRPCRequest(from: decrypted) else {
                            connection.cancel()
                            return
                        }
                        
                        let response = await self.handle(req)
                        let encoded = (try? self.encodeRPCResponse(response)) ?? Data()
                        guard let replyKey = WireGuardManager.shared.deriveClusterSymmetricKey(peerPublicKeyBase64: env.senderPublicKey),
                              let sealedReply = try? ChaChaPoly.seal(encoded, using: replyKey).combined else {
                            connection.cancel()
                            return
                        }
                        let replyEnv = Envelope(
                            senderID: WireGuardManager.shared.hostInfo.id,
                            senderPublicKey: WireGuardManager.shared.hostInfo.publicKey,
                            sealedBoxCombined: sealedReply
                        )
                        let out = (try? JSONEncoder().encode(replyEnv)) ?? Data()
                        connection.send(content: out, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                }
            }
            listener.stateUpdateHandler = { _ in }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            self.listener = nil
        }
    }
    
    @MainActor
    private func handle(_ req: RPCRequest) async -> RPCResponse {
        do {
            switch req.type {
            case "listVMs":
                let vms = VMManager.shared.virtualMachines.map { vm in
                    VMInfo(
                        id: vm.id,
                        name: vm.name,
                        state: "\(vm.state)",
                        cpuCount: vm.cpuCount,
                        memoryGB: vm.memorySizeGB
                    )
                }
                let payload = try JSONEncoder().encode(vms)
                return RPCResponse(id: req.id, ok: true, payload: payload, errorMessage: nil)
            case "createVM":
                guard let p = req.payload else { throw NSError(domain: "ClusterRPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing payload"]) }
                let spec = try JSONDecoder().decode(VMRequestSpec.self, from: p)
                let distro = VirtualMachine.LinuxDistro(rawValue: spec.distroRawValue) ?? .debian13
                let vm = try await VMManager.shared.createLinuxVM(
                    name: spec.name,
                    cpus: spec.cpus,
                    ramGB: spec.ramGB,
                    sysDiskGB: spec.sysDiskGB,
                    dataDiskGB: spec.dataDiskGB,
                    isMaster: spec.isMaster,
                    distro: distro
                )
                let payload = try JSONEncoder().encode(vm.id)
                return RPCResponse(id: req.id, ok: true, payload: payload, errorMessage: nil)
            case "bandwidthTest":
                guard let bytes = req.payload else {
                    throw NSError(domain: "ClusterRPC", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing test payload"])
                }
                let senderID = req.metadata?["senderID"] ?? "unknown"
                let senderName = req.metadata?["senderName"] ?? "Unknown Sender"
                let startedAt = Double(req.metadata?["startedAt"] ?? "") ?? Date().timeIntervalSince1970
                let elapsed = max(Date().timeIntervalSince1970 - startedAt, 0.001)
                let mbps = (Double(bytes.count) / (1024 * 1024)) / elapsed
                AppNotifications.shared.notify(
                    id: "cluster-bandwidth-\(senderID)",
                    title: "Cluster Test Received",
                    body: "\(senderName) -> \(WireGuardManager.shared.hostInfo.name): \(Int(mbps)) MB/s",
                    minimumInterval: 1
                )
                let result = BandwidthTestResult(
                    receiverID: WireGuardManager.shared.hostInfo.id,
                    receiverName: WireGuardManager.shared.hostInfo.name,
                    mbps: mbps
                )
                return RPCResponse(id: req.id, ok: true, payload: try JSONEncoder().encode(result), errorMessage: nil)
            default:
                return RPCResponse(id: req.id, ok: false, payload: nil, errorMessage: "Unknown request type: \(req.type)")
            }
        } catch {
            return RPCResponse(id: req.id, ok: false, payload: nil, errorMessage: (error as NSError).localizedDescription)
        }
    }
    
    private func send(_ request: RPCRequest, to node: Node) async throws -> RPCResponse {
        let encoded = try encodeRPCRequest(request)
        guard let key = WireGuardManager.shared.deriveClusterSymmetricKey(peerPublicKeyBase64: node.publicKey) else {
            throw NSError(domain: "ClusterRPC", code: 4, userInfo: [NSLocalizedDescriptionKey: "Encryption failed"])
        }
        let sealed = try ChaChaPoly.seal(encoded, using: key).combined
        let env = Envelope(
            senderID: WireGuardManager.shared.hostInfo.id,
            senderPublicKey: WireGuardManager.shared.hostInfo.publicKey,
            sealedBoxCombined: sealed
        )
        let out = try JSONEncoder().encode(env)
        
        return try await withCheckedThrowingContinuation { continuation in
            let params = NWParameters.tcp
            let endpoint = NWEndpoint.hostPort(host: .init(node.endpointHost), port: self.rpcPort)
            let connection = NWConnection(to: endpoint, using: params)
            connection.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    continuation.resume(throwing: err)
                    connection.cancel()
                }
            }
            connection.start(queue: .global(qos: .utility))
            connection.send(content: out, completion: .contentProcessed { _ in
                self.receiveAll(connection: connection, maximumBytes: self.rpcReplyMaxBytes) { data in
                    Task { @MainActor in
                        guard let data,
                              let replyEnv = try? JSONDecoder().decode(Envelope.self, from: data),
                              let sealed = try? ChaChaPoly.SealedBox(combined: replyEnv.sealedBoxCombined),
                              let replyKey = WireGuardManager.shared.deriveClusterSymmetricKey(peerPublicKeyBase64: node.publicKey),
                              let decrypted = try? ChaChaPoly.open(sealed, using: replyKey),
                              let resp = try? self.decodeRPCResponse(from: decrypted) else {
                            continuation.resume(throwing: NSError(domain: "ClusterRPC", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
                            connection.cancel()
                            return
                        }
                        continuation.resume(returning: resp)
                        connection.cancel()
                    }
                }
            })
        }
    }

    private func receiveAll(connection: NWConnection, maximumBytes: Int, completion: @escaping (Data?) -> Void) {
        var buffer = Data()

        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data {
                    buffer.append(data)
                    if buffer.count > maximumBytes {
                        completion(nil)
                        return
                    }
                }
                if error != nil {
                    completion(nil)
                    return
                }
                if isComplete {
                    completion(buffer.isEmpty ? nil : buffer)
                    return
                }
                pump()
            }
        }

        pump()
    }

    private func encodeRPCRequest(_ value: RPCRequest) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private func decodeRPCRequest(from data: Data) throws -> RPCRequest {
        try PropertyListDecoder().decode(RPCRequest.self, from: data)
    }

    private func encodeRPCResponse(_ value: RPCResponse) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private func decodeRPCResponse(from data: Data) throws -> RPCResponse {
        try PropertyListDecoder().decode(RPCResponse.self, from: data)
    }
}
