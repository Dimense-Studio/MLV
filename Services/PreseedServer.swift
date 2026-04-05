import Foundation
import Network
import os

/// Tiny single-file HTTP server to serve preseed.cfg to the installer.
final class PreseedServer {
    static let shared = PreseedServer()
    private let logger = Logger(subsystem: "dimense.net.MLV", category: "PreseedServer")
    private var listener: NWListener?
    private var preseedData: Data = Data()
    private var port: UInt16 = 8088

    func start(preseed: Data, port: UInt16 = 8088) {
        self.preseedData = preseed
        self.port = port

        if listener != nil { return }

        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    conn.send(content: self.httpResponse(), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                }
            }
            listener.start(queue: .global())
            self.listener = listener
            logger.info("Preseed server started on port \(self.port)")
        } catch {
            logger.error("Failed to start preseed server: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func httpResponse() -> Data {
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain\r
        Content-Length: \(preseedData.count)\r
        Connection: close\r
\r
        """
        var response = Data(header.utf8)
        response.append(preseedData)
        return response
    }
}
