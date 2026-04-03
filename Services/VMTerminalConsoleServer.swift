import Foundation
import Network

final class VMTerminalConsoleServer {
    private let port: UInt16
    private let queue = DispatchQueue(label: "mlv.vm.console.server")
    private var listener: NWListener?
    private var connection: NWConnection?
    
    private let writeToVM: @Sendable (Data) -> Void
    private let initialData: @Sendable () -> Data
    private let onConnect: @Sendable () -> Void
    
    init(
        port: Int,
        initialData: @escaping @Sendable () -> Data,
        onConnect: @escaping @Sendable () -> Void,
        writeToVM: @escaping @Sendable (Data) -> Void
    ) throws {
        guard port > 0, port < 65536 else {
            throw VMError.configurationInvalid("Invalid console port \(port)")
        }
        self.port = UInt16(port)
        self.initialData = initialData
        self.onConnect = onConnect
        self.writeToVM = writeToVM
    }
    
    func start() throws {
        if listener != nil { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw VMError.configurationInvalid("Invalid console port \(port)")
        }
        
        let params = NWParameters.tcp
        
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            self?.queue.async {
                self?.accept(conn)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }
    
    func stop() {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }
    
    func sendToClient(_ data: Data) {
        queue.async {
            guard let connection = self.connection else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }
    
    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        onConnect()
        
        conn.stateUpdateHandler = { state in
            if case .failed = state {
                conn.cancel()
            }
        }
        
        conn.start(queue: queue)
        
        let data = initialData()
        if !data.isEmpty {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
        receiveLoop(conn)
    }
    
    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                self?.writeToVM(data)
            }
            if error == nil && !isComplete {
                self?.receiveLoop(conn)
            } else {
                conn.cancel()
            }
        }
    }
}
