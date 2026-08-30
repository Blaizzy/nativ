import Darwin
import Foundation

enum ServerEndpointAvailability: Equatable {
    case available
    case addressInUse
    case invalidAddress
}

enum ServerPortProbe {
    /// Classifies whether a TCP listener can bind the given host and port right now.
    static func availability(host: String, port: Int) -> ServerEndpointAvailability {
        guard (1...65_535).contains(port) else {
            return .invalidAddress
        }

        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICSERV
        hints.ai_family = host.contains(":") ? AF_INET6 : AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &addresses) == 0,
              let firstAddress = addresses
        else {
            return .invalidAddress
        }
        defer { freeaddrinfo(firstAddress) }

        var foundAddressInUse = false
        var address: UnsafeMutablePointer<addrinfo>? = firstAddress
        while let candidate = address {
            let info = candidate.pointee
            let descriptor = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if descriptor >= 0 {
                var reuseAddress: Int32 = 1
                guard setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_REUSEADDR,
                    &reuseAddress,
                    socklen_t(MemoryLayout.size(ofValue: reuseAddress))
                ) == 0 else {
                    close(descriptor)
                    address = info.ai_next
                    continue
                }
                let bindResult = Darwin.bind(descriptor, info.ai_addr, info.ai_addrlen)
                let bindError = errno
                close(descriptor)
                if bindResult == 0 {
                    return .available
                }
                if bindError == EADDRINUSE {
                    foundAddressInUse = true
                }
            }
            address = info.ai_next
        }
        return foundAddressInUse ? .addressInUse : .invalidAddress
    }
}
