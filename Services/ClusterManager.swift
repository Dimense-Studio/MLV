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
        var interfaceType: HostResources.NetworkInterface.InterfaceType? = nil
        var isPaired: Bool = false
    }
    
    struct WorkerConfigPayload: Codable {
        let clusterName: String
        let controlPlaneIP: String
        let workerYAML: String
        let talosconfigYAML: String
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
    
    // Envelope removed - direct TCP RPC without encryption

    struct BandwidthTestResult: Codable {
        let receiverID: String
        let receiverName: String
        let mbps: Double
    }
    
    struct GlobalVMInfo: Codable, Hashable, Identifiable {
        let id: UUID
        let nodeID: String
        let name: String
        let publicKey: String
        let wgAddress: String?  // Now optional since we use direct IP
        let hostEndpoint: String
        let hostPort: Int
        let primaryAddress: String?
        let isMaster: Bool
        let networkInterface: String?
        let networkSubnetPrefix: String?
        var nodeName: String? = nil
        var interfaceType: HostResources.NetworkInterface.InterfaceType? = nil

        private enum CodingKeys: String, CodingKey {
            case id
            case nodeID
            case name
            case publicKey
            case wgAddress
            case hostEndpoint
            case hostPort
            case primaryAddress
            case isMaster
            case networkInterface
            case networkSubnetPrefix
            case nodeName
        }
    }
    
    static let peerEndpointUpdated = Notification.Name("ClusterManager.peerEndpointUpdated")
    
    static let autoPairUpgraded = Notification.Name("ClusterManager.autoPairUpgraded")
    
    private let rpcPort: NWEndpoint.Port = 7124
    private let maxRPCPayloadBytes = 160 * 1024 * 1024
    private let rpcReplyMaxBytes = 4 * 1024 * 1024
    private var listener: NWListener?
    private static let bandwidthBlob100MB = Data(repeating: 0xA5, count: 100 * 1024 * 1024)
    
    var nodes: [Node] = []
    var clusterVMs: [GlobalVMInfo] = []
    
    private init() {}
    
    @objc private func handlePeerEndpointUpdated() {
        Task { @MainActor in
            await self.syncClusterVMs()
        }
    }
    
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
        
        // Load existing paired peers into nodes list
        refreshNodesFromPeers()
        Task { @MainActor in
            await self.syncClusterVMs()
        }
        
        // Re-sync cluster when a peer's endpoint or interface upgrades
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePeerEndpointUpdated),
            name: Self.peerEndpointUpdated,
            object: nil
        )
        
        // Periodic cluster VM sync
        startPeriodicSync()
    }
    
    // Load existing paired peers into nodes list
    func refreshNodesFromPeers() {
        let peers = WireGuardManager.shared.peers
        self.nodes = peers.map { peer in
            Node(
                id: peer.id,
                name: peer.name,
                publicKey: peer.publicKey,
                endpointHost: peer.endpointHost,
                endpointPort: peer.endpointPort,
                addressCIDR: peer.addressCIDR,
                cpuCount: 0,
                memoryGB: 0,
                freeDiskGB: 0,
                lastSeen: Date(),
                interfaceType: peer.interfaceType,
                isPaired: true
            )
        }
    }
    
    // Periodic cluster VM sync
    private func startPeriodicSync() {
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task { @MainActor in
                await self.syncClusterVMs()
            }
        }
    }
    
    private func syncClusterVMs() async {
        var allVMs: [GlobalVMInfo] = []
        
        // Add local VMs
        let localNodeID = WireGuardManager.shared.hostInfo.id
        for vm in VMManager.shared.virtualMachines {
            allVMs.append(GlobalVMInfo(
                id: vm.id,
                nodeID: localNodeID,
                name: vm.name,
                publicKey: localNodeID,
                wgAddress: vm.ipAddress == "Detecting..." ? nil : vm.ipAddress,
                hostEndpoint: WireGuardManager.shared.hostInfo.endpointHost,
                hostPort: 0,
                primaryAddress: vm.ipAddress == "Detecting..." ? nil : vm.ipAddress,
                isMaster: vm.isMaster,
                networkInterface: vm.bridgeInterfaceName,
                networkSubnetPrefix: VMNetworkService.shared.subnetPrefix(forIPAddress: vm.ipAddress),
                nodeName: Host.current().localizedName ?? "This Mac",
                interfaceType: HostResources.bestAvailableInterface()?.type
            ))
        }
        
        // Build remote targets from paired peers plus discovered nodes.
        let discoveredByID = Dictionary(uniqueKeysWithValues: DiscoveryManager.shared.discovered.map { ($0.id, $0) })
        let peerNodes = WireGuardManager.shared.peers.map { peer in
            let discovered = discoveredByID[peer.id]
            return Node(
                id: peer.id,
                name: peer.name,
                publicKey: peer.publicKey,
                endpointHost: peer.endpointHost,
                endpointPort: peer.endpointPort,
                addressCIDR: peer.addressCIDR,
                cpuCount: 0,
                memoryGB: 0,
                freeDiskGB: 0,
                lastSeen: Date(),
                interfaceType: discovered?.interfaceType,
                isPaired: true
            )
        }
        var byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for peerNode in peerNodes {
            let discovered = discoveredByID[peerNode.id]
            let resolvedHost = discovered?.endpointHost.isEmpty == false ? (discovered?.endpointHost ?? peerNode.endpointHost) : peerNode.endpointHost
            let resolvedPort = (discovered?.endpointPort ?? 0) > 0 ? (discovered?.endpointPort ?? peerNode.endpointPort) : peerNode.endpointPort
            if let existing = byID[peerNode.id] {
                byID[peerNode.id] = Node(
                    id: existing.id,
                    name: existing.name,
                    publicKey: existing.publicKey,
                    endpointHost: resolvedHost,
                    endpointPort: resolvedPort,
                    addressCIDR: peerNode.addressCIDR,
                    cpuCount: existing.cpuCount,
                    memoryGB: existing.memoryGB,
                    freeDiskGB: existing.freeDiskGB,
                    lastSeen: existing.lastSeen,
                    interfaceType: discovered?.interfaceType ?? existing.interfaceType,
                    isPaired: true
                )
            } else {
                byID[peerNode.id] = Node(
                    id: peerNode.id,
                    name: peerNode.name,
                    publicKey: peerNode.publicKey,
                    endpointHost: resolvedHost,
                    endpointPort: resolvedPort,
                    addressCIDR: peerNode.addressCIDR,
                    cpuCount: peerNode.cpuCount,
                    memoryGB: peerNode.memoryGB,
                    freeDiskGB: peerNode.freeDiskGB,
                    lastSeen: peerNode.lastSeen,
                    interfaceType: discovered?.interfaceType ?? peerNode.interfaceType,
                    isPaired: true
                )
            }
        }
        self.nodes = Array(byID.values)

        // Add remote VMs with node info
        for node in self.nodes where node.isPaired {
            do {
                let vms = try await listVMsFull(on: node)
                allVMs.append(contentsOf: vms)
            } catch {
                print("[ClusterManager] Failed to fetch VMs from \(node.name): \(error)")
            }
        }
        self.clusterVMs = allVMs
    }

    func listVMsFull(on node: Node) async throws -> [GlobalVMInfo] {
        let req = RPCRequest(id: UUID().uuidString, type: "listVMsFull", payload: nil)
        let resp = try await send(req, to: node)
        guard resp.ok, let data = resp.payload else { return [] }
        let remoteVMs = try JSONDecoder().decode([GlobalVMInfo].self, from: data)
        // Tag with the node name for display
        return remoteVMs.map { vm in
            GlobalVMInfo(
                id: vm.id,
                nodeID: vm.nodeID,
                name: vm.name,
                publicKey: vm.publicKey,
                wgAddress: vm.wgAddress,
                hostEndpoint: vm.hostEndpoint,
                hostPort: vm.hostPort,
                primaryAddress: vm.primaryAddress,
                isMaster: vm.isMaster,
                networkInterface: vm.networkInterface,
                networkSubnetPrefix: vm.networkSubnetPrefix,
                nodeName: node.name,
                interfaceType: node.interfaceType
            )
        }
    }
    
    private func refreshNodeInfo(for host: DiscoveryManager.DiscoveredHost) {
        DiscoveryManager.shared.requestPeerInfo(host) { info in
            guard let info = info else { return }
            DispatchQueue.main.async {
                WireGuardManager.shared.addOrUpdatePeer(from: info)
                
                // Get the interface type from the discovered host
                let ifaceType = DiscoveryManager.shared.interfaceTypeForHost(id: host.id)
                
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
                    lastSeen: Date(),
                    interfaceType: ifaceType ?? info.primaryInterfaceType,
                    isPaired: true
                )
                var byId = Dictionary(uniqueKeysWithValues: self.nodes.map { ($0.id, $0) })
                byId[node.id] = node
                self.nodes = Array(byId.values).sorted { a, b in
                    // Sort by interface priority first, then by name
                    let priorityA = self.interfacePriority(a.interfaceType)
                    let priorityB = self.interfacePriority(b.interfaceType)
                    if priorityA != priorityB { return priorityA < priorityB }
                    return a.name < b.name
                }
            }
        }
    }

    private func interfacePriority(_ type: HostResources.NetworkInterface.InterfaceType?) -> Int {
        guard let type else { return 3 }
        switch type {
        case .thunderbolt: return 0
        case .ethernet: return 1
        case .wifi: return 2
        case .unknown: return 3
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

    // MARK: - Remote VM Lifecycle

    func startVMonNode(_ node: Node, vmID: UUID) async throws {
        let payload = try JSONEncoder().encode(vmID)
        let req = RPCRequest(id: UUID().uuidString, type: "startVM", payload: payload)
        let resp = try await send(req, to: node)
        if !resp.ok {
            throw NSError(domain: "ClusterRPC", code: 10, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage ?? "Failed to start VM on remote node"])
        }
    }

    func stopVMonNode(_ node: Node, vmID: UUID) async throws {
        let payload = try JSONEncoder().encode(vmID)
        let req = RPCRequest(id: UUID().uuidString, type: "stopVM", payload: payload)
        let resp = try await send(req, to: node)
        if !resp.ok {
            throw NSError(domain: "ClusterRPC", code: 11, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage ?? "Failed to stop VM on remote node"])
        }
    }

    func restartVMonNode(_ node: Node, vmID: UUID) async throws {
        let payload = try JSONEncoder().encode(vmID)
        let req = RPCRequest(id: UUID().uuidString, type: "restartVM", payload: payload)
        let resp = try await send(req, to: node)
        if !resp.ok {
            throw NSError(domain: "ClusterRPC", code: 12, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage ?? "Failed to restart VM on remote node"])
        }
    }

    func deleteVMonNode(_ node: Node, vmID: UUID) async throws {
        let payload = try JSONEncoder().encode(vmID)
        let req = RPCRequest(id: UUID().uuidString, type: "deleteVM", payload: payload)
        let resp = try await send(req, to: node)
        if !resp.ok {
            throw NSError(domain: "ClusterRPC", code: 13, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage ?? "Failed to delete VM on remote node"])
        }
    }

    func sendWorkerConfig(_ config: WorkerConfigPayload, to node: Node) async throws {
        let payload = try JSONEncoder().encode(config)
        let req = RPCRequest(id: UUID().uuidString, type: "provideWorkerConfig", payload: payload)
        let resp = try await send(req, to: node)
        if !resp.ok {
            throw NSError(domain: "ClusterRPC", code: 9, userInfo: [NSLocalizedDescriptionKey: resp.errorMessage ?? "Failed to send worker config"])
        }
    }

    func fetchWorkerConfig(from node: Node) async throws -> WorkerConfigPayload? {
        let req = RPCRequest(id: UUID().uuidString, type: "getWorkerConfig", payload: nil)
        let resp = try await send(req, to: node)
        guard resp.ok, let data = resp.payload else { return nil }
        return try JSONDecoder().decode(WorkerConfigPayload.self, from: data)
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
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.receiveAll(connection: connection, maximumBytes: self.maxRPCPayloadBytes) { data in
                            Task { @MainActor in
                                guard let data,
                                      let req = try? self.decodeRPCRequest(from: data) else {
                                    connection.cancel()
                                    return
                                }
                                
                                let response = await self.handle(req)
                                let out = (try? self.encodeRPCResponse(response)) ?? Data()
                                connection.send(content: out, completion: .contentProcessed { _ in
                                    connection.cancel()
                                })
                            }
                        }
                    case .failed, .cancelled:
                        connection.cancel()
                    default:
                        break
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
            case "listVMsFull":
                let vms = VMManager.shared.virtualMachines.map { vm -> GlobalVMInfo in
                    let localNodeID = WireGuardManager.shared.hostInfo.id
                    return GlobalVMInfo(
                        id: vm.id,
                        nodeID: localNodeID,
                        name: vm.name,
                        publicKey: localNodeID,
                        wgAddress: vm.ipAddress == "Detecting..." ? nil : vm.ipAddress,
                        hostEndpoint: WireGuardManager.shared.hostInfo.endpointHost,
                        hostPort: 0,
                        primaryAddress: vm.ipAddress == "Detecting..." ? nil : vm.ipAddress,
                        isMaster: vm.isMaster,
                        networkInterface: vm.bridgeInterfaceName,
                        networkSubnetPrefix: VMNetworkService.shared.subnetPrefix(forIPAddress: vm.ipAddress),
                        nodeName: Host.current().localizedName ?? "This Mac",
                        interfaceType: HostResources.bestAvailableInterface()?.type
                    )
                }
                let payload = try JSONEncoder().encode(vms)
                return RPCResponse(id: req.id, ok: true, payload: payload, errorMessage: nil)
            case "listVMs":
                let vms = VMManager.shared.virtualMachines.map { vm in
                    VMInfo(
                        id: vm.id,
                        name: vm.name,
                        state: "\(vm.state)",
                        cpuCount: vm.cpuCount,
                        memoryGB: vm.memorySizeMB / 1024
                    )
                }
                let payload = try JSONEncoder().encode(vms)
                return RPCResponse(id: req.id, ok: true, payload: payload, errorMessage: nil)
            case "createVM":
                guard let p = req.payload else { throw NSError(domain: "ClusterRPC", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing payload"]) }
                let spec = try JSONDecoder().decode(VMRequestSpec.self, from: p)
                let distro = VirtualMachine.LinuxDistro(rawValue: spec.distroRawValue) ?? .talos
                let vm = try await VMManager.shared.createLinuxVM(
                    name: spec.name,
                    cpus: spec.cpus,
                    ramMB: spec.ramGB * 1024,
                    sysDiskGB: spec.sysDiskGB,
                    dataDiskGB: spec.dataDiskGB,
                    isMaster: spec.isMaster,
                    distro: distro
                )
                let payload = try JSONEncoder().encode(vm.id)
                return RPCResponse(id: req.id, ok: true, payload: payload, errorMessage: nil)
            case "provideWorkerConfig":
                guard let p = req.payload else { throw NSError(domain: "ClusterRPC", code: 8, userInfo: [NSLocalizedDescriptionKey: "Missing payload"]) }
                let config = try JSONDecoder().decode(WorkerConfigPayload.self, from: p)
                await TalosAutoSetupService.shared.receiveWorkerConfig(config)
                return RPCResponse(id: req.id, ok: true, payload: nil, errorMessage: nil)

            case "getWorkerConfig":
                if let config = await TalosAutoSetupService.shared.availableWorkerConfig() {
                    let payload = try JSONEncoder().encode(config)
                    return RPCResponse(id: req.id, ok: true, payload: payload, errorMessage: nil)
                } else {
                    return RPCResponse(id: req.id, ok: false, payload: nil, errorMessage: "No worker config available yet")
                }

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

            // MARK: - Remote VM Lifecycle
            case "startVM":
                guard let p = req.payload, let vmID = try? JSONDecoder().decode(UUID.self, from: p) else {
                    throw NSError(domain: "ClusterRPC", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid VM ID"])
                }
                guard let vm = VMManager.shared.virtualMachines.first(where: { $0.id == vmID }) else {
                    throw NSError(domain: "ClusterRPC", code: 10, userInfo: [NSLocalizedDescriptionKey: "VM not found"])
                }
                try await VMManager.shared.startVM(vm)
                return RPCResponse(id: req.id, ok: true, payload: nil, errorMessage: nil)

            case "stopVM":
                guard let p = req.payload, let vmID = try? JSONDecoder().decode(UUID.self, from: p) else {
                    throw NSError(domain: "ClusterRPC", code: 11, userInfo: [NSLocalizedDescriptionKey: "Invalid VM ID"])
                }
                guard let vm = VMManager.shared.virtualMachines.first(where: { $0.id == vmID }) else {
                    throw NSError(domain: "ClusterRPC", code: 11, userInfo: [NSLocalizedDescriptionKey: "VM not found"])
                }
                try await VMManager.shared.stopVM(vm)
                return RPCResponse(id: req.id, ok: true, payload: nil, errorMessage: nil)

            case "restartVM":
                guard let p = req.payload, let vmID = try? JSONDecoder().decode(UUID.self, from: p) else {
                    throw NSError(domain: "ClusterRPC", code: 12, userInfo: [NSLocalizedDescriptionKey: "Invalid VM ID"])
                }
                guard let vm = VMManager.shared.virtualMachines.first(where: { $0.id == vmID }) else {
                    throw NSError(domain: "ClusterRPC", code: 12, userInfo: [NSLocalizedDescriptionKey: "VM not found"])
                }
                try await VMManager.shared.restartVM(vm)
                return RPCResponse(id: req.id, ok: true, payload: nil, errorMessage: nil)

            case "deleteVM":
                guard let p = req.payload, let vmID = try? JSONDecoder().decode(UUID.self, from: p) else {
                    throw NSError(domain: "ClusterRPC", code: 13, userInfo: [NSLocalizedDescriptionKey: "Invalid VM ID"])
                }
                guard let vm = VMManager.shared.virtualMachines.first(where: { $0.id == vmID }) else {
                    throw NSError(domain: "ClusterRPC", code: 13, userInfo: [NSLocalizedDescriptionKey: "VM not found"])
                }
                try await VMManager.shared.deleteVM(vm)
                return RPCResponse(id: req.id, ok: true, payload: nil, errorMessage: nil)

            default:
                return RPCResponse(id: req.id, ok: false, payload: nil, errorMessage: "Unknown request type: \(req.type)")
            }
        } catch {
            return RPCResponse(id: req.id, ok: false, payload: nil, errorMessage: (error as NSError).localizedDescription)
        }
    }
    
    private func send(_ request: RPCRequest, to node: Node) async throws -> RPCResponse {
        var candidates: [String] = []
        if !node.endpointHost.isEmpty {
            candidates.append(node.endpointHost)
        }
        if let cidrIP = ipFromCIDR(node.addressCIDR), !candidates.contains(cidrIP) {
            candidates.append(cidrIP)
        }
        if candidates.isEmpty {
            throw NSError(domain: "ClusterRPC", code: 7, userInfo: [NSLocalizedDescriptionKey: "No valid endpoint for node \(node.name)"])
        }
        var lastError: Error?
        for host in candidates {
            do {
                return try await sendOnce(request, host: host, port: node.endpointPort)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "ClusterRPC", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to reach node \(node.name)"])
    }

    private func sendOnce(_ request: RPCRequest, host: String, port: Int) async throws -> RPCResponse {
        let out = try encodeRPCRequest(request)
        
        return try await withCheckedThrowingContinuation { continuation in
            let params = NWParameters.tcp
            let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? self.rpcPort
            let endpoint = NWEndpoint.hostPort(host: .init(host), port: endpointPort)
            let connection = NWConnection(to: endpoint, using: params)
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: out, completion: .contentProcessed { _ in
                        self.receiveAll(connection: connection, maximumBytes: self.rpcReplyMaxBytes) { data in
                            Task { @MainActor in
                                guard let data,
                                      let resp = try? self.decodeRPCResponse(from: data) else {
                                    continuation.resume(throwing: NSError(domain: "ClusterRPC", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
                                    connection.cancel()
                                    return
                                }
                                continuation.resume(returning: resp)
                                connection.cancel()
                            }
                        }
                    })
                case .failed(let err):
                    continuation.resume(throwing: err)
                    connection.cancel()
                case .cancelled:
                    continuation.resume(throwing: NSError(domain: "ClusterRPC", code: 6, userInfo: [NSLocalizedDescriptionKey: "Connection cancelled"]))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    private func ipFromCIDR(_ cidr: String) -> String? {
        let ip = cidr.split(separator: "/").first.map(String.init) ?? ""
        return ip.isEmpty ? nil : ip
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
