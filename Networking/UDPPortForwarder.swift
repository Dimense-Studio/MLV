import Foundation
import Network

/// A bi-directional UDP port forwarder.
/// It listens on a host port and forwards traffic to a target IP/port (usually a VM guest).
/// It maintains a mapping of client endpoints to handle return traffic, essential for WireGuard.
final class UDPPortForwarder {
    private let listenPort: UInt16
    private let targetHost: NWEndpoint.Host
    private let targetPort: NWEndpoint.Port
    private var listener: NWListener?
    private let queue: DispatchQueue
    
    // Tracks active sessions: Client Endpoint -> Connection to Guest
    private var sessions: [NWEndpoint: NWConnection] = [:]
    private let sessionLock = NSLock()
    
    init(listenPort: Int, targetIP: String, targetPort: Int, queue: DispatchQueue = DispatchQueue(label: "mlv.udp.forwarder")) throws {
        self.listenPort = UInt16(listenPort)
        self.targetHost = NWEndpoint.Host(targetIP)
        guard let tPort = NWEndpoint.Port(rawValue: UInt16(targetPort)) else {
            throw NSError(domain: "UDPPortForwarder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid target UDP port \(targetPort)"])
        }
        self.targetPort = tPort
        self.queue = queue
    }
    
    func start() throws {
        if listener != nil { return }
        guard let lPort = NWEndpoint.Port(rawValue: listenPort) else {
            throw NSError(domain: "UDPPortForwarder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid listen UDP port \(listenPort)"])
        }
        
        let params = NWParameters.udp
        let listener = try NWListener(using: params, on: lPort)
        
        listener.newConnectionHandler = { [weak self] clientConnection in
            guard let self = self else { return }
            clientConnection.start(queue: self.queue)
            self.handleClientConnection(clientConnection)
        }
        
        listener.start(queue: queue)
        self.listener = listener
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        
        sessionLock.lock()
        for conn in sessions.values {
            conn.cancel()
        }
        sessions.removeAll()
        sessionLock.unlock()
    }
    
    private func handleClientConnection(_ clientConnection: NWConnection) {
        clientConnection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                let clientEndpoint = clientConnection.endpoint
                self.forwardToGuest(data: data, fromClient: clientEndpoint, clientConnection: clientConnection)
            }
            
            if error == nil {
                self.handleClientConnection(clientConnection)
            } else {
                self.cleanupSession(for: clientConnection.endpoint)
            }
        }
    }
    
    private func forwardToGuest(data: Data, fromClient clientEndpoint: NWEndpoint, clientConnection: NWConnection) {
        sessionLock.lock()
        if let existingConn = sessions[clientEndpoint] {
            sessionLock.unlock()
            existingConn.send(content: data, completion: .contentProcessed({ _ in }))
            return
        }
        
        // Create new connection to guest for this client
        let guestConn = NWConnection(host: targetHost, port: targetPort, using: .udp)
        sessions[clientEndpoint] = guestConn
        sessionLock.unlock()
        
        guestConn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guestConn.send(content: data, completion: .contentProcessed({ _ in }))
                self?.receiveFromGuest(guestConn, forClient: clientConnection)
            case .failed, .cancelled:
                self?.cleanupSession(for: clientEndpoint)
            default:
                break
            }
        }
        guestConn.start(queue: queue)
    }
    
    private func receiveFromGuest(_ guestConn: NWConnection, forClient clientConnection: NWConnection) {
        guestConn.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                clientConnection.send(content: data, completion: .contentProcessed({ _ in }))
            }
            
            if error == nil {
                self.receiveFromGuest(guestConn, forClient: clientConnection)
            } else {
                self.cleanupSession(for: clientConnection.endpoint)
            }
        }
    }
    
    private func cleanupSession(for endpoint: NWEndpoint) {
        sessionLock.lock()
        if let conn = sessions.removeValue(forKey: endpoint) {
            conn.cancel()
        }
        sessionLock.unlock()
    }
}
