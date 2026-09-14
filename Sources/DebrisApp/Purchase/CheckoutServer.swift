import Foundation
import Network

/// Serves one templated checkout page on 127.0.0.1 and then goes away: random
/// port, the first real request wins, everything closes after five minutes.
/// The page (with the Paddle client token in it) never touches disk.
final class CheckoutServer {

    private let queue = DispatchQueue(label: "com.tarunkumar.datadebris.checkout")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var served = false
    private let html: Data

    init(html: String) {
        self.html = Data(html.utf8)
    }

    /// Fills the bundled template. Values are UUIDs, price ids and the client
    /// token — plain URL-safe strings, so no escaping is needed.
    static func page(template: String, env: String, token: String, priceId: String,
                     reference: String, machineId: String) -> String {
        template
            .replacingOccurrences(of: "__ENV__", with: env)
            .replacingOccurrences(of: "__TOKEN__", with: token)
            .replacingOccurrences(of: "__PRICE_ID__", with: priceId)
            .replacingOccurrences(of: "__REFERENCE__", with: reference)
            .replacingOccurrences(of: "__MACHINE_ID__", with: machineId)
    }

    /// Binds a random loopback port and reports the page URL once listening.
    func start(onReady: @escaping (URL) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener?.port {
                onReady(URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 300) { [weak self] in self?.close() }
    }

    func stop() {
        queue.async { self.close() }
    }

    /// Browsers pre-open spare connections; the page goes to the first one
    /// that actually sends bytes, then the whole server shuts.
    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, _, _ in
            guard let self, !self.served, data?.isEmpty == false else { return }
            self.served = true
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(self.html.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + self.html,
                            completion: .contentProcessed { [weak self] _ in self?.close() })
        }
    }

    private func close() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}
