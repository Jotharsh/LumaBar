import XCTest
import Network
import LumaBarCore
@testable import LumaBar

/// A pretend bulb on localhost that records what it receives and answers like a WiZ bulb.
private final class FakeBulb: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeBulb")
    private let lock = NSLock()
    private var _received: [String] = []
    var pilotReply: String

    var received: [String] { lock.lock(); defer { lock.unlock() }; return _received }
    func commands(containing text: String) -> [String] { received.filter { $0.contains(text) } }

    init(port: UInt16, pilotReply: String = #"{"method":"getPilot","env":"pro","result":{"mac":"a8bb50aabbcc","state":true,"sceneId":0,"temp":3000,"dimming":65}}"#) throws {
        self.pilotReply = pilotReply
        listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [unowned self] connection in
            connection.start(queue: queue)
            serve(connection)
        }
    }

    func start() async {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state, !once.done { once.done = true; c.resume() }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.receiveMessage { [unowned self] data, _, _, error in
            if let data {
                let text = String(decoding: data, as: UTF8.self)
                lock.lock(); _received.append(text); lock.unlock()
                let reply = text.contains("getPilot") ? pilotReply : #"{"method":"setPilot","env":"pro","result":{"success":true}}"#
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            }
            if error == nil { serve(connection) }
        }
    }
}

@MainActor
final class BulbStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "LumaBarTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore(port: UInt16) -> BulbStore {
        let wiz = WizDriver(client: WizClient(bulbPort: port, listenPort: port + 1, timeout: 0.3))
        return BulbStore(registry: DriverRegistry(drivers: [wiz]), defaults: defaults)
    }

    private func wizBulb(mac: String = "a8bb50aabbcc", ip: String = "127.0.0.1", name: String = "Desk lamp") -> Bulb {
        Bulb(id: "wiz:\(mac)", name: name, brand: "WiZ", driverID: "wiz",
             capabilities: [.power, .brightness, .colorTemp, .color, .scenes], address: ip, native: ["mac": mac])
    }

    private func storeWithBulb(port: UInt16) async -> BulbStore {
        let store = makeStore(port: port)
        _ = await store.addBulb(ip: "127.0.0.1")
        return store
    }

    /// Waits (briefly) for the store's serialised command queue to flush.
    private func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

    // MARK: Scenes

    func testApplyingAnAnimatedSceneSendsSceneAndSpeed() async throws {
        let fake = try FakeBulb(port: 48930); await fake.start(); defer { fake.stop() }
        let store = await storeWithBulb(port: 48930)
        store.sceneSpeed = 120

        store.applyScene(try XCTUnwrap(LightScene.wizScene(id: 4)))   // Party
        await settle()

        XCTAssertEqual(fake.commands(containing: "sceneId"), [#"{"method":"setPilot","params":{"sceneId":4,"speed":120,"state":true}}"#])
        XCTAssertEqual(store.activeScene?.name, "Party")
    }

    func testStaticSceneDoesNotSendSpeed() async throws {
        let fake = try FakeBulb(port: 48931); await fake.start(); defer { fake.stop() }
        let store = await storeWithBulb(port: 48931)

        store.applyScene(try XCTUnwrap(LightScene.wizScene(id: 12)))  // Daylight
        await settle()

        XCTAssertEqual(fake.commands(containing: "sceneId"), [#"{"method":"setPilot","params":{"sceneId":12,"state":true}}"#])
    }

    func testSpeedSliderChangesSpeedOfRunningScene() async throws {
        let fake = try FakeBulb(port: 48932); await fake.start(); defer { fake.stop() }
        let store = await storeWithBulb(port: 48932)
        store.applyScene(try XCTUnwrap(LightScene.wizScene(id: 1)))   // Ocean
        await settle()

        store.setSceneSpeed(30)
        store.commitSceneSpeed()
        await settle()

        XCTAssertEqual(fake.received.last, #"{"method":"setPilot","params":{"sceneId":1,"speed":30,"state":true}}"#)
    }

    func testSwitchingToWarmWhiteLeavesSceneMode() async throws {
        let fake = try FakeBulb(port: 48933); await fake.start(); defer { fake.stop() }
        let store = await storeWithBulb(port: 48933)
        store.applyScene(try XCTUnwrap(LightScene.wizScene(id: 4)))
        await settle()
        XCTAssertNotNil(store.activeScene)

        store.setTemperature(2700); store.commitTemperature()
        await settle()

        XCTAssertNil(store.activeScene)
    }

    func testRefreshShowsTheSceneTheBulbIsRunning() async throws {
        let fake = try FakeBulb(port: 48934, pilotReply: #"{"method":"getPilot","result":{"mac":"a8bb50aabbcc","state":true,"sceneId":5,"speed":150,"dimming":40}}"#)
        await fake.start(); defer { fake.stop() }
        let store = await storeWithBulb(port: 48934)

        await store.refresh()

        XCTAssertEqual(store.activeScene?.name, "Fireplace")
        XCTAssertEqual(store.sceneSpeed, 150)
        XCTAssertEqual(store.brightness, 40)
    }

    // MARK: Basic controls

    func testPowerBrightnessWarmthAndColourCommands() async throws {
        let fake = try FakeBulb(port: 48935); await fake.start(); defer { fake.stop() }
        let store = await storeWithBulb(port: 48935)

        store.setPower(false); await settle()
        XCTAssertEqual(fake.received.last, #"{"method":"setPilot","params":{"state":false}}"#)

        store.setBrightness(55); store.commitBrightness(); await settle()
        XCTAssertEqual(fake.received.last, #"{"method":"setPilot","params":{"dimming":55,"state":true}}"#)

        store.setTemperature(4000); store.commitTemperature(); await settle()
        XCTAssertEqual(fake.received.last, #"{"method":"setPilot","params":{"state":true,"temp":4000}}"#)

        store.setHue(0); store.setSaturation(1); store.commitHue(); await settle()
        XCTAssertEqual(fake.received.last, #"{"method":"setPilot","params":{"b":0,"g":0,"r":255,"state":true}}"#)

        store.setSaturation(0.5); store.commitHue(); await settle()   // pastel
        XCTAssertEqual(fake.received.last, #"{"method":"setPilot","params":{"b":128,"g":128,"r":255,"state":true}}"#)
    }

    func testDraggingASliderIsThrottledButTheFinalValueAlwaysArrives() async throws {
        let fake = try FakeBulb(port: 48936); await fake.start(); defer { fake.stop() }
        let store = await storeWithBulb(port: 48936)

        // 50 updates in ~0.5 s, like a fast drag.
        for i in 0..<50 {
            store.setBrightness(10 + Double(i))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        store.setBrightness(77)
        store.commitBrightness()
        await settle()

        let sent = fake.commands(containing: "dimming")
        XCTAssertLessThan(sent.count, 20, "about 10 per second, not one per slider tick")
        XCTAssertEqual(sent.last, #"{"method":"setPilot","params":{"dimming":77,"state":true}}"#)
    }

    // MARK: Discovery, memory, unreachable

    func testAddedBulbsAreRememberedBetweenLaunches() async throws {
        let fake = try FakeBulb(port: 48937); await fake.start(); defer { fake.stop() }
        let first = await storeWithBulb(port: 48937)
        XCTAssertEqual(first.bulbs.map(\.id), ["wiz:a8bb50aabbcc"])
        first.rename(first.bulbs[0], to: "Desk lamp")

        let relaunched = makeStore(port: 48937)   // same defaults, fresh store
        XCTAssertEqual(relaunched.bulbs.map(\.name), ["Desk lamp"])
        XCTAssertEqual(relaunched.bulbs.map(\.address), ["127.0.0.1"])
    }

    func testUnreachableBulbShowsConnectionHelp() async throws {
        let store = makeStore(port: 48938)            // nothing is listening there
        store.addSavedBulbForTesting(wizBulb())

        await store.refresh()

        XCTAssertTrue(store.showConnectionHelp)
        XCTAssertEqual(store.connectionHeadline, "Can't reach Desk lamp")
        XCTAssertTrue(WizHelp.localControl.contains("Allow local communication"))
    }

    func testFailedCommandAlsoFlagsTheBulbUnreachable() async throws {
        let store = makeStore(port: 48939)
        store.addSavedBulbForTesting(wizBulb())

        store.setPower(true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // timeout + one retry

        XCTAssertTrue(store.showConnectionHelp)
    }

    func testConnectionHelpClearsOnceTheBulbAnswers() async throws {
        let fake = try FakeBulb(port: 48940)          // not started yet: unreachable
        let store = makeStore(port: 48940)
        store.addSavedBulbForTesting(wizBulb())
        await store.refresh()
        XCTAssertTrue(store.showConnectionHelp)

        await fake.start(); defer { fake.stop() }
        await store.refresh()

        XCTAssertFalse(store.showConnectionHelp)
    }

    func testEmptySearchShowsConnectionHelpAndManualAddRecovers() async throws {
        let store = makeStore(port: 48941)
        await store.discover()                        // no bulb anywhere
        XCTAssertTrue(store.showConnectionHelp)
        XCTAssertEqual(store.connectionHeadline, "No WiZ bulbs found")

        let fake = try FakeBulb(port: 48941); await fake.start(); defer { fake.stop() }
        let error = await store.addBulb(ip: "127.0.0.1")

        XCTAssertNil(error)
        XCTAssertFalse(store.showConnectionHelp)
        XCTAssertEqual(store.bulbs.count, 1)
    }

    func testAddingAnUnreachableIPGivesTheHelpMessage() async throws {
        let store = makeStore(port: 48942)
        let message = await store.addBulb(ip: "127.0.0.1")
        XCTAssertTrue(message?.contains("Allow local communication") == true, message ?? "nil")
        XCTAssertTrue(store.bulbs.isEmpty)
    }

    func testAddingANonIPIsRejectedWithoutNetworkTraffic() async throws {
        let store = makeStore(port: 48943)
        let message = await store.addBulb(ip: "not-an-ip")
        XCTAssertEqual(message, "That doesn't look like an IPv4 address.")
    }
}
