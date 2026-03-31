import Foundation
import Network
import SwiftUI
import CryptoKit

@Observable
final class DiscoveryManager {
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
    
    struct DiscoveryRequest: Codable {
        let nonceBase64: String
        let tokenHashBase64: String
        let requesterHostInfo: WireGuardManager.HostInfo
        let requesterSignatureBase64: String
    }
    
    struct DiscoveryResponse: Codable {
        let hostInfo: WireGuardManager.HostInfo
        let nonceBase64: String
        let signatureBase64: String
    }

    static let shared = DiscoveryManager()

    private let serviceType = "_mlv._tcp"
    private let port: NWEndpoint.Port = 7123

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var myID: String?
    private var isRunning = false
    private var clusterToken: String = ""
    
    var onUpdate: (([DiscoveredHost]) -> Void)?

    var discovered: [DiscoveredHost] = []
    var pairStatusByID: [String: String] = [:]

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
    }

    private func startListener(myInfo: WireGuardManager.HostInfo) {
        if listener != nil { return }
        let params = NWParameters.tcp
        do {
            let listener = try NWListener(using: params, on: port)
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
                        
                        WireGuardManager.shared.addOrUpdatePeer(from: req.requesterHostInfo)
                        
                        let infoData = myInfo.jsonData()
                        var payload = Data()
                        payload.append(nonce)
                        payload.append(infoData)
                        let sig = HMAC<SHA256>.authenticationCode(for: payload, using: tokenKey)
                        
                        let resp = DiscoveryResponse(
                            hostInfo: myInfo,
                            nonceBase64: req.nonceBase64,
                            signatureBase64: Data(sig).base64EncodedString()
                        )
                        
                        self.sendJSONLine(connection: connection, value: resp) {
                            connection.cancel()
                        }
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

    private func startBrowser() {
        if browser != nil { return }
        let params = NWParameters.tcp
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

        browser.stateUpdateHandler = { _ in }
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
        let params = NWParameters.tcp
        let connection = NWConnection(to: host.endpoint, using: params)
        DispatchQueue.main.async {
            self.pairStatusByID[host.id] = "Connecting…"
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.pairStatusByID[host.id] = "Connected"
                }
            case .failed(let err):
                DispatchQueue.main.async {
                    self.pairStatusByID[host.id] = "Failed: \(err)"
                }
                completion(nil)
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))

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
        
        self.sendJSONLine(connection: connection, value: req) {
            self.receiveJSONLine(connection: connection, maximumBytes: 64 * 1024) { (resp: DiscoveryResponse) in
                Task { @MainActor in
                    guard resp.nonceBase64 == req.nonceBase64,
                          let infoData = try? JSONEncoder().encode(resp.hostInfo),
                          let respNonce = Data(base64Encoded: resp.nonceBase64),
                          let sigData = Data(base64Encoded: resp.signatureBase64) else {
                        self.pairStatusByID[host.id] = "Failed: invalid response"
                        completion(nil)
                        connection.cancel()
                        return
                    }
                    
                    var payload = Data()
                    payload.append(respNonce)
                    payload.append(infoData)
                    let key = SymmetricKey(data: Data(self.clusterToken.utf8))
                    let expected = HMAC<SHA256>.authenticationCode(for: payload, using: key)
                    guard Data(expected) == sigData else {
                        self.pairStatusByID[host.id] = "Failed: auth"
                        completion(nil)
                        connection.cancel()
                        return
                    }
                    
                    self.pairStatusByID[host.id] = "Paired"
                    completion(resp.hostInfo)
                    connection.cancel()
                }
            }
        }
    }
    
    func removeDiscovered(id: String) {
        discovered.removeAll { $0.id == id }
        pairStatusByID[id] = nil
        onUpdate?(discovered)
    }

    private func sendJSONLine<T: Encodable>(connection: NWConnection, value: T, completion: @escaping () -> Void) {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        var line = Data()
        line.append(data)
        line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { _ in completion() })
    }
    
    private func receiveJSONLine<T: Decodable>(connection: NWConnection, maximumBytes: Int, completion: @escaping (T) -> Void) {
        var buffer = Data()
        var done = false
        
        func pump() {
            if done { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if done { return }
                if error != nil {
                    done = true
                    connection.cancel()
                    return
                }
                if let data { buffer.append(data) }
                if isComplete, data == nil {
                    done = true
                    connection.cancel()
                    return
                }
                if buffer.count > maximumBytes {
                    done = true
                    connection.cancel()
                    return
                }
                if let idx = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: idx)
                    if let decoded = try? JSONDecoder().decode(T.self, from: line) {
                        done = true
                        completion(decoded)
                    } else {
                        done = true
                        connection.cancel()
                    }
                    return
                }
                pump()
            }
        }
        
        pump()
    }
}
