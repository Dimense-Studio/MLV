import Foundation
import Network

final class UDPPortForwarder {
    private let listenPort: UInt16
    private let targetHost: NWEndpoint.Host
    private let targetPort: NWEndpoint.Port
    private var listener: NWListener?
    private let queue: DispatchQueue
    
    init(listenPort: Int, targetIP: String, targetPort: Int, queue: DispatchQueue = DispatchQueue(label: "mlv.udp.forwarder")) throws {
        self.listenPort = UInt16(listenPort)
        self.targetHost = NWEndpoint.Host(targetIP)
        guard let tPort = NWEndpoint.Port(rawValue: UInt16(targetPort)) else {
            throw VMError.configurationInvalid("Invalid target UDP port \(targetPort)")
        }
        self.targetPort = tPort
        self.queue = queue
    }
    
    func start() throws {
        if listener != nil { return }
        guard let lPort = NWEndpoint.Port(rawValue: listenPort) else {
            throw VMError.configurationInvalid("Invalid listen UDP port \(listenPort)")
        }
        let params = NWParameters.udp
        let listener = try NWListener(using: params, on: lPort)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.receiveLoop(from: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
    }
    
    private func receiveLoop(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                self?.forward(data)
            }
            if error == nil {
                self?.receiveLoop(from: connection)
            }
        }
    }
    
    private func forward(_ data: Data) {
        let conn = NWConnection(host: targetHost, port: targetPort, using: .udp)
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                conn.send(content: data, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            } else if case .failed = state {
                conn.cancel()
            }
        }
        conn.start(queue: queue)
    }
}

