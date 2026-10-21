import Foundation

public struct RGB: Codable, Equatable, Hashable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r.clamped(to: WizLimits.channel)
        self.g = g.clamped(to: WizLimits.channel)
        self.b = b.clamped(to: WizLimits.channel)
    }
}

/// A bulb from any brand. The UI and automations only ever deal with this.
public struct Bulb: Codable, Identifiable, Hashable, Sendable {
    /// Unique across brands: "<driverID>:<native id>", e.g. "wiz:a8bb50aabbcc".
    public var id: String
    public var name: String
    public var brand: String
    public var driverID: String
    public var capabilities: DeviceCapabilities
    /// Where the bulb is reached: an IP address or host.
    public var address: String
    /// Non-secret, driver-specific details (Tuya protocol version, Hue light number, ...).
    /// Secrets such as tokens and local keys never go here; they live in the Keychain.
    public var native: [String: String]

    public init(id: String, name: String, brand: String, driverID: String,
                capabilities: DeviceCapabilities, address: String, native: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.brand = brand
        self.driverID = driverID
        self.capabilities = capabilities
        self.address = address
        self.native = native
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, brand, driverID, capabilities, address, native
    }

    /// Bulbs saved before drivers existed were WiZ-only and stored as { mac, ip, name }.
    private enum LegacyKeys: String, CodingKey { case mac, ip, name }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            self.init(id: id,
                      name: try container.decode(String.self, forKey: .name),
                      brand: try container.decode(String.self, forKey: .brand),
                      driverID: try container.decode(String.self, forKey: .driverID),
                      capabilities: try container.decode(DeviceCapabilities.self, forKey: .capabilities),
                      address: try container.decode(String.self, forKey: .address),
                      native: try container.decodeIfPresent([String: String].self, forKey: .native) ?? [:])
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let mac = try legacy.decode(String.self, forKey: .mac)
            self.init(id: "wiz:\(mac)",
                      name: try legacy.decode(String.self, forKey: .name),
                      brand: "WiZ", driverID: "wiz",
                      capabilities: [.power, .brightness, .colorTemp, .color, .scenes],
                      address: try legacy.decode(String.self, forKey: .ip),
                      native: ["mac": mac])
        }
    }
}

/// What a bulb reports for `getPilot`.
public struct BulbState: Equatable, Sendable {
    public var isOn: Bool
    public var dimming: Int
    public var temperature: Int?
    public var rgb: RGB?
    public var sceneId: Int?
    public var speed: Int?

    public init(isOn: Bool, dimming: Int, temperature: Int? = nil, rgb: RGB? = nil, sceneId: Int? = nil, speed: Int? = nil) {
        self.isOn = isOn
        self.dimming = dimming
        self.temperature = temperature
        self.rgb = rgb
        self.sceneId = sceneId
        self.speed = speed
    }

    /// A command that puts a bulb back into this state.
    public func restoreParams() -> LightCommand {
        guard isOn else { return .power(false) }
        if let sceneId { return LightCommand(state: true, dimming: dimming, sceneId: sceneId, speed: speed) }
        if let rgb, temperature == nil { return LightCommand(state: true, dimming: dimming, rgb: rgb) }
        return LightCommand(state: true, dimming: dimming, temp: temperature ?? 2700)
    }
}

public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    public var brightness: Int
    public var temperature: Int
    /// When set, the preset is a colour instead of a white temperature.
    public var rgb: RGB?

    public init(id: String = UUID().uuidString, name: String, symbol: String = "lightbulb",
                brightness: Int, temperature: Int, rgb: RGB? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.brightness = brightness
        self.temperature = temperature
        self.rgb = rgb
    }

    public var command: LightCommand {
        if let rgb { return LightCommand(state: true, dimming: brightness, rgb: rgb) }
        return LightCommand(state: true, dimming: brightness, temp: temperature)
    }

    public static let videoCallID = "videoCall"

    public static let defaults: [Preset] = [
        Preset(id: "reading", name: "Reading", symbol: "book", brightness: 80, temperature: 4000),
        Preset(id: "movie", name: "Movie", symbol: "film", brightness: 15, temperature: 2400),
        Preset(id: "night", name: "Night", symbol: "moon", brightness: 10, temperature: 2200),
        Preset(id: "focus", name: "Focus", symbol: "scope", brightness: 100, temperature: 6000),
        Preset(id: videoCallID, name: "Video Call", symbol: "video", brightness: 90, temperature: 4500),
    ]
}
