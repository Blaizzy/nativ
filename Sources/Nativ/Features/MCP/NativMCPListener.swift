import Foundation
import MCP
import Network

actor NativMCPListener {
    private let port: NWEndpoint.Port
    private let access: NativMCPAccess
    private let endpoints: [NativMCPScope: NativMCPEndpoint]
    private var listener: NWListener?

    init(port: Int, access: NativMCPAccess, endpoints: [NativMCPScope: NativMCPEndpoint]) {
        self.port = NWEndpoint.Port(rawValue: UInt16(port)) ?? 8765
        self.access = access
        self.endpoints = endpoints
    }

    func start() throws {
        guard listener == nil else {
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task { await self?.serve(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        guard let request = await Self.readRequest(from: connection) else {
            return
        }
        guard let scope = access.scope(forSecret: Self.secret(in: request)),
              let endpoint = endpoints[scope]
        else {
            await Self.write(status: 401, headers: [:], body: Data(), to: connection)
            return
        }
        let response = await endpoint.respond(to: request)
        await Self.write(
            status: response.statusCode,
            headers: response.headers,
            body: response.bodyData ?? Data(),
            to: connection
        )
    }

    private static func secret(in request: HTTPRequest) -> String? {
        guard let header = request.header("Authorization") else {
            return nil
        }
        return header.hasPrefix("Bearer ")
            ? String(header.dropFirst("Bearer ".count))
            : header
    }

    private static func readRequest(from connection: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        while true {
            guard let chunk = await receive(from: connection) else {
                return nil
            }
            buffer += chunk
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                continue
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            var lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
            guard let requestLine = lines.first else {
                return nil
            }
            lines.removeFirst()
            let parts = requestLine.split(separator: " ")
            var headers: [String: String] = [:]
            for line in lines {
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else {
                    continue
                }
                headers[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            let expected = headers.first { $0.key.lowercased() == "content-length" }
                .flatMap { Int($0.value) } ?? 0
            var body = buffer[headerEnd.upperBound...]
            while body.count < expected {
                guard let chunk = await receive(from: connection) else {
                    return nil
                }
                buffer += chunk
                body = buffer[headerEnd.upperBound...]
            }
            return HTTPRequest(
                method: parts.first.map(String.init) ?? "POST",
                headers: headers,
                body: Data(body),
                path: parts.count > 1 ? String(parts[1]) : "/mcp"
            )
        }
    }

    private static func receive(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, _ in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: complete ? nil : Data())
                }
            }
        }
    }

    private static func write(
        status: Int,
        headers: [String: String],
        body: Data,
        to connection: NWConnection
    ) async {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers where name.lowercased() != "content-length" {
            head += "\(name): \(value)\r\n"
        }
        if headers.keys.contains(where: { $0.lowercased() == "content-type" }) == false {
            head += "Content-Type: application/json\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let payload = Data(head.utf8) + body
        await withCheckedContinuation { continuation in
            connection.send(content: payload, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}
