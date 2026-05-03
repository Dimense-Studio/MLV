import Foundation
import Network
import SwiftUI
import CryptoKit

private nonisolated struct DiscoveryRequest: Codable {
    let nonceBase64: String
    let requesterHostInfo: WireGuardManager.HostInfo
}

private nonisolated struct DiscoveryResponse: Codable {
    let status: String
    let hostInfo: WireGuardManager.HostInfo?
    let nonceBase64: String
    let signatureBase64: String?
    let message: String?
}

@Observable
final class DiscoveryManager {
    struct IncomingPairRequest: Identifiable, Hashable {
        let id: String
        let name: String
        let addressCIDR: String
        let endpointHost: String
        let endpointPort: Int
        let requestedAt: Date
        var interfaceType: HostResources.NetworkInterface.InterfaceType?
    }

    struct DiscoveredHost: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        let publicKey: String
        let endpointHost: String
        let endpointPort: Int
        let addressCIDR: String
        let lastSeen: Date
        var interfaceType: HostResources.NetworkInterface.InterfaceType?
        var isPaired: Bool = false
        var cpuCount: Int = 0
        var memoryGB: Int = 0
        var freeDiskGB: Int = 0
    }
    
    static let shared = DiscoveryManager()

    private let serviceType = "_mlv._tcp"

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var myID: String?
    private var isRunning = false
    private var inFlightPeerInfoRequests: Set<String> = []
    private var lastPeerInfoRequestAt: [String: Date] = [:]
    private let peerInfoRequestCooldown: TimeInterval = 2.0
    private var pendingRequesterInfoByID: [String: WireGuardManager.HostInfo] = [:]
    private var approvedRequesterIDs: Set<String> = []
    
    var onUpdate: (([DiscoveredHost]) -> Void)?
    var discovered: [DiscoveredHost] = []
    var pairStatusByID: [String: String] = [:]
    var incomingPairRequests: [IncomingPairRequest] = []
    
    // Auto-pairing state
    var autoPairingEnabled: Bool = true
    private var autoPairTask: Task<Void, Never>?
    
    private init() {}

    func start(myInfo: WireGuardManager.HostInfo) {
        if isRunning {
            myID = myInfo.id
            return
        }
        isRunning = true
        myID = myInfo.id
        startListener(myInfo: myInfo)
        startBrowser()
        
        // Start auto-pairing task
        if autoPairingEnabled {
            startAutoPairing()
        }
    }

    func stop() {
        isRunning = false
        autoPairTask?.cancel()
        autoPairTask = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        discovered = []
        incomingPairRequests = []
        pendingRequesterInfoByID = [:]
    }

    /// Enable or disable auto-pairing
    func setAutoPairing(enabled: Bool) {
        autoPairingEnabled = enabled
        if enabled && isRunning && autoPairTask == nil {
            startAutoPairing()
        } else if !enabled {
            autoPairTask?.cancel()
            autoPairTask = nil
        }
    }

    private func startAutoPairing() {
        autoPairTask?.cancel()
        autoPairTask = Task { [weak self] in
            guard let self else { return }
            // Wait a bit for initial discovery
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            
            while !Task.isCancelled && self.isRunning {
                await self.attemptAutoPairing()
                // Check every 10 seconds
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// Attempt to auto-pair with discovered hosts using priority: Thunderbolt > Ethernet > WiFi
    /// Also re-pairs existing peers if a better interface becomes available.
    private func attemptAutoPairing() async {
        guard !discovered.isEmpty else { return }
        
        // Check all discovered hosts - both unpaired and already-paired
        for host in discovered {
            guard !Task.isCancelled else { break }
            
            let existingPeer = WireGuardManager.shared.peers.first(where: { $0.id == host.id })
            let isPaired = existingPeer != nil
            
            // Skip if paired and interface type hasn't improved
            if isPaired, let peer = existingPeer {
                let currentPriority = interfacePriority(host.interfaceType)
                let peerIP = peer.endpointHost
                let peerInterfaceType = interfaceTypeForIP(peerIP)
                let peerPriority = interfacePriority(peerInterfaceType)
                
                // If current connection is already better or equal, skip
                if peerPriority <= currentPriority {
                    continue
                }
                
                // Better interface found - re-pair
                await MainActor.run {
                    self.pairStatusByID[host.id] = "Upgrading connection..."
                }
            }
            
            guard let discoveredHost = discovered.first(where: { $0.id == host.id }) else { continue }
            
            // Skip if already paired via this exact endpoint
            if isPaired, let peer = existingPeer,
               peer.endpointHost == discoveredHost.endpointHost,
               peer.endpointPort == discoveredHost.endpointPort {
                continue
            }
            
            await MainActor.run {
                self.pairStatusByID[host.id] = isPaired ? "Switching to better interface..." : "Auto-pairing..."
            }
            
            await withCheckedContinuation { continuation in
                WireGuardManager.shared.pair(discovered: discoveredHost) { success, _ in
                    if success {
                        Task { @MainActor in
                            let interfaceName = String(describing: host.interfaceType ?? .unknown)
                            self.pairStatusByID[host.id] = isPaired ? "Upgraded to \(interfaceName)" : "Paired (auto)"
                            AppNotifications.shared.notify(
                                id: "auto-pair-\(host.id)",
                                title: isPaired ? "Connection Upgraded" : "Device Auto-Paired",
                                body: "\(host.name) is now connected via \(interfaceName)"
                            )
                        }
                    }
                    continuation.resume()
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

    private func startListener(myInfo: WireGuardManager.HostInfo) {
        if listener != nil { return }
        let params = discoveryParameters()
        do {
            // Use an available port picked by the OS and publish it via Bonjour.
            // This avoids hard failures when a fixed port is unavailable.
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(
                name: myInfo.id,
                type: serviceType,
                domain: nil
            )

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .utility))
                connection.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    self.receiveJSONLine(connection: connection, maximumBytes: 64 * 1024) { (req: DiscoveryRequest) in
                        Task { @MainActor in
                            guard Data(base64Encoded: req.nonceBase64) != nil else {
                                connection.cancel()
                                return
                            }
                            
                            let requester = req.requesterHostInfo
                            self.pendingRequesterInfoByID[requester.id] = requester
                            if let existing = self.incomingPairRequests.firstIndex(where: { $0.id == requester.id }) {
                                self.incomingPairRequests[existing] = IncomingPairRequest(
                                    id: requester.id,
                                    name: requester.name,
                                    addressCIDR: requester.addressCIDR,
                                    endpointHost: requester.endpointHost,
                                    endpointPort: requester.endpointPort,
                                    requestedAt: Date()
                                )
                            } else {
                                self.incomingPairRequests.append(
                                    IncomingPairRequest(
                                        id: requester.id,
                                        name: requester.name,
                                        addressCIDR: requester.addressCIDR,
                                        endpointHost: requester.endpointHost,
                                        endpointPort: requester.endpointPort,
                                        requestedAt: Date()
                                    )
                                )
                            }

                            if self.approvedRequesterIDs.contains(requester.id) {
                                WireGuardManager.shared.addOrUpdatePeer(from: requester)

                                let resp = DiscoveryResponse(
                                    status: "approved",
                                    hostInfo: myInfo,
                                    nonceBase64: req.nonceBase64,
                                    signatureBase64: nil,
                                    message: nil
                                )
                                self.sendJSONLine(connection: connection, value: resp) {
                                    connection.cancel()
                                }
                            } else {
                                self.pairStatusByID[requester.id] = "Awaiting your approval"
                                let resp = DiscoveryResponse(
                                    status: "pending",
                                    hostInfo: nil,
                                    nonceBase64: req.nonceBase64,
                                    signatureBase64: nil,
                                    message: "Waiting for approval on \(myInfo.name)"
                                )
                                self.sendJSONLine(connection: connection, value: resp) {
                                    connection.cancel()
                                }
                            }
                        }
                    }
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed = state {
                    self.listener?.cancel()
                    self.listener = nil
                    guard self.isRunning, let id = self.myID else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        guard self.isRunning else { return }
                        self.startListener(myInfo: WireGuardManager.shared.hostInfo)
                        self.myID = id
                    }
                }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            self.listener = nil
        }
    }

    private func startBrowser() {
        if browser != nil { return }
        let params = discoveryParameters()
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)

        browser.browseResultsChangedHandler = { results, _ in
            var next: [DiscoveredHost] = []
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                let id = name
                if let myID = self.myID, id == myID { continue }

                // Try to resolve the endpoint to get IP and interface info
                let resolvedHost = self.resolveEndpoint(result.endpoint)
                
                // Determine interface type from the resolved IP
                let ifaceType = resolvedHost.ip.flatMap { self.interfaceTypeForIP($0) }

                next.append(
                    DiscoveredHost(
                        id: id,
                        name: name,
                        endpoint: result.endpoint,
                        publicKey: "",
                        endpointHost: resolvedHost.ip ?? "",
                        endpointPort: resolvedHost.port ?? 0,
                        addressCIDR: resolvedHost.ip.map { $0 + "/32" } ?? "",
                        lastSeen: Date(),
                        interfaceType: ifaceType,
                        isPaired: WireGuardManager.shared.peers.contains { $0.id == id }
                    )
                )
            }
            DispatchQueue.main.async {
                self.mergeDiscovered(next)
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.browser?.cancel()
                self.browser = nil
                guard self.isRunning else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard self.isRunning else { return }
                    self.startBrowser()
                }
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint) -> (ip: String?, port: Int?) {
        // Try to extract IP from the endpoint
        switch endpoint {
        case .hostPort(let host, let port):
            let ip = Self.hostString(from: host)
            return (ip, Int(port.rawValue))
        case .service:
            return (nil, nil)
        case .unix(let path):
            return (path, nil)
        @unknown default:
            return (nil, nil)
        }
    }

    private func resolveBestEndpoint(for host: DiscoveredHost) -> NWEndpoint {
        if !host.endpointHost.isEmpty, host.endpointPort > 0,
           let port = NWEndpoint.Port(rawValue: UInt16(host.endpointPort)) {
            return .hostPort(host: .init(host.endpointHost), port: port)
        }
        return host.endpoint
    }

    private func interfaceTypeForIP(_ ip: String) -> HostResources.NetworkInterface.InterfaceType? {
        // Determine interface type based on IP address ranges
        let parts = ip.split(separator: ".")
        guard parts.count == 4, let _ = Int(parts[0]) else { return nil }
        
        // Thunderbolt bridges typically use 192.168.100.x or similar private ranges
        // WiFi and Ethernet can be various ranges
        // This is a heuristic - proper detection would use routing tables
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") {
            return HostResources.bestAvailableInterface()?.type
        }
        return nil
    }
    
    // MARK: - Notification Names
    
    static let peerEndpointUpdated = Notification.Name("DiscoveryManager.peerEndpointUpdated")

    private func mergeDiscovered(_ next: [DiscoveredHost]) {
        let existingByID: [String: DiscoveredHost] = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        var merged: [DiscoveredHost] = []
        for host in next {
            if let existing = existingByID[host.id] {
                // Preserve existing peer info and CPU/memory data but update timestamp and endpoint
                merged.append(
                    DiscoveredHost(
                        id: existing.id,
                        name: host.name,
                        endpoint: host.endpoint,
                        publicKey: existing.publicKey.isEmpty ? host.publicKey : existing.publicKey,
                        endpointHost: host.endpointHost.isEmpty ? existing.endpointHost : host.endpointHost,
                        endpointPort: host.endpointPort == 0 ? existing.endpointPort : host.endpointPort,
                        addressCIDR: host.addressCIDR.isEmpty ? existing.addressCIDR : host.addressCIDR,
                        lastSeen: Date(),
                        interfaceType: host.interfaceType ?? existing.interfaceType,
                        isPaired: existing.isPaired || WireGuardManager.shared.peers.contains { $0.id == host.id },
                        cpuCount: existing.cpuCount,
                        memoryGB: existing.memoryGB,
                        freeDiskGB: existing.freeDiskGB
                    )
                )
            } else {
                merged.append(host)
            }
        }
        discovered = merged.sorted { a, b in
            // Sort by interface priority first, then by name
            let priorityA = interfacePriority(a.interfaceType)
            let priorityB = interfacePriority(b.interfaceType)
            if priorityA != priorityB { return priorityA < priorityB }
            return a.name < b.name
        }
        reconcilePairedPeerEndpoints(with: discovered)
        onUpdate?(discovered)
    }

    private func reconcilePairedPeerEndpoints(with discoveredHosts: [DiscoveredHost]) {
        let peerByID = Dictionary(uniqueKeysWithValues: WireGuardManager.shared.peers.map { ($0.id, $0) })
        for host in discoveredHosts {
            guard let peer = peerByID[host.id] else { continue }
            let discoveredIP = host.addressCIDR.split(separator: "/").first.map(String.init) ?? ""
            if host.endpointHost.isEmpty || discoveredIP.isEmpty {
                continue
            }
            let endpointChanged = peer.endpointHost != host.endpointHost || peer.endpointPort != host.endpointPort
            let addressChanged = peer.addressCIDR != host.addressCIDR
            let interfaceChanged = peer.interfaceType != host.interfaceType
            if !endpointChanged && !addressChanged && !interfaceChanged {
                continue
            }
            let refreshed = WireGuardManager.HostInfo(
                id: peer.id,
                name: host.name,
                publicKey: peer.publicKey,
                endpointHost: host.endpointHost,
                endpointPort: host.endpointPort > 0 ? host.endpointPort : peer.endpointPort,
                addressCIDR: host.addressCIDR,
                advertisedRoutes: peer.allowedIPs,
                cpuCount: host.cpuCount,
                memoryGB: host.memoryGB,
                freeDiskGB: host.freeDiskGB,
                primaryInterfaceType: host.interfaceType
            )
            WireGuardManager.shared.addOrUpdatePeer(from: refreshed)
            
            // Notify ClusterManager to re-sync if endpoint or interface changed
            if endpointChanged || interfaceChanged {
                NotificationCenter.default.post(
                    name: Self.peerEndpointUpdated,
                    object: nil,
                    userInfo: ["peerID": host.id]
                )
            }
        }
    }

    func requestPeerInfo(_ host: DiscoveredHost, completion: @escaping (WireGuardManager.HostInfo?) -> Void) {
        let now = Date()
        if inFlightPeerInfoRequests.contains(host.id) {
            return
        }
        if let last = lastPeerInfoRequestAt[host.id], now.timeIntervalSince(last) < peerInfoRequestCooldown {
            return
        }
        inFlightPeerInfoRequests.insert(host.id)
        lastPeerInfoRequestAt[host.id] = now

        // Use priority-based endpoint resolution
        let targetEndpoint = resolveBestEndpoint(for: host)
        let params = peerInfoClientParameters()
        let connection = NWConnection(to: targetEndpoint, using: params)
        
        DispatchQueue.main.async {
            self.pairStatusByID[host.id] = "Connecting…"
        }
        let stateQueue = DispatchQueue(label: "DiscoveryManager.requestPeerInfo.\(host.id)")
        var didFinish = false
        var didCancelConnection = false

        let cancelConnectionIfNeeded: () -> Void = {
            let shouldCancel = stateQueue.sync { () -> Bool in
                if didCancelConnection { return false }
                didCancelConnection = true
                return true
            }
            if shouldCancel {
                connection.cancel()
            }
        }

        let finish: (WireGuardManager.HostInfo?) -> Void = { info in
            let shouldFinish = stateQueue.sync { () -> Bool in
                if didFinish { return false }
                didFinish = true
                return true
            }
            if !shouldFinish { return }
            DispatchQueue.main.async {
                self.inFlightPeerInfoRequests.remove(host.id)
                if info == nil {
                    let current = self.pairStatusByID[host.id] ?? ""
                    if !current.hasPrefix("Failed"),
                       current != "Paired",
                       !current.hasPrefix("Awaiting"),
                       !current.hasPrefix("Rejected") {
                        self.pairStatusByID[host.id] = "Failed: timeout"
                    }
                }
            }
            completion(info)
            cancelConnectionIfNeeded()
        }

        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let requesterInfo = WireGuardManager.shared.hostInfo
        
        let req = DiscoveryRequest(
            nonceBase64: nonce.base64EncodedString(),
            requesterHostInfo: requesterInfo
        )

        var didStartExchange = false
        let startExchange = {
            if didStartExchange { return }
            didStartExchange = true

            let data = (try? JSONEncoder().encode(req)) ?? Data()
            var line = Data()
            line.append(data)
            line.append(0x0A)
            connection.send(content: line, completion: .contentProcessed { error in
                if let error {
                    DispatchQueue.main.async {
                        self.pairStatusByID[host.id] = "Failed: \(error.localizedDescription)"
                    }
                    finish(nil)
                    return
                }

                self.receiveJSONLine(
                    connection: connection,
                    maximumBytes: 64 * 1024,
                    completion: { (resp: DiscoveryResponse) in
                        Task { @MainActor in
                            guard resp.nonceBase64 == req.nonceBase64 else {
                                self.pairStatusByID[host.id] = "Failed: invalid response"
                                finish(nil)
                                return
                            }

                            if resp.status == "pending" {
                                self.pairStatusByID[host.id] = resp.message ?? "Awaiting remote approval"
                                finish(nil)
                                return
                            }

                            if resp.status == "rejected" {
                                self.pairStatusByID[host.id] = resp.message ?? "Rejected by remote"
                                finish(nil)
                                return
                            }

                            guard resp.status == "approved",
                                  let remoteInfo = resp.hostInfo,
                                  Data(base64Encoded: resp.nonceBase64) != nil else {
                                self.pairStatusByID[host.id] = "Failed: invalid approval"
                                finish(nil)
                                return
                            }

                            let resolvedHost = Self.hostString(from: connection.currentPath?.remoteEndpoint)
                            let reachableInfo: WireGuardManager.HostInfo
                            if let resolvedHost, !resolvedHost.isEmpty {
                                reachableInfo = WireGuardManager.HostInfo(
                                    id: remoteInfo.id,
                                    name: remoteInfo.name,
                                    publicKey: remoteInfo.publicKey,
                                    endpointHost: resolvedHost,
                                    endpointPort: remoteInfo.endpointPort,
                                    addressCIDR: remoteInfo.addressCIDR,
                                    advertisedRoutes: remoteInfo.advertisedRoutes,
                                    cpuCount: remoteInfo.cpuCount,
                                    memoryGB: remoteInfo.memoryGB,
                                    freeDiskGB: remoteInfo.freeDiskGB,
                                    primaryInterfaceType: remoteInfo.primaryInterfaceType
                                )
                            } else {
                                reachableInfo = remoteInfo
                            }

                            // Update discovered host with remote info
                            if let idx = self.discovered.firstIndex(where: { $0.id == host.id }) {
                                let existing = self.discovered[idx]
                                self.discovered[idx] = DiscoveredHost(
                                    id: existing.id,
                                    name: reachableInfo.name,
                                    endpoint: existing.endpoint,
                                    publicKey: reachableInfo.publicKey,
                                    endpointHost: reachableInfo.endpointHost,
                                    endpointPort: reachableInfo.endpointPort,
                                    addressCIDR: reachableInfo.addressCIDR,
                                    lastSeen: Date(),
                                    interfaceType: existing.interfaceType,
                                    isPaired: true,
                                    cpuCount: reachableInfo.cpuCount,
                                    memoryGB: reachableInfo.memoryGB,
                                    freeDiskGB: reachableInfo.freeDiskGB
                                )
                                self.onUpdate?(self.discovered)
                            }

                            self.pairStatusByID[host.id] = "Paired"
                            finish(reachableInfo)
                        }
                    },
                    onFailure: {
                        DispatchQueue.main.async {
                            let current = self.pairStatusByID[host.id] ?? ""
                            if !current.hasPrefix("Failed"), current != "Paired" {
                                self.pairStatusByID[host.id] = "Failed: no response"
                            }
                        }
                        finish(nil)
                    },
                    cancelOnFailure: false
                )
            })
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.pairStatusByID[host.id] = "Connected"
                }
                startExchange()
            case .failed(let err):
                DispatchQueue.main.async {
                    self.pairStatusByID[host.id] = "Failed: \(err)"
                }
                finish(nil)
            case .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) {
            finish(nil)
        }
    }
    
    func removeDiscovered(id: String) {
        discovered.removeAll { $0.id == id }
        pairStatusByID[id] = nil
        onUpdate?(discovered)
    }

    func approveIncomingPairRequest(id: String) {
        guard let info = pendingRequesterInfoByID[id] else { return }
        approvedRequesterIDs.insert(id)
        incomingPairRequests.removeAll { $0.id == id }
        pairStatusByID[id] = "Approved"
        WireGuardManager.shared.addOrUpdatePeer(from: info)
        
        // Notify
        AppNotifications.shared.notify(
            id: "pair-approved-\(id)",
            title: "Pairing Approved",
            body: "\(info.name) can now share VMs with this device"
        )
    }

    func rejectIncomingPairRequest(id: String) {
        incomingPairRequests.removeAll { $0.id == id }
        pendingRequesterInfoByID[id] = nil
        pairStatusByID[id] = "Rejected"
    }

    /// Get the interface type for a discovered host by its ID
    func interfaceTypeForHost(id: String) -> HostResources.NetworkInterface.InterfaceType? {
        discovered.first(where: { $0.id == id })?.interfaceType
    }

    private func sendJSONLine<T: Encodable>(connection: NWConnection, value: T, completion: @escaping () -> Void) {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        var line = Data()
        line.append(data)
        line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { _ in completion() })
    }
    
    private func receiveJSONLine<T: Decodable>(
        connection: NWConnection,
        maximumBytes: Int,
        completion: @escaping (T) -> Void,
        onFailure: (() -> Void)? = nil,
        cancelOnFailure: Bool = true
    ) {
        var buffer = Data()
        var done = false
        
        func fail() {
            if done { return }
            done = true
            if cancelOnFailure {
                connection.cancel()
            }
            onFailure?()
        }
        
        func pump() {
            if done { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if done { return }
                if error != nil {
                    fail()
                    return
                }
                if let data { buffer.append(data) }
                if isComplete, data == nil {
                    fail()
                    return
                }
                if buffer.count > maximumBytes {
                    fail()
                    return
                }
                if let idx = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: idx)
                    if let decoded = try? JSONDecoder().decode(T.self, from: line) {
                        done = true
                        completion(decoded)
                    } else {
                        fail()
                    }
                    return
                }
                pump()
            }
        }
        
        pump()
    }

    private func discoveryParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        return params
    }

    private static func hostString(from endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        switch endpoint {
        case .hostPort(let host, _):
            let raw = host.debugDescription
            if raw.hasPrefix("[") && raw.hasSuffix("]") {
                return String(raw.dropFirst().dropLast())
            }
            return raw
        default:
            return nil
        }
    }

    private static func hostString(from host: NWEndpoint.Host) -> String {
        let raw = host.debugDescription
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// Client-side peer-info requests allow peer-to-peer transport so
    /// Bonjour-discovered peers on local/P2P paths can actually pair.
    private func peerInfoClientParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        return params
    }
}
