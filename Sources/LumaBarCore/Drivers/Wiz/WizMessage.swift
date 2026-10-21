import Foundation

public enum WizLimits {
    public static let port: UInt16 = 38899
    public static let dimming = 10...100
    public static let temperature = 2200...6500
    public static let channel = 0...255
    public static let speed = 10...200
}

extension Int {
    public func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// The `params` object of a `setPilot` request. Every field is optional; only set fields are sent.
public struct LightCommand: Codable, Equatable, Sendable {
    public var state: Bool?
    public var dimming: Int?
    public var temp: Int?
    public var r: Int?
    public var g: Int?
    public var b: Int?
    public var sceneId: Int?
    /// Animation speed for dynamic scenes (10 slow ... 200 fast).
    public var speed: Int?

    /// Values are clamped to what the bulb accepts.
    public init(state: Bool? = nil, dimming: Int? = nil, temp: Int? = nil, rgb: RGB? = nil, sceneId: Int? = nil, speed: Int? = nil) {
        self.state = state
        self.dimming = dimming?.clamped(to: WizLimits.dimming)
        self.temp = temp?.clamped(to: WizLimits.temperature)
        self.r = rgb?.r
        self.g = rgb?.g
        self.b = rgb?.b
        self.sceneId = sceneId
        self.speed = speed?.clamped(to: WizLimits.speed)
    }

    public static func power(_ on: Bool) -> LightCommand { LightCommand(state: on) }
    public static func brightness(_ percent: Int) -> LightCommand { LightCommand(dimming: percent) }
    public static func temperature(_ kelvin: Int) -> LightCommand { LightCommand(temp: kelvin) }
    public static func color(_ rgb: RGB, dimming: Int? = nil) -> LightCommand { LightCommand(dimming: dimming, rgb: rgb) }
    public static func scene(_ id: Int, speed: Int? = nil) -> LightCommand { LightCommand(sceneId: id, speed: speed) }

    public var rgb: RGB? {
        guard let r, let g, let b else { return nil }
        return RGB(r: r, g: g, b: b)
    }

    /// True when the command sets nothing.
    public var isEmpty: Bool {
        state == nil && dimming == nil && temp == nil && r == nil && g == nil && b == nil && sceneId == nil && speed == nil
    }

    /// Drops whatever a bulb can't do (e.g. colour for a white-only bulb). Nil if nothing is left to send.
    public func filtered(for capabilities: DeviceCapabilities) -> LightCommand? {
        var c = self
        if !capabilities.contains(.power) { c.state = nil }
        if !capabilities.contains(.brightness) { c.dimming = nil }
        if !capabilities.contains(.colorTemp) { c.temp = nil }
        if !capabilities.contains(.color) { c.r = nil; c.g = nil; c.b = nil }
        if !capabilities.contains(.scenes) { c.sceneId = nil; c.speed = nil }
        return c.isEmpty ? nil : c
    }

    public func turningOn() -> LightCommand {
        var copy = self
        copy.state = true
        return copy
    }

    /// Combines two commands so a pending one can be replaced by a newer one.
    /// Newer fields win, and the three light "modes" (white temperature, RGB, scene) are mutually exclusive.
    public func merged(with newer: LightCommand) -> LightCommand {
        var result = self
        if let v = newer.state { result.state = v }
        if let v = newer.dimming { result.dimming = v }
        if newer.temp != nil {
            result.temp = newer.temp
            result.r = nil; result.g = nil; result.b = nil; result.sceneId = nil; result.speed = nil
        }
        if newer.rgb != nil {
            result.r = newer.r; result.g = newer.g; result.b = newer.b
            result.temp = nil; result.sceneId = nil; result.speed = nil
        }
        if newer.sceneId != nil {
            result.sceneId = newer.sceneId
            result.temp = nil; result.r = nil; result.g = nil; result.b = nil
            result.speed = newer.speed ?? result.speed
        }
        if let v = newer.speed { result.speed = v }
        return result
    }
}

/// Builders for the JSON datagrams sent to a bulb.
public enum WizMessage {
    private struct Request<P: Encodable>: Encodable {
        var method: String
        var params: P?
    }

    private struct Empty: Encodable {}

    private struct Registration: Encodable {
        var phoneMac: String
        var register: Bool
        var phoneIp: String
        var id: String
    }

    public static func setPilot(_ params: LightCommand) -> Data {
        encode(Request(method: "setPilot", params: params))
    }

    public static var getPilot: Data {
        encode(Request<Empty>(method: "getPilot", params: nil))
    }

    public static func registration(phoneIP: String, phoneMac: String = "AABBCCDDEEFF") -> Data {
        encode(Request(method: "registration",
                       params: Registration(phoneMac: phoneMac, register: false, phoneIp: phoneIP, id: "1")))
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain structs of strings/ints/bools cannot fail.
        return (try? encoder.encode(value)) ?? Data()
    }

    public static func parseResponse(_ data: Data) throws -> WizResponse {
        do {
            return try JSONDecoder().decode(WizResponse.self, from: data)
        } catch {
            throw WizError.invalidResponse
        }
    }
}

public struct WizResponse: Decodable, Sendable {
    public struct Result: Decodable, Sendable {
        public var mac: String?
        public var rssi: Int?
        public var state: Bool?
        public var sceneId: Int?
        public var speed: Int?
        public var temp: Int?
        public var dimming: Int?
        public var r: Int?
        public var g: Int?
        public var b: Int?
        public var success: Bool?
    }

    public struct Failure: Decodable, Sendable {
        public var code: Int?
        public var message: String?
    }

    public var method: String?
    public var env: String?
    public var result: Result?
    public var error: Failure?

    /// The bulb's current light state, if this is a `getPilot` reply.
    public var bulbState: BulbState? {
        guard let result, let on = result.state else { return nil }
        var rgb: RGB?
        if let r = result.r, let g = result.g, let b = result.b { rgb = RGB(r: r, g: g, b: b) }
        let scene = (result.sceneId ?? 0) == 0 ? nil : result.sceneId
        return BulbState(isOn: on, dimming: result.dimming ?? 100, temperature: result.temp, rgb: rgb, sceneId: scene, speed: result.speed)
    }
}

public enum WizError: Error, Equatable, LocalizedError {
    case timeout
    case offline(String)
    case invalidResponse
    case rejected(String)
    /// macOS is refusing the connection (usually the Local Network permission).
    case localNetworkBlocked

    public var errorDescription: String? {
        switch self {
        case .timeout: return "The bulb didn't respond."
        case .offline(let reason): return "Can't reach the bulb (\(reason))."
        case .invalidResponse: return "The bulb sent a reply LumaBar couldn't read."
        case .rejected(let reason): return "The bulb rejected the command: \(reason)"
        case .localNetworkBlocked: return "macOS is blocking LumaBar from your local network."
        }
    }
}
