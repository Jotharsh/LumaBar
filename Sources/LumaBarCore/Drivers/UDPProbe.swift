import Foundation
import Darwin

/// One UDP datagram received while probing, with the sender's address.
public struct Datagram: Sendable {
    public let data: Data
    public let source: String
}

/// Sends a packet to some addresses (broadcast or multicast included) and collects every reply for a
/// short while. Plain sockets, because the Network framework can't send broadcasts (no `SO_BROADCAST`).
enum UDPProbe {
    /// - Parameter stopWhen: if given, collecting ends as soon as a datagram satisfies it (for request/response use).
    static func collect(payload: Data, targets: [(host: String, port: UInt16)], bindPort: UInt16 = 0,
                        duration: TimeInterval = 2.0, stopWhen: (@Sendable (Datagram) -> Bool)? = nil) async -> [Datagram] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: collectBlocking(payload: payload, targets: targets, bindPort: bindPort,
                                                               duration: duration, stopWhen: stopWhen))
            }
        }
    }

    private static func collectBlocking(payload: Data, targets: [(host: String, port: UInt16)], bindPort: UInt16,
                                        duration: TimeInterval, stopWhen: (@Sendable (Datagram) -> Bool)?) -> [Datagram] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, size)
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var local = sockaddr_in(ip: "0.0.0.0", port: bindPort)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 && bindPort != 0 {   // port taken: fall back to any port
            var any = sockaddr_in(ip: "0.0.0.0", port: 0)
            _ = withUnsafePointer(to: &any) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }

        func sendAll() {
            for target in targets {
                var dest = sockaddr_in(ip: target.host, port: target.port)
                _ = payload.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &dest) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        var found: [Datagram] = []
        let deadline = Date().addingTimeInterval(duration)
        let resendAt = Date().addingTimeInterval(duration / 2)   // UDP can drop the first packet
        var resent = false
        sendAll()

        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            if !resent && Date() >= resendAt { sendAll(); resent = true }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0, pfd.revents & Int16(POLLIN) != 0 else { continue }
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            if count > 0 {
                let datagram = Datagram(data: Data(buffer[0..<count]), source: source.ipString)
                found.append(datagram)
                if stopWhen?(datagram) == true { break }
            }
        }
        return found
    }

    /// Sends one datagram to a single host and returns the first reply `accept` approves. Resends once on silence.
    static func request(payload: Data, host: String, port: UInt16, timeout: TimeInterval = 0.8, attempts: Int = 2,
                        accept: @escaping @Sendable (Datagram) -> Bool = { _ in true }) async -> Datagram? {
        for _ in 0..<attempts {
            let replies = await collect(payload: payload, targets: [(host, port)], duration: timeout,
                                        stopWhen: { $0.source == host && accept($0) })
            if let match = replies.last(where: { $0.source == host && accept($0) }) { return match }
        }
        return nil
    }
}
