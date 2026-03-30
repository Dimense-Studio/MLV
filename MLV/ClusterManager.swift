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
    }
    
    struct RPCResponse: Codable {
        let id: String
        let ok: Bool
        let payload: Data?
        let errorMessage: String?
    }
    
    struct Envelope: Codable {
        let senderID: String
        let senderPublicKey: String
        let sealedBoxCombinedBase64: String
    }
    
    private let rpcPort: NWEndpoint.Port = 7124
    private var listener: NWListener?
    
    var nodes: [Node] = []
    
    private init() {}
    
    func start() {
        startListener()
        WireGuardManager.shared.startDiscovery()
        DiscoveryManager.shared.onUpdate = { [weak self] hosts in
            guard let self else { return }
            for host in hosts {
                WireGuardManager.shared.pair(discovered: host)
                self.refreshNodeInfo(for: host)
            }
        }
    }
    
    private func refreshNodeInfo(for host: DiscoveryManager.DiscoveredHost) {
        DiscoveryManager.shared.requestPeerInfo(host) { info in
            guard let info else { return }
            DispatchQueue.main.async {
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
    
    private func startListener() {
        if listener != nil { return }
        let params = NWParameters.tcp
        do {
            let listener = try NWListener(using: params, on: rpcPort)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: .global(qos: .utility))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { data, _, _, _ in
                    Task { @MainActor in
                        guard let data,
                              let env = try? JSONDecoder().decode(Envelope.self, from: data),
                              let combined = Data(base64Encoded: env.sealedBoxCombinedBase64),
                              let sealed = try? ChaChaPoly.SealedBox(combined: combined),
                              let key = WireGuardManager.shared.deriveClusterSymmetricKey(peerPublicKeyBase64: env.senderPublicKey),
                              let decrypted = try? ChaChaPoly.open(sealed, using: key),
                              let req = try? JSONDecoder().decode(RPCRequest.self, from: decrypted) else {
                            connection.cancel()
                            return
                        }
                        
                        let response = await self.handle(req)
                        let encoded = (try? JSONEncoder().encode(response)) ?? Data()
                        guard let replyKey = WireGuardManager.shared.deriveClusterSymmetricKey(peerPublicKeyBase64: env.senderPublicKey),
                              let sealedReply = try? ChaChaPoly.seal(encoded, using: replyKey).combined else {
                            connection.cancel()
                            return
                        }
                        let replyEnv = Envelope(
                            senderID: WireGuardManager.shared.hostInfo.id,
                            senderPublicKey: WireGuardManager.shared.hostInfo.publicKey,
                            sealedBoxCombinedBase64: sealedReply.base64EncodedString()
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
            default:
                return RPCResponse(id: req.id, ok: false, payload: nil, errorMessage: "Unknown request type: \(req.type)")
            }
        } catch {
            return RPCResponse(id: req.id, ok: false, payload: nil, errorMessage: (error as NSError).localizedDescription)
        }
    }
    
    private func send(_ request: RPCRequest, to node: Node) async throws -> RPCResponse {
        let encoded = try JSONEncoder().encode(request)
        guard let key = WireGuardManager.shared.deriveClusterSymmetricKey(peerPublicKeyBase64: node.publicKey) else {
            throw NSError(domain: "ClusterRPC", code: 4, userInfo: [NSLocalizedDescriptionKey: "Encryption failed"])
        }
        let sealed = try ChaChaPoly.seal(encoded, using: key).combined
        let env = Envelope(
            senderID: WireGuardManager.shared.hostInfo.id,
            senderPublicKey: WireGuardManager.shared.hostInfo.publicKey,
            sealedBoxCombinedBase64: sealed.base64EncodedString()
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
                connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { data, _, _, _ in
                    Task { @MainActor in
                        guard let data,
                              let replyEnv = try? JSONDecoder().decode(Envelope.self, from: data),
                              let combined = Data(base64Encoded: replyEnv.sealedBoxCombinedBase64),
                              let sealed = try? ChaChaPoly.SealedBox(combined: combined),
                              let replyKey = WireGuardManager.shared.deriveClusterSymmetricKey(peerPublicKeyBase64: node.publicKey),
                              let decrypted = try? ChaChaPoly.open(sealed, using: replyKey),
                              let resp = try? JSONDecoder().decode(RPCResponse.self, from: decrypted) else {
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
}
