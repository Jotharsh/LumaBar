import Foundation
import LumaBarCore

/// A scriptable driver: no network, records every command it receives.
final class MockDriver: BulbDriver, @unchecked Sendable {
    let id: String
    let displayName: String
    let brand: String
    var help: DriverHelp
    var scenes: [LightScene]
    var isConfigured = true
    var supportsManualIP = false

    private let lock = NSLock()
    private var _bulbs: [Bulb]
    private var _applied: [(bulbID: String, command: LightCommand)] = []
    private var _reachable = true
    private var _state = BulbState(isOn: true, dimming: 50, temperature: 3000)

    init(id: String, brand: String? = nil, bulbs: [Bulb] = [], scenes: [LightScene] = []) {
        self.id = id
        self.displayName = brand ?? id.capitalized
        self.brand = brand ?? id.capitalized
        self.help = DriverHelp(driverName: brand ?? id.capitalized, unreachable: "Fix \(id) like this.", checks: ["\(id) check"])
        self._bulbs = bulbs
        self.scenes = scenes
    }

    var applied: [(bulbID: String, command: LightCommand)] { lock.lock(); defer { lock.unlock() }; return _applied }
    func setReachable(_ value: Bool) { lock.lock(); _reachable = value; lock.unlock() }
    func setState(_ state: BulbState) { lock.lock(); _state = state; lock.unlock() }
    func setBulbs(_ bulbs: [Bulb]) { lock.lock(); _bulbs = bulbs; lock.unlock() }

    func discover() async -> [Bulb] { lock.lock(); defer { lock.unlock() }; return _reachable ? _bulbs : [] }

    func probe(host: String) async throws -> Bulb {
        lock.lock(); defer { lock.unlock() }
        guard supportsManualIP, _reachable, let bulb = _bulbs.first(where: { $0.address == host }) else {
            throw DriverError.unreachable("no answer")
        }
        return bulb
    }

    func getState(of bulb: Bulb) async throws -> BulbState {
        lock.lock(); defer { lock.unlock() }
        guard _reachable else { throw DriverError.unreachable("offline") }
        return _state
    }

    func apply(_ command: LightCommand, to bulb: Bulb) async throws {
        lock.lock(); defer { lock.unlock() }
        guard _reachable else { throw DriverError.unreachable("offline") }
        _applied.append((bulb.id, command))
    }

    var forgotten: [String] { lock.lock(); defer { lock.unlock() }; return _forgotten }
    private var _forgotten: [String] = []
    func forget(_ bulb: Bulb) { lock.lock(); _forgotten.append(bulb.id); lock.unlock() }
}

func mockBulb(_ driver: String, _ n: String, caps: DeviceCapabilities, name: String? = nil, address: String = "10.0.0.1") -> Bulb {
    Bulb(id: "\(driver):\(n)", name: name ?? "\(driver) \(n)", brand: driver.capitalized, driverID: driver,
         capabilities: caps, address: address)
}
