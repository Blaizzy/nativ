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
    private static let readTimeoutSeconds = 15

    private let requestedPort: Int
    private let respond: @Sendable (HTTPRequest) async -> HTTPResponse
    private let queue = DispatchQueue(label: "dev.local.Nativ.mcp-server", attributes: .concurrent)
    private var descriptor: Int32?

    init(port: Int, respond: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.requestedPort = port
        self.respond = respond
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
                self.handle(connection)
            }
        }
    }

    private nonisolated func handle(_ connection: Int32) {
        queue.async { [weak self] in
            var buffer = Data()
            while true {
                switch NativMCPRequestReader.read(buffer) {
                case .request(let request):
                    guard let self else {
                        close(connection)
                        return
                    }
                    Task { await self.reply(to: request, on: connection) }
                    return
                case .tooLarge:
                    Self.write(status: 413, headers: [:], body: Data(), to: connection)
                    close(connection)
                    return
                case .malformed:
                    Self.write(status: 400, headers: [:], body: Data(), to: connection)
                    close(connection)
                    return
                case .incomplete:
                    guard let chunk = Self.receive(from: connection) else {
                        close(connection)
                        return
                    }
                    buffer += chunk
                }
            }
        }
    }

    private func reply(to request: HTTPRequest, on connection: Int32) async {
        defer { close(connection) }
        guard NativMCPRequestReader.isEndpointPath(request.path) else {
            Self.write(status: 404, headers: [:], body: Data(), to: connection)
            return
        }
        let response = await respond(request)
        Self.write(
            status: response.statusCode,
            headers: response.headers,
            body: response.bodyData ?? Data(),
            to: connection
        )
    }

    private static func receive(from connection: Int32) -> Data? {
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
