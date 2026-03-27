import Foundation
import Network
import SwiftUI

@Observable
final class DiscoveryManager {
    struct DiscoveredHost: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        let publicKey: String
        let endpointHost: String
        let endpointPort: Int
        let vmSubnet: String
        let lastSeen: Date
    }

    static let shared = DiscoveryManager()

    private let serviceType = "_mlv._tcp"
    private let port: NWEndpoint.Port = 7123

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var myID: String?
    private var isRunning = false

    var discovered: [DiscoveredHost] = []

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
                name: myInfo.name,
                type: serviceType,
                domain: nil
            )

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .utility))
                let reply = myInfo.jsonData()
                connection.send(content: reply, completion: .contentProcessed { _ in
                    connection.cancel()
                })
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
                        vmSubnet: "",
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
        var byId: [String: DiscoveredHost] = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        for host in next {
            byId[host.id] = host
        }
        discovered = Array(byId.values).sorted { $0.name < $1.name }
    }

    func requestPeerInfo(_ host: DiscoveredHost, completion: @escaping (WireGuardManager.HostInfo?) -> Void) {
        let params = NWParameters.tcp
        let connection = NWConnection(to: host.endpoint, using: params)
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                completion(nil)
                connection.cancel()
            }
        }
        connection.start(queue: .global(qos: .utility))

        receiveOnce(connection: connection) { data in
            let info = WireGuardManager.HostInfo.fromJSON(data: data)
            completion(info)
            connection.cancel()
        }
    }

    private func receiveOnce(connection: NWConnection, completion: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
            completion(data ?? Data())
        }
    }
}
