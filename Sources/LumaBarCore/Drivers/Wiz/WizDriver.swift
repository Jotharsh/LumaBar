import Foundation

/// WiZ bulbs over local UDP. A thin adapter: all protocol work stays in `WizClient`, unchanged.
public final class WizDriver: BulbDriver {
    public static let driverID = "wiz"
    public let id = WizDriver.driverID
    public let displayName = "WiZ"
    public let brand = "WiZ"
    public let supportsManualIP = true
    public var scenes: [LightScene] { LightScene.wiz }

    public let client: WizClient

    public var help: DriverHelp {
        DriverHelp(
            driverName: "WiZ",
            unreachable: WizHelp.localControl,
            checks: WizHelp.moreChecks,
            setup: [
                "Set the bulb up in the WiZ app first.",
                "In the WiZ app, make sure \"Allow local communication\" is turned on (Settings ▸ Security).",
                "Keep your Mac on the same Wi-Fi as the bulb, then use Search Network."
            ])
    }

    public init(client: WizClient = WizClient()) {
        self.client = client
    }

    static let capabilities: DeviceCapabilities = [.power, .brightness, .colorTemp, .color, .scenes]

    private func bulb(mac: String, ip: String) -> Bulb {
        Bulb(id: "\(Self.driverID):\(mac)", name: "WiZ \(mac.suffix(6).uppercased())", brand: brand,
             driverID: Self.driverID, capabilities: Self.capabilities, address: ip, native: ["mac": mac])
    }

    public func discover() async -> [Bulb] {
        await client.discover().map { bulb(mac: $0.mac, ip: $0.ip) }
    }

    public func probe(host: String) async throws -> Bulb {
        do {
            let mac = try await client.identify(host: host) ?? host
            return bulb(mac: mac, ip: host)
        } catch {
            throw Self.translate(error)
        }
    }

    public func getState(of bulb: Bulb) async throws -> BulbState {
        do { return try await client.getPilot(host: bulb.address) } catch { throw Self.translate(error) }
    }

    public func apply(_ command: LightCommand, to bulb: Bulb) async throws {
        do { try await client.setPilot(command, host: bulb.address) } catch { throw Self.translate(error) }
    }

    static func translate(_ error: Error) -> Error {
        guard let wiz = error as? WizError else { return error }
        switch wiz {
        case .rejected(let reason): return DriverError.rejected(reason)
        case .invalidResponse: return DriverError.protocolError(wiz.localizedDescription)
        case .localNetworkBlocked: return DriverError.localNetworkBlocked(wiz.localizedDescription)
        case .timeout, .offline: return DriverError.unreachable(wiz.localizedDescription)
        }
    }
}
