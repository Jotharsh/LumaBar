import Foundation
import Network

/// A Hue Bridge. Only non-secret details; the pairing key is in the `SecretStore`.
public struct HueBridge: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The bridge's own id (from its config), e.g. "001788FFFE123456".
    public var id: String
    public var host: String
    public var name: String

    public init(id: String, host: String, name: String = "Hue Bridge") {
        self.id = id
        self.host = host
        self.name = name
    }
}

/// The bridges this Mac has been paired with, remembered between launches.
public final class HueBridgeBook: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "lumabar.hue.bridges") {
        self.defaults = defaults
        self.key = key
    }

    public var all: [HueBridge] {
        lock.lock(); defer { lock.unlock() }
        return defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([HueBridge].self, from: $0) } ?? []
    }

    public func upsert(_ bridge: HueBridge) {
        var list = all
        if let i = list.firstIndex(where: { $0.id == bridge.id }) { list[i] = bridge } else { list.append(bridge) }
        save(list)
    }

    public func remove(id: String) { save(all.filter { $0.id != id }) }

    private func save(_ list: [HueBridge]) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}

public protocol HueBridgeFinding: Sendable {
    func findBridges() async -> [HueBridge]
}

/// Finds bridges on the local network with Bonjour (`_hue._tcp`). No internet involved.
public struct BonjourHueFinder: HueBridgeFinding {
    public var duration: TimeInterval

    public init(duration: TimeInterval = 2.5) { self.duration = duration }

    public func findBridges() async -> [HueBridge] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: nil), using: .tcp)
        let queue = DispatchQueue(label: "LumaBar.HueBrowser")
        let collector = Collector()

        browser.browseResultsChangedHandler = { results, _ in collector.set(results) }
        browser.start(queue: queue)
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        browser.cancel()

        var bridges: [HueBridge] = []
        for result in collector.results {
            var bridgeID: String?
            if case .bonjour(let txt) = result.metadata { bridgeID = txt["bridgeid"]?.uppercased() }
            guard let host = await Self.resolve(result.endpoint, queue: queue) else { continue }
            var name = "Hue Bridge"
            if case .service(let n, _, _, _) = result.endpoint { name = n }
            bridges.append(HueBridge(id: bridgeID ?? host, host: host, name: name))
        }
        return bridges
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock(); private var _results: Set<NWBrowser.Result> = []
        func set(_ r: Set<NWBrowser.Result>) { lock.lock(); _results = r; lock.unlock() }
        var results: [NWBrowser.Result] { lock.lock(); defer { lock.unlock() }; return Array(_results) }
    }

    /// Connects to the service just long enough to learn its IPv4 address.
    private static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue) async -> String? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = Once()
            let finish: @Sendable (String?) -> Void = { value in
                if once.claim() { connection.cancel(); continuation.resume(returning: value) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint, case .ipv4(let address) = host {
                        finish("\(address)".components(separatedBy: "%").first)
                    } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}

/// Philips' online lookup (discovery.meethue.com). Needs the internet, so the app only uses it when the user asks.
public struct PhilipsCloudHueFinder: HueBridgeFinding {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func findBridges() async -> [HueBridge] {
        guard let url = URL(string: "https://discovery.meethue.com"),
              let (data, response) = try? await transport.send(URLRequest(url: url)), response.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String, let ip = entry["internalipaddress"] as? String else { return nil }
            return HueBridge(id: id.uppercased(), host: ip)
        }
    }
}
