import Foundation
import Network
import SwiftUI
import CryptoKit

private nonisolated struct DiscoveryRequest: Codable {
    let nonceBase64: String
    let tokenHashBase64: String
    let requesterHostInfo: WireGuardManager.HostInfo
    let requesterSignatureBase64: String
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
    }
    
    static let shared = DiscoveryManager()

    private let serviceType = "_mlv._tcp"

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var myID: String?
    private var isRunning = false
    private var clusterToken: String = ""
    private var inFlightPeerInfoRequests: Set<String> = []
    private var lastPeerInfoRequestAt: [String: Date] = [:]
    private let peerInfoRequestCooldown: TimeInterval = 2.0
    private var pendingRequesterInfoByID: [String: WireGuardManager.HostInfo] = [:]
    private var approvedRequesterIDs: Set<String> = []
    
    var onUpdate: (([DiscoveredHost]) -> Void)?

    var discovered: [DiscoveredHost] = []
    var pairStatusByID: [String: String] = [:]
    var incomingPairRequests: [IncomingPairRequest] = []

    private init() {}

    func start(myInfo: WireGuardManager.HostInfo, clusterToken: String) {
        if isRunning {
            myID = myInfo.id
            self.clusterToken = clusterToken
            return
        }
        isRunning = true
        myID = myInfo.id
        self.clusterToken = clusterToken
        startListener(myInfo: myInfo)
        startBrowser()
    }

    func stop() {
        isRunning = false
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        discovered = []
        incomingPairRequests = []
        pendingRequesterInfoByID = [:]
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
                self.receiveJSONLine(connection: connection, maximumBytes: 64 * 1024) { (req: DiscoveryRequest) in
                    Task { @MainActor in
                        guard let nonce = Data(base64Encoded: req.nonceBase64),
                              let tokenHash = Data(base64Encoded: req.tokenHashBase64),
                              let requesterSig = Data(base64Encoded: req.requesterSignatureBase64) else {
                            connection.cancel()
                            return
                        }
                        
                        let expectedHash = Data(SHA256.hash(data: Data(self.clusterToken.utf8)))
                        guard tokenHash == expectedHash else {
                            connection.cancel()
                            return
                        }
                        
                        let reqInfoData = req.requesterHostInfo.jsonData()
                        var reqPayload = Data()
                        reqPayload.append(nonce)
                        reqPayload.append(reqInfoData)
                        let tokenKey = SymmetricKey(data: Data(self.clusterToken.utf8))
                        let reqExpected = HMAC<SHA256>.authenticationCode(for: reqPayload, using: tokenKey)
                        guard Data(reqExpected) == requesterSig else {
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

                            let infoData = myInfo.jsonData()
                            var payload = Data()
                            payload.append(nonce)
                            payload.append(infoData)
                            let sig = HMAC<SHA256>.authenticationCode(for: payload, using: tokenKey)

                            let resp = DiscoveryResponse(
                                status: "approved",
                                hostInfo: myInfo,
                                nonceBase64: req.nonceBase64,
                                signatureBase64: Data(sig).base64EncodedString(),
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
                next.append(
                    DiscoveredHost(
                        id: id,
                        name: name,
                        endpoint: result.endpoint,
                        publicKey: "",
                        endpointHost: "",
                        endpointPort: 0,
                        addressCIDR: "",
                        lastSeen: Date()
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

    private func mergeDiscovered(_ next: [DiscoveredHost]) {
        let existingByID: [String: DiscoveredHost] = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        var merged: [DiscoveredHost] = []
        for host in next {
            if let existing = existingByID[host.id] {
                merged.append(
                    DiscoveredHost(
                        id: existing.id,
                        name: host.name,
                        endpoint: host.endpoint,
                        publicKey: existing.publicKey,
                        endpointHost: existing.endpointHost,
                        endpointPort: existing.endpointPort,
                        addressCIDR: existing.addressCIDR,
                        lastSeen: Date()
                    )
                )
            } else {
                merged.append(host)
            }
        }
        discovered = merged.sorted { $0.name < $1.name }
        onUpdate?(discovered)
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

        let params = peerInfoClientParameters()
        let connection = NWConnection(to: host.endpoint, using: params)
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
        let tokenHash = Data(SHA256.hash(data: Data(clusterToken.utf8)))
        
        let requesterInfo = WireGuardManager.shared.hostInfo
        let requesterInfoData = requesterInfo.jsonData()
        var reqPayload = Data()
        reqPayload.append(nonce)
        reqPayload.append(requesterInfoData)
        let tokenKey = SymmetricKey(data: Data(clusterToken.utf8))
        let requesterSig = HMAC<SHA256>.authenticationCode(for: reqPayload, using: tokenKey)
        
        let req = DiscoveryRequest(
            nonceBase64: nonce.base64EncodedString(),
            tokenHashBase64: tokenHash.base64EncodedString(),
            requesterHostInfo: requesterInfo,
            requesterSignatureBase64: Data(requesterSig).base64EncodedString()
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
                                  let infoData = try? JSONEncoder().encode(remoteInfo),
                                  let respNonce = Data(base64Encoded: resp.nonceBase64),
                                  let signatureBase64 = resp.signatureBase64,
                                  let sigData = Data(base64Encoded: signatureBase64) else {
                                self.pairStatusByID[host.id] = "Failed: invalid approval"
                                finish(nil)
                                return
                            }

                            var payload = Data()
                            payload.append(respNonce)
                            payload.append(infoData)
                            let key = SymmetricKey(data: Data(self.clusterToken.utf8))
                            let expected = HMAC<SHA256>.authenticationCode(for: payload, using: key)
                            guard Data(expected) == sigData else {
                                self.pairStatusByID[host.id] = "Failed: auth"
                                finish(nil)
                                return
                            }

                            self.pairStatusByID[host.id] = "Paired"
                            finish(remoteInfo)
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
    }

    func rejectIncomingPairRequest(id: String) {
        incomingPairRequests.removeAll { $0.id == id }
        pendingRequesterInfoByID[id] = nil
        pairStatusByID[id] = "Rejected"
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

    /// Client-side peer-info requests allow peer-to-peer transport so
    /// Bonjour-discovered peers on local/P2P paths can actually pair.
    private func peerInfoClientParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        return params
    }
}
