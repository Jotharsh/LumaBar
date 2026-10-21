import Foundation
import Network
import Darwin

/// Talks to WiZ bulbs over UDP using the Network framework.
///
/// UDP is unreliable, so every request waits for the bulb's reply and is retried once.
/// A bulb that answered a WiZ broadcast.
public struct WizDiscovery: Equatable, Sendable {
    public let mac: String
    public let ip: String
}

public final class WizClient: @unchecked Sendable {
    public let bulbPort: UInt16
    /// Local port discovery replies are received on. Bulbs answer to the sender's source port,
    /// and some firmware answers to 38899 regardless, so both are the same by default.
    public let listenPort: UInt16
    public let timeout: TimeInterval
    private let queue = DispatchQueue(label: "LumaBar.WizClient")

    public init(bulbPort: UInt16 = WizLimits.port, listenPort: UInt16 = WizLimits.port, timeout: TimeInterval = 1.0) {
        self.bulbPort = bulbPort
        self.listenPort = listenPort
        self.timeout = timeout
    }

    // MARK: - Commands

    public func setPilot(_ params: LightCommand, host: String) async throws {
        let reply = try await exchange(WizMessage.setPilot(params), host: host)
        let response = try WizMessage.parseResponse(reply)
        if let error = response.error { throw WizError.rejected(error.message ?? "code \(error.code ?? 0)") }
        if response.result?.success == false { throw WizError.rejected("setPilot failed") }
    }

    public func getPilot(host: String) async throws -> BulbState {
        let reply = try await exchange(WizMessage.getPilot, host: host)
        let response = try WizMessage.parseResponse(reply)
        if let error = response.error { throw WizError.rejected(error.message ?? "code \(error.code ?? 0)") }
        guard let state = response.bulbState else { throw WizError.invalidResponse }
        return state
    }

    /// Returns the MAC address a bulb reports, used when adding a bulb by IP.
    public func identify(host: String) async throws -> String? {
        let reply = try await exchange(WizMessage.getPilot, host: host)
        return try WizMessage.parseResponse(reply).result?.mac
    }

    // MARK: - Request / response

    private func exchange(_ payload: Data, host: String) async throws -> Data {
        var lastError: Error = WizError.timeout
        for _ in 0..<2 {
            do {
                return try await exchangeOnce(payload, host: host)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func exchangeOnce(_ payload: Data, host: String) async throws -> Data {
        guard let port = NWEndpoint.Port(rawValue: bulbPort) else { throw WizError.offline("bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        let timeout = self.timeout

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let once = OneShot(continuation: continuation, connection: connection)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error { once.fail(WizError.offline(error.localizedDescription)) }
                    })
                    connection.receiveMessage { data, _, _, error in
                        if let data, !data.isEmpty {
                            once.succeed(data)
                        } else {
                            once.fail(WizError.offline(error?.localizedDescription ?? "empty reply"))
                        }
                    }
                case .failed(let error):
                    once.fail(WizError.offline(error.localizedDescription))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.fail(WizError.timeout) }
        }
    }

    // MARK: - Discovery

    /// Broadcasts a registration request and collects replies from every bulb on the LAN.
    ///
    /// This is the one place that doesn't use the Network framework: `NWConnection` cannot set
    /// `SO_BROADCAST`, so a broadcast sent through it is either refused (EACCES for directed
    /// broadcasts) or silently dropped (255.255.255.255). A plain UDP socket does it correctly.
    public func discover(duration: TimeInterval = 2.5, localIP: String? = LocalNetwork.ipv4Address()) async -> [WizDiscovery] {
        let payload = WizMessage.registration(phoneIP: localIP ?? "0.0.0.0")
        let bulbPort = self.bulbPort, listenPort = self.listenPort
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.broadcastDiscovery(
                    payload: payload, bulbPort: bulbPort, listenPort: listenPort, duration: duration))
            }
        }
    }

    private static func broadcastDiscovery(payload: Data, bulbPort: UInt16, listenPort: UInt16, duration: TimeInterval) -> [WizDiscovery] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, size)

        // Bind to the well-known port: some firmware answers to 38899, the rest to our source port.
        // If it is taken, fall back to an ephemeral port (bulbs then answer to that).
        if !bind(fd, port: listenPort) { _ = bind(fd, port: 0) }

        var targets = ["255.255.255.255"] + LocalNetwork.broadcastAddresses()
        targets = Array(NSOrderedSet(array: targets)) as? [String] ?? targets

        func sendAll() {
            for target in targets {
                var dest = sockaddr_in(ip: target, port: bulbPort)
                _ = payload.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &dest) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        let collector = BulbCollector()
        let deadline = Date().addingTimeInterval(duration)
        let resendAt = Date().addingTimeInterval(duration / 2) // UDP can drop the first packet
        var resent = false
        sendAll()

        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            if !resent && Date() >= resendAt { sendAll(); resent = true }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0, pfd.revents & Int16(POLLIN) != 0 else { continue }

            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &sourceLength)
                }
            }
            guard count > 0,
                  let response = try? WizMessage.parseResponse(Data(buffer[0..<count])),
                  let mac = response.result?.mac else { continue }
            collector.add(WizDiscovery(mac: mac, ip: source.ipString))
        }
        return collector.bulbs
    }

    private static func bind(_ fd: Int32, port: UInt16) -> Bool {
        var addr = sockaddr_in(ip: "0.0.0.0", port: port)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

extension sockaddr_in {
    init(ip: String, port: UInt16) {
        self.init()
        sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin_family = sa_family_t(AF_INET)
        sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &sin_addr)
    }

    var ipString: String {
        var address = sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &text, socklen_t(text.count))
        return String(cString: text)
    }
}

/// Resumes a continuation exactly once, from whichever of reply / failure / timeout happens first.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Data, Error>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func succeed(_ data: Data) { finish(.success(data)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        connection.cancel()
        continuation.resume(with: result)
    }
}

private final class BulbCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String: WizDiscovery] = [:]

    func add(_ bulb: WizDiscovery) {
        lock.lock(); defer { lock.unlock() }
        found[bulb.mac] = bulb
    }

    var bulbs: [WizDiscovery] {
        lock.lock(); defer { lock.unlock() }
        return found.values.sorted { $0.mac < $1.mac }
    }
}
