import Foundation
import Network

/// A single generated website, served from memory on its own loopback origin.
/// No filesystem routes or native execution endpoints are exposed.
@MainActor
final class ChatWorkPreviewServer {
    private let listener: NWListener
    private let path = "/\(UUID().uuidString)/index.html"
    private var html = Data()
    private var started = false
    private var stopped = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
    }

    deinit {
        listener.cancel()
        connections.values.forEach { $0.cancel() }
    }

    func update(_ content: String) { html = Data(content.utf8) }

    func start() async throws -> URL {
        if !started {
            started = true
            listener.start(queue: .global(qos: .userInitiated))
        }
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            if case .ready = listener.state, let port = listener.port {
                return URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")!
            }
            if case .failed(let error) = listener.state { throw error }
            if case .cancelled = listener.state { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.timedOut)
    }

    func stop() {
        stopped = true
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 32 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                Task { @MainActor [weak self] in self?.connections.removeValue(forKey: id) }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        // Bound idle/partial requests as well as their header size.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { connection.cancel() }
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                let request = buffered + (data ?? Data())
                guard request.count <= 16_384 else { connection.cancel(); return }
                guard let end = request.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete || error != nil { connection.cancel() }
                    else { self.receive(connection, buffered: request) }
                    return
                }
                self.respond(connection, header: String(decoding: request[..<end.lowerBound], as: UTF8.self))
            }
        }
    }

    private func respond(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?
            .dropFirst(5).trimmingCharacters(in: .whitespaces)
        let expectedHost = listener.port.map { "127.0.0.1:\($0.rawValue)" }
        let method = request.first.map(String.init) ?? ""
        let target = request.count > 1 ? String(request[1]).components(separatedBy: "?")[0] : ""
        let status: String
        let body: Data
        if host != expectedHost || expectedHost == nil {
            status = "403 Forbidden"; body = Data("Forbidden".utf8)
        } else if method != "GET" && method != "HEAD" {
            status = "405 Method Not Allowed"; body = Data("Method not allowed".utf8)
        } else if target != path {
            status = "404 Not Found"; body = Data("Not found".utf8)
        } else {
            status = "200 OK"; body = html
        }
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + (method == "HEAD" ? Data() : body),
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
