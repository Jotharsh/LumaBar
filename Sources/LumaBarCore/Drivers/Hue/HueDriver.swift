import Foundation

/// Philips Hue lights through the bridge's local REST API (v1, plain HTTP on the LAN). Nothing goes to the cloud.
///
/// Setup is a one-off "press the link button" pairing, which produces an app key. The key is stored in the
/// `SecretStore`; the list of paired bridges (id, IP, name) is not secret and lives in `HueBridgeBook`.
public final class HueDriver: BulbDriver {
    public static let driverID = "hue"
    public let id = HueDriver.driverID
    public let displayName = "Philips Hue"
    public let brand = "Hue"

    private let secrets: SecretStore
    private let transport: HTTPTransport
    public let book: HueBridgeBook
    private let finder: HueBridgeFinding
    private let cloudFinder: HueBridgeFinding
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let pacer = Pacer()

    public init(secrets: SecretStore,
                transport: HTTPTransport = URLSessionTransport(),
                book: HueBridgeBook = HueBridgeBook(),
                finder: HueBridgeFinding = BonjourHueFinder(),
                cloudFinder: HueBridgeFinding? = nil,
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.secrets = secrets
        self.transport = transport
        self.book = book
        self.finder = finder
        self.cloudFinder = cloudFinder ?? PhilipsCloudHueFinder(transport: transport)
        self.sleeper = sleeper
    }

    public var help: DriverHelp {
        DriverHelp(
            driverName: "Hue",
            unreachable: "Make sure the Hue Bridge is powered, connected to your router by its network cable, and on the same network as your Mac. If the bridge was reset or replaced, pair it again.",
            checks: [
                "A light the bridge can't reach (switched off at the wall) shows as unreachable even though the bridge is fine.",
                "A guest network or VPN on your Mac can hide the bridge.",
                "Allow LumaBar in System Settings ▸ Privacy & Security ▸ Local Network.",
                "If the bridge's IP address changed, use Find Bridges again.",
            ],
            setup: [
                "Make sure the bridge is set up in the Hue app and the lights work.",
                "In LumaBar, click Find Bridges (or enter the bridge's IP address).",
                "Press the large round link button on top of the bridge, then click Pair within 30 seconds.",
                "LumaBar adds your lights. The pairing key is stored in your Keychain.",
            ])
    }

    // MARK: Finding and pairing

    public func findBridges() async -> [HueBridge] { await finder.findBridges() }

    /// Asks Philips' servers for bridges on this network. Opt-in: it needs the internet.
    public func findBridgesViaPhilips() async -> [HueBridge] { await cloudFinder.findBridges() }

    /// Reads a bridge's identity. Works without pairing.
    public func identify(host: String) async throws -> HueBridge {
        let object = try await json(.get, host: host, path: "/api/config")
        guard let dict = object as? [String: Any], let bridgeID = dict["bridgeid"] as? String else {
            throw DriverError.protocolError("That address didn't answer like a Hue Bridge.")
        }
        return HueBridge(id: bridgeID.uppercased(), host: host, name: dict["name"] as? String ?? "Hue Bridge")
    }

    /// Press-button pairing: asks for an app key every `pollInterval` until the user presses the bridge's
    /// link button or `timeout` passes. On success the key is saved and the bridge is remembered.
    public func pair(host: String, timeout: TimeInterval = 30, pollInterval: TimeInterval = 2) async throws -> HueBridge {
        var bridge = try await identify(host: host)
        var waited: TimeInterval = 0
        while true {
            let object = try await json(.post, host: host, path: "/api", body: ["devicetype": "lumabar#mac"])
            if let entry = (object as? [[String: Any]])?.first {
                if let key = (entry["success"] as? [String: Any])?["username"] as? String {
                    try secrets.set(key, for: Self.secretKey(bridge.id))
                    bridge.host = host
                    book.upsert(bridge)
                    return bridge
                }
                let type = (entry["error"] as? [String: Any])?["type"] as? Int
                guard type == 101 else {   // 101 = "link button not pressed": keep waiting; anything else is a real error
                    throw DriverError.rejected((entry["error"] as? [String: Any])?["description"] as? String ?? "The bridge refused to pair.")
                }
            }
            guard waited < timeout else {
                throw DriverError.notConfigured("The link button wasn't pressed in time. Press the large round button on top of the bridge, then try Pair again.")
            }
            await sleeper(pollInterval)
            waited += pollInterval
        }
    }

    /// All lights on a paired bridge.
    public func lights(on bridge: HueBridge) async throws -> [Bulb] {
        let object = try await authorised(.get, bridge: bridge, path: "/lights")
        guard let lights = object as? [String: [String: Any]] else { throw DriverError.protocolError("The bridge sent an unexpected list of lights.") }
        return lights.compactMap { (number, light) -> Bulb? in
            guard let type = light["type"] as? String else { return nil }
            let name = light["name"] as? String ?? "Hue light \(number)"
            return Bulb(id: "\(id):\(bridge.id):\(number)", name: name, brand: brand, driverID: id,
                        capabilities: Self.capabilities(forType: type), address: bridge.host,
                        native: ["bridge": bridge.id, "light": number, "type": type])
        }.sorted { (Int($0.native["light"] ?? "") ?? 0) < (Int($1.native["light"] ?? "") ?? 0) }
    }

    static func capabilities(forType type: String) -> DeviceCapabilities {
        switch type.lowercased() {
        case "extended color light": return [.power, .brightness, .colorTemp, .color]
        case "color light": return [.power, .brightness, .color]
        case "color temperature light": return [.power, .brightness, .colorTemp]
        case "dimmable light": return [.power, .brightness]
        default: return [.power]                         // on/off lights and plugs
        }
    }

    static func secretKey(_ bridgeID: String) -> String { "hue.key.\(bridgeID)" }

    // MARK: BulbDriver

    /// Lists the lights on every paired bridge. If a bridge has moved to a new IP, it's looked up again by id.
    public func discover() async -> [Bulb] {
        var all: [Bulb] = []
        for var bridge in book.all {
            if let lights = try? await lights(on: bridge) {
                all += lights
            } else if let moved = await finder.findBridges().first(where: { $0.id == bridge.id }), moved.host != bridge.host {
                bridge.host = moved.host
                if let lights = try? await lights(on: bridge) { book.upsert(bridge); all += lights }
            }
        }
        return all
    }

    // Removing one light never deletes the pairing key: it belongs to the bridge. `unpair(_:)` removes it.

    /// Forgets a bridge entirely: removes its pairing key and stops listing its lights.
    public func unpair(_ bridge: HueBridge) {
        try? secrets.set(nil, for: Self.secretKey(bridge.id))
        book.remove(id: bridge.id)
    }

    public func getState(of bulb: Bulb) async throws -> BulbState {
        let (bridge, number) = try location(of: bulb)
        let object = try await authorised(.get, bridge: bridge, path: "/lights/\(number)")
        guard let light = object as? [String: Any], let state = light["state"] as? [String: Any] else {
            throw DriverError.protocolError("The bridge sent an unexpected light state.")
        }
        if state["reachable"] as? Bool == false {
            throw DriverError.unreachable("\(bulb.name) can't be reached by the bridge. Check that it has power (not switched off at the wall).")
        }
        let isOn = state["on"] as? Bool ?? false
        let brightness = state["bri"] as? Int
        let mode = state["colormode"] as? String
        var temperature: Int?
        var rgb: RGB?
        if mode == "ct", let mired = state["ct"] as? Int, mired > 0 {
            temperature = 1_000_000 / mired
        } else if let hue = state["hue"] as? Int, let sat = state["sat"] as? Int {
            rgb = ColorMath.rgb(hue: Double(hue) / 65535, saturation: Double(sat) / 254, value: 1)
        }
        return BulbState(isOn: isOn, dimming: brightness.map { max(1, Int((Double($0) / 254 * 100).rounded())) } ?? 100,
                         temperature: temperature, rgb: rgb)
    }

    public func apply(_ command: LightCommand, to bulb: Bulb) async throws {
        let (bridge, number) = try location(of: bulb)
        var body: [String: Any] = [:]
        if let on = command.state { body["on"] = on }
        if command.state != false {
            if let percent = command.dimming { body["bri"] = Self.brightness(fromPercent: percent) }
            if let rgb = command.rgb {
                body["hue"] = Int((ColorMath.hue(of: rgb) * 65535).rounded())
                body["sat"] = Int((ColorMath.saturation(of: rgb) * 254).rounded())
            } else if let kelvin = command.temp {
                body["ct"] = Self.mired(fromKelvin: kelvin)
            }
            if body.count > 1 || body["on"] == nil { body["transitiontime"] = 2 }   // tenths of a second
        }
        guard !body.isEmpty else { return }

        await pacer.wait(for: bridge.id, sleeper: sleeper)
        let object = try await authorised(.put, bridge: bridge, path: "/lights/\(number)/state", body: body)
        try Self.checkResults(object)
    }

    static func brightness(fromPercent p: Int) -> Int { min(max(Int((Double(p) / 100 * 253).rounded()) + 1, 1), 254) }
    static func mired(fromKelvin k: Int) -> Int { min(max(Int((1_000_000 / Double(max(k, 1))).rounded()), 153), 500) }

    // MARK: HTTP

    private enum Method: String { case get = "GET", post = "POST", put = "PUT" }

    private func location(of bulb: Bulb) throws -> (HueBridge, String) {
        guard let bridgeID = bulb.native["bridge"], let number = bulb.native["light"] else {
            throw DriverError.notConfigured("\(bulb.name) needs to be added again.")
        }
        let bridge = book.all.first { $0.id == bridgeID } ?? HueBridge(id: bridgeID, host: bulb.address)
        // The bulb's saved address is refreshed by discovery; prefer it when the book is stale.
        return (HueBridge(id: bridge.id, host: bulb.address.isEmpty ? bridge.host : bulb.address, name: bridge.name), number)
    }

    private func authorised(_ method: Method, bridge: HueBridge, path: String, body: [String: Any]? = nil) async throws -> Any {
        guard let key = secrets.get(Self.secretKey(bridge.id)) else {
            throw DriverError.authentication("LumaBar isn't paired with this Hue Bridge. Open Settings ▸ Drivers ▸ Hue and pair it.")
        }
        let object = try await json(method, host: bridge.host, path: "/api/\(key)\(path)", body: body)
        // Errors come back as [{"error":{"type":1,"description":"unauthorized user"}}]
        if let first = (object as? [[String: Any]])?.first, let error = first["error"] as? [String: Any] {
            if (error["type"] as? Int) == 1 {
                throw DriverError.authentication("The bridge no longer recognises LumaBar. Pair it again in Settings ▸ Drivers ▸ Hue.")
            }
        }
        return object
    }

    private func json(_ method: Method, host: String, path: String, body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: "http://\(host)\(path)") else { throw DriverError.notConfigured("Bad bridge address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw DriverError.unreachable("The bridge answered with HTTP \(response.statusCode).") }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw DriverError.protocolError("The bridge's reply wasn't JSON.") }
        return object
    }

    private static func checkResults(_ object: Any) throws {
        guard let results = object as? [[String: Any]] else { return }
        for result in results {
            if let error = result["error"] as? [String: Any] {
                throw DriverError.rejected(error["description"] as? String ?? "The bridge rejected the command.")
            }
        }
    }

    /// The bridge handles about 10 light commands a second; keep a little spacing between them.
    private final class Pacer: @unchecked Sendable {
        private let lock = NSLock()
        private var next: [String: Date] = [:]
        private let spacing: TimeInterval = 0.1

        /// Reserves the next slot for `key` and returns how long to wait for it. Synchronous so the lock is never held across an `await`.
        private func reserve(_ key: String) -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            let slot = max(now, next[key] ?? now)
            next[key] = slot.addingTimeInterval(spacing)
            return slot.timeIntervalSince(now)
        }

        func wait(for key: String, sleeper: @Sendable (TimeInterval) async -> Void) async {
            let delay = reserve(key)
            if delay > 0 { await sleeper(delay) }
        }
    }
}
