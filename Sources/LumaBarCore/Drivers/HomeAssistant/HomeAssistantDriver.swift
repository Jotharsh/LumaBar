import Foundation

/// Lights controlled through a Home Assistant server's REST API. This is how you reach any brand Home
/// Assistant supports, without LumaBar needing its own driver for it.
///
/// The server URL isn't secret and is kept in UserDefaults; the long-lived access token goes in the
/// `SecretStore` (the Keychain in the app). Needs Home Assistant 2022.11 or newer (for Kelvin colour temperature).
public final class HomeAssistantDriver: BulbDriver {
    public static let driverID = "homeassistant"
    public let id = HomeAssistantDriver.driverID
    public let displayName = "Home Assistant"
    public let brand = "Home Assistant"

    static let tokenKey = "homeassistant.token"
    private static let urlKey = "lumabar.homeassistant.url"

    private let secrets: SecretStore
    private let transport: HTTPTransport
    /// UserDefaults is thread-safe; it just isn't annotated `Sendable` yet.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(secrets: SecretStore, transport: HTTPTransport = URLSessionTransport(), defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.transport = transport
        self.defaults = defaults
    }

    public var serverURL: String? { defaults.string(forKey: Self.urlKey) }
    public var isConfigured: Bool { serverURL != nil && secrets.get(Self.tokenKey) != nil }

    public var help: DriverHelp {
        DriverHelp(
            driverName: "Home Assistant",
            unreachable: "Check the Home Assistant address (for example http://homeassistant.local:8123) and that your access token is still valid. Make sure your Mac can reach the server.",
            checks: [
                "Open the address in a web browser on this Mac. If that doesn't load, LumaBar can't reach it either.",
                "Tokens can be deleted in Home Assistant. If yours was, create a new one and connect again.",
                "Use https:// addresses for servers outside your home network.",
                "If a light is also set up directly in LumaBar (WiZ, Hue, ...), enable only one of the two or it will appear twice.",
            ],
            setup: [
                "In Home Assistant, open your profile (your name at the bottom of the sidebar) and go to the Security tab.",
                "Under \"Long-lived access tokens\", choose Create Token, name it \"LumaBar\", and copy it. Home Assistant only shows it once.",
                "In LumaBar, enter your Home Assistant address (e.g. http://homeassistant.local:8123) and paste the token.",
                "Click Connect. Your lights are imported, and the token is stored in your Keychain.",
            ])
    }

    // MARK: Setup

    /// Checks the address and token against the server, then saves them. Returns the number of lights found.
    @discardableResult
    public func connect(url rawURL: String, token rawToken: String) async throws -> [Bulb] {
        let base = try Self.normalise(rawURL)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw DriverError.notConfigured("Paste your long-lived access token.") }

        _ = try await request(.get, base: base, token: token, path: "/api/")      // 200 {"message":"API running."}
        let bulbs = try await lights(base: base, token: token)
        try secrets.set(token, for: Self.tokenKey)
        defaults.set(base, forKey: Self.urlKey)
        return bulbs
    }

    /// Forgets the server and its token.
    public func disconnect() {
        try? secrets.set(nil, for: Self.tokenKey)
        defaults.removeObject(forKey: Self.urlKey)
    }

    static func normalise(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw DriverError.notConfigured("Enter the full address, including http:// or https://, like http://homeassistant.local:8123.")
        }
        return text
    }

    // MARK: BulbDriver

    public func discover() async -> [Bulb] {
        guard let base = serverURL, let token = secrets.get(Self.tokenKey) else { return [] }
        return (try? await lights(base: base, token: token)) ?? []
    }

    public func getState(of bulb: Bulb) async throws -> BulbState {
        let (base, token, entity) = try connection(for: bulb)
        let object = try await request(.get, base: base, token: token, path: "/api/states/\(entity)")
        guard let dict = object as? [String: Any], let state = dict["state"] as? String else {
            throw DriverError.protocolError("Home Assistant sent an unexpected reply.")
        }
        if state == "unavailable" || state == "unknown" {
            throw DriverError.unreachable("\(bulb.name) is \(state) in Home Assistant. Check that the light is powered and connected there.")
        }
        let attributes = dict["attributes"] as? [String: Any] ?? [:]
        let mode = attributes["color_mode"] as? String
        let brightness = (attributes["brightness"] as? NSNumber)?.intValue
        var temperature: Int?
        var rgb: RGB?
        if mode == "color_temp", let kelvin = (attributes["color_temp_kelvin"] as? NSNumber)?.intValue {
            temperature = kelvin
        } else if let c = attributes["rgb_color"] as? [NSNumber], c.count == 3 {
            // HA reports the colour at its current brightness; normalise to full intensity (brightness is separate).
            let r = c[0].doubleValue, g = c[1].doubleValue, b = c[2].doubleValue
            let top = max(r, g, b)
            if top > 0 { rgb = RGB(r: Int((r / top * 255).rounded()), g: Int((g / top * 255).rounded()), b: Int((b / top * 255).rounded())) }
        }
        return BulbState(isOn: state == "on",
                         dimming: brightness.map { max(1, Int((Double($0) / 255 * 100).rounded())) } ?? 100,
                         temperature: temperature, rgb: rgb)
    }

    public func apply(_ command: LightCommand, to bulb: Bulb) async throws {
        let (base, token, entity) = try connection(for: bulb)

        if command.state == false {
            _ = try await request(.post, base: base, token: token, path: "/api/services/light/turn_off", body: ["entity_id": entity])
            return
        }
        var data: [String: Any] = ["entity_id": entity]
        if let percent = command.dimming { data["brightness_pct"] = percent }
        if let rgb = command.rgb {
            data["rgb_color"] = [rgb.r, rgb.g, rgb.b]
        } else if let kelvin = command.temp {
            data["color_temp_kelvin"] = kelvin
        }
        guard command.state == true || data.count > 1 else { return }
        data["transition"] = 0.3
        _ = try await request(.post, base: base, token: token, path: "/api/services/light/turn_on", body: data)
    }

    // MARK: Lights

    private func lights(base: String, token: String) async throws -> [Bulb] {
        let object = try await request(.get, base: base, token: token, path: "/api/states")
        guard let states = object as? [[String: Any]] else { throw DriverError.protocolError("Home Assistant sent an unexpected list of entities.") }
        let host = URL(string: base)?.host ?? base
        return states.compactMap { entry -> Bulb? in
            guard let entity = entry["entity_id"] as? String, entity.hasPrefix("light.") else { return nil }
            let attributes = entry["attributes"] as? [String: Any] ?? [:]
            let name = attributes["friendly_name"] as? String ?? entity
            return Bulb(id: "\(id):\(entity)", name: name, brand: brand, driverID: id,
                        capabilities: Self.capabilities(from: attributes), address: host, native: ["entity": entity])
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// From `supported_color_modes` (modern Home Assistant), or the older `supported_features` bitmask.
    static func capabilities(from attributes: [String: Any]) -> DeviceCapabilities {
        var caps: DeviceCapabilities = [.power]
        if let modes = attributes["supported_color_modes"] as? [String] {
            let colour: Set<String> = ["hs", "xy", "rgb", "rgbw", "rgbww"]
            if modes.contains(where: { $0 != "onoff" }) { caps.insert(.brightness) }
            if modes.contains("color_temp") || modes.contains("rgbww") { caps.insert(.colorTemp) }
            if modes.contains(where: colour.contains) { caps.insert(.color) }
        } else if let features = (attributes["supported_features"] as? NSNumber)?.intValue {
            if features & 1 != 0 { caps.insert(.brightness) }
            if features & 2 != 0 { caps.insert(.colorTemp) }
            if features & 16 != 0 { caps.insert(.color) }
        }
        return caps
    }

    // MARK: HTTP

    private enum Method: String { case get = "GET", post = "POST" }

    private func connection(for bulb: Bulb) throws -> (base: String, token: String, entity: String) {
        guard let base = serverURL, let token = secrets.get(Self.tokenKey) else {
            throw DriverError.notConfigured("Home Assistant isn't connected. Open Settings ▸ Drivers ▸ Home Assistant.")
        }
        guard let entity = bulb.native["entity"] else { throw DriverError.notConfigured("\(bulb.name) needs to be added again.") }
        return (base, token, entity)
    }

    private func request(_ method: Method, base: String, token: String, path: String, body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: base + path) else { throw DriverError.notConfigured("Bad Home Assistant address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")      // the token only ever travels in this header
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw DriverError.authentication("Home Assistant rejected the access token. Create a new long-lived token and connect again.")
        case 404: throw DriverError.rejected("Home Assistant doesn't know that light any more. Remove it and search again.")
        default: throw DriverError.unreachable("Home Assistant answered with HTTP \(response.statusCode).")
        }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? [:]
    }
}
