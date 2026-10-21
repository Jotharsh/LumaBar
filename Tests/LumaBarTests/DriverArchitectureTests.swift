import XCTest
import LumaBarCore
@testable import LumaBar

final class RegistryTests: XCTestCase {
    func testDiscoveryMergesEnabledDriversIntoOneList() async {
        let a = MockDriver(id: "alpha", bulbs: [mockBulb("alpha", "1", caps: .fullColor, name: "Zed"), mockBulb("alpha", "2", caps: .fullColor, name: "Amy")])
        let b = MockDriver(id: "beta", bulbs: [mockBulb("beta", "9", caps: [.power, .brightness])])
        let registry = DriverRegistry(drivers: [a, b])

        let found = await registry.discoverAll(enabled: ["alpha", "beta"])

        XCTAssertEqual(found.map(\.id), ["alpha:2", "alpha:1", "beta:9"], "ordered by driver, then name")
    }

    func testDisabledAndUnconfiguredDriversAreSkipped() async {
        let a = MockDriver(id: "alpha", bulbs: [mockBulb("alpha", "1", caps: .fullColor)])
        let b = MockDriver(id: "beta", bulbs: [mockBulb("beta", "1", caps: .fullColor)])
        let c = MockDriver(id: "gamma", bulbs: [mockBulb("gamma", "1", caps: .fullColor)])
        c.isConfigured = false
        let registry = DriverRegistry(drivers: [a, b, c])

        let found = await registry.discoverAll(enabled: ["alpha", "gamma"])

        XCTAssertEqual(found.map(\.id), ["alpha:1"])
    }

    func testDuplicateIDsAcrossDriversCollapse() async {
        let a = MockDriver(id: "alpha", bulbs: [mockBulb("alpha", "1", caps: .fullColor)])
        let again = MockDriver(id: "alpha2", bulbs: [mockBulb("alpha", "1", caps: .fullColor)])
        let found = await DriverRegistry(drivers: [a, again]).discoverAll(enabled: ["alpha", "alpha2"])
        XCTAssertEqual(found.count, 1)
    }

    func testOneFailingDriverDoesNotHideTheOthers() async {
        let a = MockDriver(id: "alpha", bulbs: [mockBulb("alpha", "1", caps: .fullColor)])
        a.setReachable(false)
        let b = MockDriver(id: "beta", bulbs: [mockBulb("beta", "1", caps: .fullColor)])
        let found = await DriverRegistry(drivers: [a, b]).discoverAll(enabled: ["alpha", "beta"])
        XCTAssertEqual(found.map(\.id), ["beta:1"])
    }

    func testProbeAsksOnlyDriversThatSupportManualIP() async {
        let a = MockDriver(id: "alpha", bulbs: [mockBulb("alpha", "1", caps: .fullColor, address: "10.0.0.7")])
        a.supportsManualIP = true
        let b = MockDriver(id: "beta", bulbs: [mockBulb("beta", "1", caps: .fullColor, address: "10.0.0.7")])
        let registry = DriverRegistry(drivers: [a, b])

        let result = await registry.probe(host: "10.0.0.7", enabled: ["alpha", "beta"])

        XCTAssertEqual(result.bulb?.id, "alpha:1")
        XCTAssertEqual(result.tried.map(\.id), ["alpha"])
    }
}

@MainActor
final class CapabilityAwareStoreTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "LumaBarTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func settle() async { try? await Task.sleep(nanoseconds: 300_000_000) }

    private func store(_ drivers: [MockDriver], bulbs: [Bulb], enabled: Set<String>? = nil) -> BulbStore {
        let store = BulbStore(registry: DriverRegistry(drivers: drivers), defaults: defaults)
        for id in enabled ?? Set(drivers.map(\.id)) { store.setDriver(id, enabled: true) }
        for bulb in bulbs { store.addSavedBulbForTesting(bulb) }
        return store
    }

    func testCapabilitiesAreTheUnionOfTheSelectedBulbs() {
        let white = mockBulb("alpha", "1", caps: [.power, .brightness, .colorTemp])
        let colour = mockBulb("beta", "1", caps: [.power, .brightness, .color])
        let s = store([MockDriver(id: "alpha"), MockDriver(id: "beta")], bulbs: [white, colour])

        XCTAssertEqual(s.capabilities, [.power, .brightness, .colorTemp, .color])

        s.selection = white.id
        XCTAssertEqual(s.capabilities, [.power, .brightness, .colorTemp], "no colour control for a white-only bulb")
        s.selection = colour.id
        XCTAssertFalse(s.capabilities.contains(.colorTemp), "no warmth control for a colour-only bulb")
    }

    func testDimmableOnlyBulbShowsNothingButPowerAndBrightness() {
        let dim = mockBulb("alpha", "1", caps: [.power, .brightness])
        let s = store([MockDriver(id: "alpha")], bulbs: [dim])
        XCTAssertEqual(s.capabilities, [.power, .brightness])
        XCTAssertTrue(s.availableScenes.isEmpty)
    }

    func testCommandsToAMixedGroupAreFilteredPerBulb() async {
        let white = mockBulb("alpha", "1", caps: [.power, .brightness, .colorTemp])
        let colour = mockBulb("beta", "1", caps: .fullColor)
        let a = MockDriver(id: "alpha"), b = MockDriver(id: "beta")
        let s = store([a, b], bulbs: [white, colour])

        s.send(LightCommand(state: true, dimming: 60, rgb: RGB(r: 255, g: 0, b: 0)))
        await settle()

        XCTAssertEqual(a.applied.map(\.command), [LightCommand(state: true, dimming: 60)], "white bulb never receives colour")
        XCTAssertEqual(b.applied.map(\.command), [LightCommand(state: true, dimming: 60, rgb: RGB(r: 255, g: 0, b: 0))])
    }

    func testColourIsDroppedForBulbsThatCannotShowIt() async {
        let white = mockBulb("alpha", "1", caps: [.power, .brightness])
        let a = MockDriver(id: "alpha")
        let s = store([a], bulbs: [white])

        s.applyColor(RGB(r: 0, g: 255, b: 0))
        await settle()

        XCTAssertTrue(a.applied.allSatisfy { $0.command.rgb == nil }, "colour never reaches a bulb that can't show it")
        XCTAssertEqual(a.applied.map(\.command), [.power(true)], "but touching a control still turns the light on")
    }

    func testScenesComeOnlyFromSceneCapableBulbs() {
        let scenes = [LightScene(id: 1, name: "One", isDynamic: true)]
        let withScenes = mockBulb("alpha", "1", caps: [.power, .brightness, .scenes])
        let without = mockBulb("beta", "1", caps: .fullColor)
        let s = store([MockDriver(id: "alpha", scenes: scenes), MockDriver(id: "beta")], bulbs: [withScenes, without])

        XCTAssertEqual(s.availableScenes.map(\.name), ["One"])
        s.selection = without.id
        XCTAssertTrue(s.availableScenes.isEmpty)
    }

    func testDisablingADriverHidesAndStopsControllingItsBulbs() async {
        let a = MockDriver(id: "alpha"), b = MockDriver(id: "beta")
        let s = store([a, b], bulbs: [mockBulb("alpha", "1", caps: .fullColor), mockBulb("beta", "1", caps: .fullColor)])
        XCTAssertEqual(s.bulbs.count, 2)

        s.setDriver("beta", enabled: false)
        XCTAssertEqual(s.bulbs.map(\.id), ["alpha:1"])
        XCTAssertEqual(s.savedBulbs.count, 2, "disabled bulbs are kept, just inactive")

        s.sendToAll(.power(false))
        await settle()
        XCTAssertEqual(a.applied.count, 1)
        XCTAssertTrue(b.applied.isEmpty)
    }

    func testOnlyWizIsEnabledOnFirstRun() {
        let s = BulbStore(registry: DriverRegistry(drivers: [MockDriver(id: "wiz"), MockDriver(id: "tuya")]), defaults: defaults)
        XCTAssertEqual(s.enabledDrivers, ["wiz"])
    }

    func testEnabledDriversAreRememberedBetweenLaunches() {
        let registry = DriverRegistry(drivers: [MockDriver(id: "wiz"), MockDriver(id: "tuya")])
        let first = BulbStore(registry: registry, defaults: defaults)
        first.setDriver("tuya", enabled: true)
        XCTAssertEqual(BulbStore(registry: registry, defaults: defaults).enabledDrivers, ["wiz", "tuya"])
    }

    func testDiscoveryAcrossDriversMergesIntoTheStoreAndKeepsUserNames() async {
        let a = MockDriver(id: "alpha", bulbs: [mockBulb("alpha", "1", caps: .fullColor, address: "10.0.0.1")])
        let b = MockDriver(id: "beta", bulbs: [mockBulb("beta", "1", caps: [.power, .brightness])])
        let s = store([a, b], bulbs: [])

        await s.discover()
        XCTAssertEqual(s.bulbs.map(\.id), ["alpha:1", "beta:1"])

        s.rename(s.bulbs[0], to: "Mine")
        a.setBulbs([mockBulb("alpha", "1", caps: .fullColor, address: "10.0.0.99")])
        await s.discover()
        XCTAssertEqual(s.bulbs[0].name, "Mine")
        XCTAssertEqual(s.bulbs[0].address, "10.0.0.99", "address updates when the bulb moves")
    }

    func testUnreachableHelpIsSpecificToTheBrandThatFailed() async {
        let a = MockDriver(id: "alpha"), b = MockDriver(id: "beta")
        a.setReachable(false)
        let s = store([a, b], bulbs: [mockBulb("alpha", "1", caps: .fullColor)])
        s.selection = "alpha:1"

        await s.refresh()

        XCTAssertTrue(s.showConnectionHelp)
        XCTAssertEqual(s.connectionHelp.map(\.driverName), ["Alpha"])
        XCTAssertEqual(s.connectionHelp.first?.unreachable, "Fix alpha like this.")
    }

    func testHelpListsEveryEnabledBrandWhenNothingIsFound() async {
        let s = store([MockDriver(id: "alpha"), MockDriver(id: "beta")], bulbs: [])
        await s.discover()
        XCTAssertTrue(s.showConnectionHelp)
        XCTAssertEqual(s.connectionHelp.map(\.driverName), ["Alpha", "Beta"])
        XCTAssertEqual(s.connectionHeadline, "No bulbs found")
    }

    func testAuthenticationErrorsAreMessagesNotOfflineCards() async {
        final class AuthFailing: BulbDriver, @unchecked Sendable {
            let id = "auth", displayName = "Auth", brand = "Auth"
            let help = DriverHelp(driverName: "Auth", unreachable: "x")
            func discover() async -> [Bulb] { [] }
            func getState(of bulb: Bulb) async throws -> BulbState { throw DriverError.authentication("Token rejected") }
            func apply(_ command: LightCommand, to bulb: Bulb) async throws { throw DriverError.authentication("Token rejected") }
        }
        let driver = AuthFailing()
        let s = BulbStore(registry: DriverRegistry(drivers: [driver]), defaults: defaults)
        s.setDriver("auth", enabled: true)
        let bulb = mockBulb("auth", "1", caps: .fullColor, name: "Lamp")
        s.addSavedBulbForTesting(bulb)

        s.setPower(true)
        await settle()

        XCTAssertEqual(s.lastError, "Lamp: Token rejected")
        XCTAssertFalse(s.offline.contains(bulb.id), "a bad token is not 'unreachable'")
    }

    func testRemovingABulbLetsItsDriverForgetSecrets() {
        let a = MockDriver(id: "alpha")
        let bulb = mockBulb("alpha", "1", caps: .fullColor)
        let s = store([a], bulbs: [bulb])
        s.remove(bulb)
        XCTAssertEqual(a.forgotten, ["alpha:1"])
        XCTAssertTrue(s.savedBulbs.isEmpty)
    }
}
