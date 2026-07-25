import Darwin
import Foundation

enum ServerPortProbe {
    /// Whether a TCP listener can bind the given host and port right now.
    static func isAvailable(host: String, port: Int) -> Bool {
        guard (1...65_535).contains(port) else {
            return false
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
            return false
        }
        defer { freeaddrinfo(firstAddress) }

        var address: UnsafeMutablePointer<addrinfo>? = firstAddress
        while let candidate = address {
            let info = candidate.pointee
            let descriptor = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if descriptor >= 0 {
                let bindResult = Darwin.bind(descriptor, info.ai_addr, info.ai_addrlen)
                close(descriptor)
                if bindResult == 0 {
                    return true
                }
            }
            address = info.ai_next
        }
        return false
    }
}
