import Darwin
import XCTest

final class ServerPortProbeTests: XCTestCase {
    func testRejectsPortsOutsideTCPRange() {
        for port in [-1, 0, 65_536, Int.max] {
            XCTAssertEqual(
                ServerPortProbe.availability(host: "127.0.0.1", port: port),
                .invalidAddress,
                "Port \(port) must be rejected"
            )
        }
    }

    func testRejectsInvalidHost() {
        XCTAssertEqual(
            ServerPortProbe.availability(host: "not a valid host !", port: 8080),
            .invalidAddress
        )
    }

    func testReportsUnusedIPv4PortAsAvailable() throws {
        let port = try makeUnusedIPv4Port()

        XCTAssertEqual(
            ServerPortProbe.availability(host: "127.0.0.1", port: port),
            .available
        )
    }

    func testReportsActiveIPv4ListenerAsAddressInUse() throws {
        let listener = try makeIPv4Listener()
        defer { Darwin.close(listener.descriptor) }

        XCTAssertEqual(
            ServerPortProbe.availability(host: "127.0.0.1", port: listener.port),
            .addressInUse
        )
    }

    func testWildcardIPv4ListenerAllowsSpecificLoopbackListener() throws {
        let listener = try makeIPv4Listener(wildcard: true, reuseAddress: false)
        defer { Darwin.close(listener.descriptor) }

        XCTAssertEqual(
            ServerPortProbe.availability(host: "127.0.0.1", port: listener.port),
            .available
        )

        let loopbackListener = try makeIPv4Listener(port: listener.port)
        Darwin.close(loopbackListener.descriptor)
    }

    func testReportsIPv4PortAvailableDuringServerSideTimeWait() throws {
        let port = try makeRecentlyClosedIPv4Listener()

        XCTAssertEqual(
            ServerPortProbe.availability(host: "127.0.0.1", port: port),
            .available
        )
    }

    func testReportsActiveIPv6ListenerAsAddressInUse() throws {
        let listener = try makeIPv6Listener()
        defer { Darwin.close(listener.descriptor) }

        XCTAssertEqual(
            ServerPortProbe.availability(host: "::1", port: listener.port),
            .addressInUse
        )
    }

    func testReportsIPv6PortAvailableDuringServerSideTimeWait() throws {
        let port = try makeRecentlyClosedIPv6Listener()

        XCTAssertEqual(
            ServerPortProbe.availability(host: "::1", port: port),
            .available
        )
    }

    func testRepeatedProbesDoNotReserveAvailablePort() throws {
        let port = try makeUnusedIPv4Port()

        for _ in 0..<10 {
            XCTAssertEqual(
                ServerPortProbe.availability(host: "127.0.0.1", port: port),
                .available
            )
        }

        let listener = try makeIPv4Listener(port: port)
        defer { Darwin.close(listener.descriptor) }
        XCTAssertEqual(
            ServerPortProbe.availability(host: "127.0.0.1", port: port),
            .addressInUse
        )
    }

    private func makeUnusedIPv4Port() throws -> Int {
        let listener = try makeIPv4Listener()
        Darwin.close(listener.descriptor)
        return listener.port
    }

    private func makeRecentlyClosedIPv4Listener() throws -> Int {
        var listener = try makeIPv4Listener()
        defer {
            if listener.descriptor >= 0 {
                Darwin.close(listener.descriptor)
            }
        }

        var client = socket(AF_INET, SOCK_STREAM, 0)
        try requireValid(client, operation: "IPv4 client socket")
        defer {
            if client >= 0 {
                Darwin.close(client)
            }
        }

        var address = ipv4Address(port: listener.port)
        try requireSuccess(
            withSockAddr(&address) {
                Darwin.connect(client, $0, $1)
            },
            operation: "IPv4 connect"
        )

        let accepted = Darwin.accept(listener.descriptor, nil, nil)
        try requireValid(accepted, operation: "IPv4 accept")
        Darwin.close(accepted)

        var byte: UInt8 = 0
        _ = Darwin.recv(client, &byte, 1, 0)
        Darwin.close(client)
        client = -1
        Darwin.close(listener.descriptor)
        listener.descriptor = -1
        return listener.port
    }

    private func makeRecentlyClosedIPv6Listener() throws -> Int {
        var listener = try makeIPv6Listener()
        defer {
            if listener.descriptor >= 0 {
                Darwin.close(listener.descriptor)
            }
        }

        var client = socket(AF_INET6, SOCK_STREAM, 0)
        try requireValid(client, operation: "IPv6 client socket")
        defer {
            if client >= 0 {
                Darwin.close(client)
            }
        }

        var address = ipv6Address(port: listener.port)
        try requireSuccess(
            withSockAddr(&address) {
                Darwin.connect(client, $0, $1)
            },
            operation: "IPv6 connect"
        )

        let accepted = Darwin.accept(listener.descriptor, nil, nil)
        try requireValid(accepted, operation: "IPv6 accept")
        Darwin.close(accepted)

        var byte: UInt8 = 0
        _ = Darwin.recv(client, &byte, 1, 0)
        Darwin.close(client)
        client = -1
        Darwin.close(listener.descriptor)
        listener.descriptor = -1
        return listener.port
    }

    private func makeIPv4Listener(
        port: Int = 0,
        wildcard: Bool = false,
        reuseAddress: Bool = true
    ) throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try requireValid(descriptor, operation: "IPv4 listener socket")
        var shouldClose = true
        defer {
            if shouldClose {
                Darwin.close(descriptor)
            }
        }

        if reuseAddress {
            try enableAddressReuse(descriptor)
        }
        var address = ipv4Address(port: port, wildcard: wildcard)
        try requireSuccess(
            withSockAddr(&address) {
                Darwin.bind(descriptor, $0, $1)
            },
            operation: "IPv4 bind"
        )
        try requireSuccess(Darwin.listen(descriptor, 1), operation: "IPv4 listen")

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        try requireSuccess(
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &addressLength)
                }
            },
            operation: "IPv4 getsockname"
        )

        shouldClose = false
        return (descriptor, Int(UInt16(bigEndian: address.sin_port)))
    }

    private func makeIPv6Listener() throws -> (descriptor: Int32, port: Int) {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        try requireValid(descriptor, operation: "IPv6 listener socket")
        var shouldClose = true
        defer {
            if shouldClose {
                Darwin.close(descriptor)
            }
        }

        try enableAddressReuse(descriptor)
        var address = ipv6Address(port: 0)
        try requireSuccess(
            withSockAddr(&address) {
                Darwin.bind(descriptor, $0, $1)
            },
            operation: "IPv6 bind"
        )
        try requireSuccess(Darwin.listen(descriptor, 1), operation: "IPv6 listen")

        var addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        try requireSuccess(
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &addressLength)
                }
            },
            operation: "IPv6 getsockname"
        )

        shouldClose = false
        return (descriptor, Int(UInt16(bigEndian: address.sin6_port)))
    }

    private func enableAddressReuse(_ descriptor: Int32) throws {
        var reuseAddress: Int32 = 1
        try requireSuccess(
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout.size(ofValue: reuseAddress))
            ),
            operation: "setsockopt"
        )
    }

    private func ipv4Address(port: Int, wildcard: Bool = false) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(
            s_addr: wildcard ? in_addr_t(INADDR_ANY) : inet_addr("127.0.0.1")
        )
        return address
    }

    private func ipv6Address(port: Int) -> sockaddr_in6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(port).bigEndian
        address.sin6_addr = in6addr_loopback
        return address
    }

    private func withSockAddr<Address, Result>(
        _ address: inout Address,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<Address>.size))
            }
        }
    }

    private func requireSuccess(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw posixError(operation)
        }
    }

    private func requireValid(_ descriptor: Int32, operation: String) throws {
        guard descriptor >= 0 else {
            throw posixError(operation)
        }
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed"]
        )
    }
}
