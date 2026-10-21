import XCTest
@testable import LumaBarCore

/// A Hue Bridge speaking the v1 REST API, behind a mock HTTP transport.
final class FakeHueBridge: HTTPTransport, @unchecked Sendable {
    let bridgeID = "001788FFFE123456"
    let appKey = "newdeveloper-abc123"
    private let lock = NSLock()
    private var _requests: [(method: String, path: String, body: [String: Any]?)] = []
    private var _lights: [String: [String: Any]]
    private var pollsUntilButton: Int
    private var polls = 0
    var reachable = true
    var rejectKey = false

    init(pollsUntilButton: Int = 0, lights: [String: [String: Any]]? = nil) {
        self.pollsUntilButton = pollsUntilButton
        self._lights = lights ?? FakeHueBridge.sampleLights
    }

    var requests: [(method: String, path: String, body: [String: Any]?)] { lock.lock(); defer { lock.unlock() }; return _requests }
    var pairingAttempts: Int { lock.lock(); defer { lock.unlock() }; return polls }
    func light(_ n: String) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return _lights[n] }

    static let sampleLights: [String: [String: Any]] = [
        "1": ["state": ["on": true, "bri": 144, "hue": 13088, "sat": 212, "xy": [0.5128, 0.4147], "ct": 467, "alert": "none", "effect": "none", "colormode": "xy", "reachable": true],
              "type": "Extended color light", "name": "Hue color lamp 1", "modelid": "LCT001", "uniqueid": "00:17:88:01:00:d4:12:08-0a"],
        "2": ["state": ["on": false, "bri": 254, "ct": 250, "colormode": "ct", "reachable": true],
              "type": "Color temperature light", "name": "Ambiance", "modelid": "LTW001", "uniqueid": "00:17:88:01:00:aa:00:02-0b"],
        "3": ["state": ["on": true, "bri": 100, "reachable": false],
              "type": "Dimmable light", "name": "Hall", "modelid": "LWB006", "uniqueid": "00:17:88:01:00:aa:00:03-0b"],
    ]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard reachable else { throw DriverError.unreachable("The request timed out.") }
        let path = request.url?.path ?? ""
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        lock.lock(); _requests.append((request.httpMethod ?? "GET", path, body)); lock.unlock()

        func respond(_ object: Any, status: Int = 200) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func error(_ type: Int, _ description: String) throws -> (Data, HTTPURLResponse) {
            try respond([["error": ["type": type, "address": path, "description": description]]])
        }

        if path == "/api/config" { return try respond(["name": "Philips hue", "bridgeid": bridgeID.lowercased(), "apiversion": "1.41.0"]) }
        if path == "/api", request.httpMethod == "POST" {
            lock.lock(); polls += 1; let ready = polls > pollsUntilButton; lock.unlock()
            return ready ? try respond([["success": ["username": appKey]]]) : try error(101, "link button not pressed")
        }

        let parts = path.split(separator: "/").map(String.init)      // ["api", key, "lights", "1", "state"]
        guard parts.count >= 3, parts[0] == "api" else { return try respond([:], status: 404) }
        if rejectKey || parts[1] != appKey { return try error(1, "unauthorized user") }
        guard parts[2] == "lights" else { return try respond([:], status: 404) }

        lock.lock(); defer { lock.unlock() }
        if parts.count == 3 { return try respond(_lights) }
        let number = parts[3]
        guard var light = _lights[number] else { return try error(3, "resource, /lights/\(number), not available") }
        if parts.count == 4 { return try respond(light) }

        // PUT /lights/<n>/state
        var state = light["state"] as? [String: Any] ?? [:]
        var results: [[String: Any]] = []
        for (key, value) in body ?? [:] {
            if key != "on", key != "transitiontime", state["on"] as? Bool == false, body?["on"] as? Bool != true {
                results.append(["error": ["type": 201, "address": "/lights/\(number)/state/\(key)",
                                          "description": "parameter, \(key), is not modifiable. Device is set to off."]])
            } else {
                state[key] = value
                results.append(["success": ["/lights/\(number)/state/\(key)": value]])
            }
        }
        if body?["ct"] != nil { state["colormode"] = "ct" }
        if body?["hue"] != nil { state["colormode"] = "hs" }
        light["state"] = state
        _lights[number] = light
        return try respond(results)
    }
}

final class HueDriverTests: XCTestCase {
    private var secrets = InMemorySecretStore()
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        secrets = InMemorySecretStore()
        suite = "LumaBarTests.hue.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    final class Sleeps: @unchecked Sendable {
        private let lock = NSLock(); private var _d: [TimeInterval] = []
        func record(_ x: TimeInterval) { lock.lock(); _d.append(x); lock.unlock() }
        var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _d }
    }
    struct StubFinder: HueBridgeFinding { var bridges: [HueBridge]; func findBridges() async -> [HueBridge] { bridges } }

    private func driver(_ bridge: FakeHueBridge, finder: HueBridgeFinding = StubFinder(bridges: []), sleeps: Sleeps = Sleeps()) -> HueDriver {
        HueDriver(secrets: secrets, transport: bridge, book: HueBridgeBook(defaults: defaults), finder: finder, sleeper: { sleeps.record($0) })
    }

    private func paired(_ bridge: FakeHueBridge, finder: HueBridgeFinding = StubFinder(bridges: []), sleeps: Sleeps = Sleeps()) async throws -> (HueDriver, [Bulb]) {
        let d = driver(bridge, finder: finder, sleeps: sleeps)
        let hueBridge = try await d.pair(host: "192.168.1.2", timeout: 10, pollInterval: 1)
        return (d, try await d.lights(on: hueBridge))
    }

    // MARK: Pairing

    func testIdentifyReadsTheBridgeWithoutPairing() async throws {
        let bridge = try await driver(FakeHueBridge()).identify(host: "192.168.1.2")
        XCTAssertEqual(bridge.id, "001788FFFE123456")
        XCTAssertEqual(bridge.name, "Philips hue")
    }

    func testAddressThatIsNotABridgeIsReportedClearly() async {
        final class NotABridge: HTTPTransport {
            func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) { (Data("{}".utf8), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        }
        let d = HueDriver(secrets: secrets, transport: NotABridge(), book: HueBridgeBook(defaults: defaults))
        do { _ = try await d.identify(host: "1.2.3.4"); XCTFail("expected failure") }
        catch { guard case .protocolError(let m) = error as? DriverError else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("Hue Bridge")) }
    }

    func testPressButtonPairingWaitsThenStoresTheKeySecurely() async throws {
        let bridge = FakeHueBridge(pollsUntilButton: 3)
        let sleeps = Sleeps()
        let d = driver(bridge, sleeps: sleeps)

        let paired = try await d.pair(host: "192.168.1.2", timeout: 30, pollInterval: 2)

        XCTAssertEqual(bridge.pairingAttempts, 4, "three 'link button not pressed' answers, then success")
        XCTAssertEqual(sleeps.delays, [2, 2, 2])
        XCTAssertEqual(paired.id, "001788FFFE123456")
        XCTAssertEqual(secrets.get("hue.key.001788FFFE123456"), bridge.appKey)
        XCTAssertEqual(d.book.all.map(\.id), ["001788FFFE123456"], "the bridge is remembered")
        let saved = String(decoding: defaults.data(forKey: "lumabar.hue.bridges") ?? Data(), as: UTF8.self)
        XCTAssertFalse(saved.contains(bridge.appKey), "the key must not be in UserDefaults")
    }

    func testPairingGivesUpWithAClearInstructionIfTheButtonIsNeverPressed() async {
        let bridge = FakeHueBridge(pollsUntilButton: 1000)
        let d = driver(bridge)
        do {
            _ = try await d.pair(host: "192.168.1.2", timeout: 6, pollInterval: 2)
            XCTFail("expected failure")
        } catch {
            guard case .notConfigured(let message) = error as? DriverError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("link button"), message)
        }
        XCTAssertNil(secrets.get("hue.key.001788FFFE123456"))
        XCTAssertTrue(d.book.all.isEmpty)
    }

    func testUnreachableBridgeFailsPairingAsUnreachable() async {
        let bridge = FakeHueBridge(); bridge.reachable = false
        do { _ = try await driver(bridge).pair(host: "192.168.1.2"); XCTFail("expected failure") }
        catch { guard case .unreachable = error as? DriverError else { return XCTFail("\(error)") } }
    }

    // MARK: Lights

    func testListsLightsWithCapabilitiesFromTheirType() async throws {
        let (_, bulbs) = try await paired(FakeHueBridge())
        XCTAssertEqual(bulbs.map(\.id), ["hue:001788FFFE123456:1", "hue:001788FFFE123456:2", "hue:001788FFFE123456:3"])
        XCTAssertEqual(bulbs.map(\.name), ["Hue color lamp 1", "Ambiance", "Hall"])
        XCTAssertEqual(bulbs[0].capabilities, [.power, .brightness, .colorTemp, .color])
        XCTAssertEqual(bulbs[1].capabilities, [.power, .brightness, .colorTemp])
        XCTAssertEqual(bulbs[2].capabilities, [.power, .brightness])
        XCTAssertEqual(bulbs[0].address, "192.168.1.2")
    }

    func testBulbsNeverContainTheKey() async throws {
        let bridge = FakeHueBridge()
        let (_, bulbs) = try await paired(bridge)
        let json = String(decoding: try JSONEncoder().encode(bulbs), as: UTF8.self)
        XCTAssertFalse(json.contains(bridge.appKey))
    }

    func testCapabilityTable() {
        XCTAssertEqual(HueDriver.capabilities(forType: "Color light"), [.power, .brightness, .color])
        XCTAssertEqual(HueDriver.capabilities(forType: "On/Off plug-in unit"), [.power])
    }

    func testDiscoverListsLightsOfPairedBridges() async throws {
        let (d, _) = try await paired(FakeHueBridge())
        let found = await d.discover()
        XCTAssertEqual(found.count, 3)
    }

    func testDiscoverFollowsABridgeThatMovedToANewAddress() async throws {
        let bridge = FakeHueBridge()
        let moved = HueBridge(id: "001788FFFE123456", host: "192.168.1.77")
        // First pair at the old address, then the old address stops answering unless the host matches the new one.
        final class AddressRouter: HTTPTransport, @unchecked Sendable {
            let inner: FakeHueBridge; let liveHost: String
            init(_ inner: FakeHueBridge, liveHost: String) { self.inner = inner; self.liveHost = liveHost }
            func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
                guard r.url?.host == liveHost else { throw DriverError.unreachable("No route to host") }
                return try await inner.send(r)
            }
        }
        let first = HueDriver(secrets: secrets, transport: AddressRouter(bridge, liveHost: "192.168.1.2"), book: HueBridgeBook(defaults: defaults))
        _ = try await first.pair(host: "192.168.1.2", timeout: 1, pollInterval: 1)

        let d = HueDriver(secrets: secrets, transport: AddressRouter(bridge, liveHost: "192.168.1.77"), book: HueBridgeBook(defaults: defaults),
                          finder: StubFinder(bridges: [moved]))
        let found = await d.discover()

        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { $0.address == "192.168.1.77" })
        XCTAssertEqual(d.book.all.first?.host, "192.168.1.77", "the new address is remembered")
    }

    // MARK: State

    func testReadsColourTemperatureAndColourModes() async throws {
        let (d, bulbs) = try await paired(FakeHueBridge())
        let colour = try await d.getState(of: bulbs[0])              // xy mode with hue/sat present
        XCTAssertTrue(colour.isOn)
        XCTAssertNotNil(colour.rgb)
        XCTAssertEqual(colour.dimming, 57)                            // 144/254

        let white = try await d.getState(of: bulbs[1])
        XCTAssertEqual(white, BulbState(isOn: false, dimming: 100, temperature: 4000))   // ct 250 mired
    }

    func testALightTheBridgeCannotReachIsUnreachable() async throws {
        let (d, bulbs) = try await paired(FakeHueBridge())
        do { _ = try await d.getState(of: bulbs[2]); XCTFail("expected failure") }
        catch {
            guard case .unreachable(let m) = error as? DriverError else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("power"), m)
        }
    }

    // MARK: Control

    func testPowerBrightnessAndTemperatureCommands() async throws {
        let bridge = FakeHueBridge()
        let (d, bulbs) = try await paired(bridge)

        try await d.apply(LightCommand(state: true, dimming: 60, temp: 4000), to: bulbs[1])
        let last = try XCTUnwrap(bridge.requests.last)
        XCTAssertEqual(last.method, "PUT")
        XCTAssertTrue(last.path.hasSuffix("/lights/2/state"))
        XCTAssertEqual(last.body?["on"] as? Bool, true)
        XCTAssertEqual(last.body?["bri"] as? Int, 153)               // 60% of 253, plus 1
        XCTAssertEqual(last.body?["ct"] as? Int, 250)                // 1,000,000 / 4000 mired
        XCTAssertNil(last.body?["hue"])
    }

    func testColourCommandSendsHueAndSaturation() async throws {
        let bridge = FakeHueBridge()
        let (d, bulbs) = try await paired(bridge)
        try await d.apply(LightCommand(state: true, rgb: RGB(r: 0, g: 255, b: 0)), to: bulbs[0])
        let body = try XCTUnwrap(bridge.requests.last?.body)
        XCTAssertEqual(body["hue"] as? Int, 21845)
        XCTAssertEqual(body["sat"] as? Int, 254)
    }

    func testPowerOffSendsOnlyOnFalse() async throws {
        let bridge = FakeHueBridge()
        let (d, bulbs) = try await paired(bridge)
        try await d.apply(LightCommand(state: false, dimming: 50), to: bulbs[0])
        XCTAssertEqual(bridge.requests.last?.body as? [String: Bool], ["on": false])
    }

    func testBridgeRefusalIsReportedAsARejection() async throws {
        let bridge = FakeHueBridge()
        let (d, bulbs) = try await paired(bridge)
        do {
            try await d.apply(LightCommand(dimming: 40), to: bulbs[1])      // light 2 is off; brightness alone isn't allowed
            XCTFail("expected failure")
        } catch {
            guard case .rejected(let m) = error as? DriverError else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("is set to off"), m)
        }
    }

    func testARevokedKeyAsksToPairAgain() async throws {
        let bridge = FakeHueBridge()
        let (d, bulbs) = try await paired(bridge)
        bridge.rejectKey = true
        do { _ = try await d.getState(of: bulbs[0]); XCTFail("expected failure") }
        catch {
            guard case .authentication(let m) = error as? DriverError else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("Pair it again"), m)
        }
    }

    func testControlWithoutPairingExplainsHowToPair() async {
        let d = driver(FakeHueBridge())
        let bulb = Bulb(id: "hue:X:1", name: "Lamp", brand: "Hue", driverID: "hue", capabilities: .fullColor, address: "1.2.3.4", native: ["bridge": "X", "light": "1"])
        do { _ = try await d.getState(of: bulb); XCTFail("expected failure") }
        catch { guard case .authentication(let m) = error as? DriverError else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("pair")) }
    }

    func testUnreachableBridgeDuringControl() async throws {
        let bridge = FakeHueBridge()
        let (d, bulbs) = try await paired(bridge)
        bridge.reachable = false
        do { try await d.apply(.power(true), to: bulbs[0]); XCTFail("expected failure") }
        catch { guard case .unreachable = error as? DriverError else { return XCTFail("\(error)") } }
    }

    func testCommandsAreSpacedForTheBridge() async throws {
        let bridge = FakeHueBridge()
        let sleeps = Sleeps()
        let (d, bulbs) = try await paired(bridge, sleeps: sleeps)
        let pairingSleeps = sleeps.delays.count
        for p in [20, 40, 60] { try await d.apply(LightCommand(state: true, dimming: p), to: bulbs[0]) }
        let spacing = Array(sleeps.delays.dropFirst(pairingSleeps))
        XCTAssertEqual(spacing.count, 2, "the first goes straight out; the next two wait ~100 ms apart")
        XCTAssertEqual(spacing[0], 0.1, accuracy: 0.05)
    }

    func testUnpairingRemovesTheKeyAndTheBridge() async throws {
        let (d, _) = try await paired(FakeHueBridge())
        let bridge = try XCTUnwrap(d.book.all.first)
        d.unpair(bridge)
        XCTAssertNil(secrets.get("hue.key.\(bridge.id)"))
        XCTAssertTrue(d.book.all.isEmpty)
    }

    func testConversions() {
        XCTAssertEqual(HueDriver.brightness(fromPercent: 100), 254)
        XCTAssertEqual(HueDriver.brightness(fromPercent: 1), 4)
        XCTAssertEqual(HueDriver.mired(fromKelvin: 2700), 370)
        XCTAssertEqual(HueDriver.mired(fromKelvin: 6500), 154)
        XCTAssertEqual(HueDriver.mired(fromKelvin: 1000), 500, "clamped to the bridge's range")
    }

    // MARK: Discovery and help

    func testPhilipsLookupParsesTheirAnswerAndIsSilentOnFailure() async {
        final class Canned: HTTPTransport, @unchecked Sendable {
            let body: String; let status: Int
            init(_ b: String, _ s: Int = 200) { body = b; status = s }
            func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) { (Data(body.utf8), HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
        }
        let ok = await PhilipsCloudHueFinder(transport: Canned(#"[{"id":"001788fffe123456","internalipaddress":"192.168.1.2","port":443}]"#)).findBridges()
        XCTAssertEqual(ok, [HueBridge(id: "001788FFFE123456", host: "192.168.1.2")])
        let down = await PhilipsCloudHueFinder(transport: Canned("{}", 503)).findBridges()
        XCTAssertTrue(down.isEmpty)
    }

    func testHelpExplainsTheLinkButton() {
        let help = driver(FakeHueBridge()).help
        XCTAssertTrue(help.setup.contains { $0.contains("link button") })
        XCTAssertTrue(help.unreachable.contains("Hue Bridge"))
    }
}
