import Foundation
import MCP
import Network

enum NativMCPListenerError: LocalizedError {
    case cancelled
    case portOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "The connection was closed before Nativ could listen."
        case .portOutOfRange(let port):
            "\(port) is not a usable port. Choose a number between 1024 and 65535."
        }
    }
}

actor NativMCPListener {
    private static let maximumBodyBytes = 1 << 20
    private static let readTimeoutSeconds = 15.0
    private let requestedPort: Int
    private let access: NativMCPAccess
    private let endpoints: [NativMCPScope: NativMCPEndpoint]
    private let report: @Sendable (NativMCPAgent?, Int) async -> Void
    private var listener: NWListener?

    init(
        port: Int,
        access: NativMCPAccess,
        endpoints: [NativMCPScope: NativMCPEndpoint],
        report: @escaping @Sendable (NativMCPAgent?, Int) async -> Void
    ) {
        self.requestedPort = port
        self.access = access
        self.endpoints = endpoints
        self.report = report
    }

    func start() async throws {
        guard listener == nil else {
            return
        }
        guard let candidate = UInt16(exactly: requestedPort), candidate >= 1024,
              let port = NWEndpoint.Port(rawValue: candidate)
        else {
            throw NativMCPListenerError.portOutOfRange(requestedPort)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Task { await self?.serve(connection) }
        }

        let (states, continuation) = AsyncStream<NWListener.State>.makeStream()
        listener.stateUpdateHandler = { continuation.yield($0) }
        listener.start(queue: .global(qos: .userInitiated))

        for await state in states {
            switch state {
            case .ready:
                listener.stateUpdateHandler = nil
                continuation.finish()
                self.listener = listener
                return
            case .failed(let error), .waiting(let error):
                listener.cancel()
                throw error
            case .cancelled:
                throw NativMCPListenerError.cancelled
            default:
                continue
            }
        }
        throw NativMCPListenerError.cancelled
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) async {
        let request: HTTPRequest
        switch await Self.readRequest(from: connection) {
        case .request(let read):
            request = read
        case .tooLarge:
            await Self.write(status: 413, headers: [:], body: Data(), to: connection)
            connection.cancel()
            return
        case .closed:
            connection.cancel()
            return
        }
        guard Self.isEndpointPath(request.path) else {
            await Self.write(status: 404, headers: [:], body: Data(), to: connection)
            connection.cancel()
            return
        }
        guard let key = access.key(forSecret: Self.secret(in: request)),
              let endpoint = endpoints[key.agent.scope]
        else {
            await Self.write(status: 401, headers: [:], body: Data(), to: connection)
            connection.cancel()
            await report(nil, 401)
            return
        }
        let response = await endpoint.respond(to: request)
        await Self.write(
            status: response.statusCode,
            headers: response.headers,
            body: response.bodyData ?? Data(),
            to: connection
        )
        connection.cancel()
        await report(key.agent, response.statusCode)
    }

    private static func isEndpointPath(_ path: String?) -> Bool {
        guard let path = path?.split(separator: "?").first.map(String.init) else {
            return false
        }
        return path == "/mcp" || path == "/mcp/"
    }

    private static func secret(in request: HTTPRequest) -> String? {
        guard let header = request.header("Authorization") else {
            return nil
        }
        return header.hasPrefix("Bearer ")
            ? String(header.dropFirst("Bearer ".count))
            : header
    }

    private enum ReadOutcome {
        case request(HTTPRequest)
        case tooLarge
        case closed
    }

    private static func readRequest(from connection: NWConnection) async -> ReadOutcome {
        var buffer = Data()
        while true {
            guard let chunk = await receive(from: connection) else {
                return .closed
            }
            buffer += chunk
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard buffer.count <= maximumBodyBytes else {
                    return .tooLarge
                }
                continue
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            var lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
            guard let requestLine = lines.first else {
                return .closed
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
            guard expected <= maximumBodyBytes else {
                return .tooLarge
            }
            var body = buffer[headerEnd.upperBound...]
            while body.count < expected {
                guard let chunk = await receive(from: connection) else {
                    return .closed
                }
                buffer += chunk
                body = buffer[headerEnd.upperBound...]
            }
            return .request(
                HTTPRequest(
                    method: parts.first.map(String.init) ?? "POST",
                    headers: headers,
                    body: Data(body),
                    path: parts.count > 1 ? String(parts[1]) : "/mcp"
                )
            )
        }
    }

    private static func receive(from connection: NWConnection) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
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
            group.addTask {
                try? await Task.sleep(for: .seconds(readTimeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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
