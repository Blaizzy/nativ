import Darwin
import Foundation
import MCP

enum NativMCPListenerError: LocalizedError {
    case portOutOfRange(Int)
    case unavailable(Int32)

    var errorDescription: String? {
        switch self {
        case .portOutOfRange(let port):
            "\(port) is not a usable port. Choose a number between 1024 and 65535."
        case .unavailable(let code):
            code == EADDRINUSE
                ? "Another program is already using that port."
                : "The port could not be opened (error \(code))."
        }
    }
}

actor NativMCPListener {
    private static let maximumBodyBytes = 1 << 20
    private static let readTimeoutSeconds = 15

    private let requestedPort: Int
    private let access: NativMCPAccess
    private let endpoints: [NativMCPScope: NativMCPEndpoint]
    private let report: @Sendable (NativMCPAgent?, Int) async -> Void
    private let queue = DispatchQueue(label: "dev.local.Nativ.agent-access", attributes: .concurrent)
    private var descriptor: Int32?

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

    func start() throws {
        guard descriptor == nil else {
            return
        }
        guard requestedPort >= 1024, requestedPort <= 65535 else {
            throw NativMCPListenerError.portOutOfRange(requestedPort)
        }

        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw NativMCPListenerError.unavailable(errno)
        }
        var reuse: Int32 = 1
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(requestedPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(socketDescriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(socketDescriptor, 16) == 0 else {
            let code = errno
            close(socketDescriptor)
            throw NativMCPListenerError.unavailable(code)
        }

        descriptor = socketDescriptor
        accept(on: socketDescriptor)
    }

    func stop() {
        guard let descriptor else {
            return
        }
        self.descriptor = nil
        close(descriptor)
    }

    private func accept(on socketDescriptor: Int32) {
        queue.async { [weak self] in
            while true {
                let connection = Darwin.accept(socketDescriptor, nil, nil)
                guard connection >= 0 else {
                    return
                }
                var timeout = timeval(tv_sec: Self.readTimeoutSeconds, tv_usec: 0)
                setsockopt(
                    connection,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    &timeout,
                    socklen_t(MemoryLayout<timeval>.size)
                )
                guard let self else {
                    close(connection)
                    return
                }
                self.read(connection)
            }
        }
    }

    private nonisolated func read(_ connection: Int32) {
        queue.async { [weak self] in
            let outcome = Self.readRequest(from: connection)
            guard let self else {
                close(connection)
                return
            }
            Task { await self.serve(outcome, on: connection) }
        }
    }

    private func serve(_ outcome: ReadOutcome, on connection: Int32) async {
        defer { close(connection) }
        let request: HTTPRequest
        switch outcome {
        case .request(let read):
            request = read
        case .tooLarge:
            Self.write(status: 413, headers: [:], body: Data(), to: connection)
            return
        case .closed:
            return
        }
        guard Self.isEndpointPath(request.path) else {
            Self.write(status: 404, headers: [:], body: Data(), to: connection)
            return
        }
        guard let key = access.key(forSecret: Self.secret(in: request)),
              let endpoint = endpoints[key.agent.scope]
        else {
            Self.write(status: 401, headers: [:], body: Data(), to: connection)
            await report(nil, 401)
            return
        }
        let response = await endpoint.respond(to: request)
        Self.write(
            status: response.statusCode,
            headers: response.headers,
            body: response.bodyData ?? Data(),
            to: connection
        )
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

    enum ReadOutcome {
        case request(HTTPRequest)
        case tooLarge
        case closed
    }

    private static func readRequest(from connection: Int32) -> ReadOutcome {
        var buffer = Data()
        while true {
            guard let chunk = read(from: connection) else {
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
                guard let chunk = read(from: connection) else {
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

    private static func read(from connection: Int32) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 1 << 16)
        let count = recv(connection, &bytes, bytes.count, 0)
        guard count > 0 else {
            return nil
        }
        return Data(bytes[0..<count])
    }

    private static func write(
        status: Int,
        headers: [String: String],
        body: Data,
        to connection: Int32
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers where name.lowercased() != "content-length" {
            head += "\(name): \(value)\r\n"
        }
        if headers.keys.contains(where: { $0.lowercased() == "content-type" }) == false {
            head += "Content-Type: application/json\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8) + body
        payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let written = send(connection, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard written > 0 else {
                    return
                }
                sent += written
            }
        }
    }
}
