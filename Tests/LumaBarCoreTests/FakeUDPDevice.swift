import Foundation
import Darwin
@testable import LumaBarCore

/// A UDP "device" on 127.0.0.1 for discovery tests: answers each datagram it receives with whatever `respond` returns.
final class FakeUDPDevice: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let respond: @Sendable (Data) -> [Data]
    private let lock = NSLock()
    private var _received: [Data] = []
    private var running = true
    private var thread: Thread?

    var received: [Data] { lock.lock(); defer { lock.unlock() }; return _received }

    /// - Parameter bindAny: also receive broadcast/multicast aimed at this port (bind 0.0.0.0 instead of loopback).
    init(port: UInt16, bindAny: Bool = false, respond: @escaping @Sendable (Data) -> [Data]) throws {
        self.port = port
        self.respond = respond
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(ip: bindAny ? "0.0.0.0" : "127.0.0.1", port: port)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { close(fd); throw NSError(domain: "FakeUDPDevice", code: Int(errno)) }

        let thread = Thread { [self] in loop() }
        self.thread = thread
        thread.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        close(fd)
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            lock.lock(); let go = running; lock.unlock()
            guard go else { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0, pfd.revents & Int16(POLLIN) != 0 else { continue }
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { continue }
            let request = Data(buffer[0..<count])
            lock.lock(); _received.append(request); lock.unlock()
            for reply in respond(request) {
                _ = reply.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &source) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, length)
                        }
                    }
                }
            }
        }
    }
}
