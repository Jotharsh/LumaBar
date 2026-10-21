import Foundation

public enum DriverError: Error, Equatable, LocalizedError {
    /// The device didn't answer or the connection failed.
    case unreachable(String)
    /// macOS refused the connection before it left the Mac. Almost always the Local Network permission.
    case localNetworkBlocked(String)
    /// The device answered but refused the command.
    case rejected(String)
    /// Credentials are missing or wrong (token, local key, pairing).
    case authentication(String)
    /// The driver needs setup before it can talk to this bulb.
    case notConfigured(String)
    /// This bulb can't do that.
    case unsupported(String)
    /// The device sent something that didn't follow its protocol.
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let m), .localNetworkBlocked(let m), .rejected(let m), .authentication(let m),
             .notConfigured(let m), .unsupported(let m), .protocolError(let m):
            return m
        }
    }
}

/// Guidance shown for one brand: what to check when a bulb can't be reached, and how to set it up.
public struct DriverHelp: Equatable, Sendable {
    public var driverName: String
    /// One clear sentence for the "can't reach it" card.
    public var unreachable: String
    public var checks: [String]
    /// Setup steps, shown in Settings ▸ Drivers.
    public var setup: [String]

    public init(driverName: String, unreachable: String, checks: [String] = [], setup: [String] = []) {
        self.driverName = driverName
        self.unreachable = unreachable
        self.checks = checks
        self.setup = setup
    }
}

/// One brand's way of finding and controlling bulbs. The store, UI and automations only ever see this.
///
/// Drivers implement `apply(_:to:)`, which takes a combined command (power + brightness + colour in
/// one go, as the app's sliders and presets produce them). The single-purpose methods have defaults
/// built on it, so a driver only overrides them if it can do better.
public protocol BulbDriver: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var brand: String { get }
    var help: DriverHelp { get }
    /// Scenes this brand offers; empty unless bulbs report `.scenes`.
    var scenes: [LightScene] { get }
    /// Whether `probe(host:)` can identify a bulb from just its IP address.
    var supportsManualIP: Bool { get }
    /// Whether the driver is ready to talk to bulbs (e.g. a Home Assistant token has been entered).
    var isConfigured: Bool { get }

    /// Finds bulbs this driver can reach. Never throws: no bulbs found is an empty list.
    func discover() async -> [Bulb]
    /// Identifies the bulb at a given address (manual add).
    func probe(host: String) async throws -> Bulb

    func getState(of bulb: Bulb) async throws -> BulbState
    func apply(_ command: LightCommand, to bulb: Bulb) async throws

    func setPower(_ on: Bool, for bulb: Bulb) async throws
    func setBrightness(_ percent: Int, for bulb: Bulb) async throws
    func setColorTemp(_ kelvin: Int, for bulb: Bulb) async throws
    func setColor(_ rgb: RGB, for bulb: Bulb) async throws
    /// Optional: only meaningful for bulbs with the `scenes` capability.
    func setScene(_ scene: LightScene, speed: Int?, for bulb: Bulb) async throws
    /// Called when the user removes a bulb, so a driver can delete any secrets it stored for it.
    func forget(_ bulb: Bulb)
}

extension BulbDriver {
    public var scenes: [LightScene] { [] }
    public var supportsManualIP: Bool { false }
    public var isConfigured: Bool { true }

    public func forget(_ bulb: Bulb) {}

    public func probe(host: String) async throws -> Bulb {
        throw DriverError.unsupported("\(displayName) bulbs can't be added by IP address.")
    }

    public func setPower(_ on: Bool, for bulb: Bulb) async throws {
        try await apply(.power(on), to: bulb)
    }

    public func setBrightness(_ percent: Int, for bulb: Bulb) async throws {
        try await apply(LightCommand(state: true, dimming: percent), to: bulb)
    }

    public func setColorTemp(_ kelvin: Int, for bulb: Bulb) async throws {
        try await apply(LightCommand(state: true, temp: kelvin), to: bulb)
    }

    public func setColor(_ rgb: RGB, for bulb: Bulb) async throws {
        try await apply(LightCommand(state: true, rgb: rgb), to: bulb)
    }

    public func setScene(_ scene: LightScene, speed: Int?, for bulb: Bulb) async throws {
        guard bulb.capabilities.contains(.scenes) else {
            throw DriverError.unsupported("\(bulb.name) doesn't support scenes.")
        }
        try await apply(LightCommand(state: true, sceneId: scene.id, speed: speed), to: bulb)
    }
}
