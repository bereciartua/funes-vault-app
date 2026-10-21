import Darwin
import dnssd
import Foundation
import FunesProtocol
import Network
import os

private let logger = Logger(subsystem: Identifiers.macLoggerSubsystem, category: "companion")

/// A bound, listening BSD socket. `NWListener` is not used: on macOS 27 its own TCP stack never
/// finishes the handshake for flows arriving on Tailscale's `utun` interface (Spike 1e,
/// 2026-10-21), while the kernel's `accept` does.
struct ListeningSocket {
    enum Address {
        /// `::` with `IPV6_V6ONLY` off: every interface, IPv4 and IPv6, including ones that
        /// appear later (Tailscale connecting after the listener started).
        case any
        case loopbackIPv4
        case loopbackIPv6
    }

    let fd: Int32
    let port: Int

    /// `port` 0 picks a free port. Throws the `errno` of the call that failed.
    init(_ address: Address, port: Int) throws(POSIXError) {
        let family = address == .loopbackIPv4 ? AF_INET : AF_INET6
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw Self.error() }
        do throws(POSIXError) {
            try Self.option(fd, SOL_SOCKET, SO_REUSEADDR, 1)
            if family == AF_INET6 { try Self.option(fd, IPPROTO_IPV6, IPV6_V6ONLY, address == .any ? 0 : 1) }
            try Self.bind(fd, address, port: UInt16(clamping: port))
            guard listen(fd, SOMAXCONN) == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw Self.error() }
            self.fd = fd
            self.port = try Self.localPort(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// The next pending connection, non-blocking with `SIGPIPE` off, and its peer's address
    /// bytes (4 for IPv4, 16 for IPv6). Nil when none is waiting.
    func accept() -> (fd: Int32, address: [UInt8])? {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &length) }
            }
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return nil
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            return (client, Self.addressBytes(storage))
        }
    }

    static func addressBytes(_ storage: sockaddr_storage) -> [UInt8] {
        let family = Int32(storage.ss_family)
        var storage = storage
        return withUnsafeBytes(of: &storage) { raw in
            switch family {
            case AF_INET:
                let address = raw.load(as: sockaddr_in.self).sin_addr
                return withUnsafeBytes(of: address) { [UInt8]($0) }
            case AF_INET6:
                let address = raw.load(as: sockaddr_in6.self).sin6_addr
                return withUnsafeBytes(of: address) { [UInt8]($0) }
            default:
                return []
            }
        }
    }

    private static func bind(_ fd: Int32, _ address: Address, port: UInt16) throws(POSIXError) {
        let result: Int32
        if address == .loopbackIPv4 {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            sin.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            result = withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_port = port.bigEndian
            sin6.sin6_addr = address == .any ? in6addr_any : in6addr_loopback
            result = withUnsafePointer(to: &sin6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard result == 0 else { throw error() }
    }

    private static func localPort(_ fd: Int32) throws(POSIXError) -> Int {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0 else { throw error() }
        // sin_port and sin6_port sit at the same offset.
        return Int(UInt16(bigEndian: withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in.self).sin_port }))
    }

    private static func option(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) throws(POSIXError) {
        var value = value
        guard setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw error() }
    }

    private static func error() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// Advertises `_funes._tcp` on every interface through mDNSResponder, which `NWListener.service`
/// did before the listener moved to BSD sockets. Create, use and stop it on one queue.
final class BonjourAdvertiser {
    private var service: DNSServiceRef?

    init?(port: Int, txtRecord: [String: String], queue: DispatchQueue) {
        let txt = NWTXTRecord(txtRecord).data
        var service: DNSServiceRef?
        let error = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(&service, 0, 0, nil, Identifiers.bonjourServiceType, nil, nil,
                               UInt16(clamping: port).bigEndian, UInt16(clamping: txt.count), bytes.baseAddress,
                               { _, _, error, _, _, _, _ in
                                   if error != kDNSServiceErr_NoError {
                                       logger.error("Bonjour registration failed: \(error, privacy: .public)") // log-safe: a DNSServiceErrorType code
                                   }
                               }, nil)
        }
        guard error == kDNSServiceErr_NoError, let service else {
            logger.error("Bonjour registration failed: \(error, privacy: .public)") // log-safe: a DNSServiceErrorType code
            return nil
        }
        DNSServiceSetDispatchQueue(service, queue)
        self.service = service
    }

    func stop() {
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
    }
}
