import XCTest
@testable import LumaBarCore

/// A Home Assistant server's REST API behind a mock HTTP transport.
final class FakeHomeAssistant: HTTPTransport, @unchecked Sendable {
    let token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.secret-token-value"
    private let lock = NSLock()
    private var _requests: [(method: String, url: String, authorization: String?, body: [String: Any]?)] = []
    private var entities: [[String: Any]]
    var reachable = true
    var serverError: Int?

    init(entities: [[String: Any]]? = nil) { self.entities = entities ?? FakeHomeAssistant.sample }

    var requests: [(method: String, url: String, authorization: String?, body: [String: Any]?)] { lock.lock(); defer { lock.unlock() }; return _requests }

    static let sample: [[String: Any]] = [
        ["entity_id": "light.kitchen", "state": "on", "attributes": [
            "friendly_name": "Kitchen", "supported_color_modes": ["color_temp", "xy"], "color_mode": "color_temp",
            "brightness": 204, "color_temp_kelvin": 3000]],
        ["entity_id": "light.desk", "state": "off", "attributes": [
            "friendly_name": "Desk lamp", "supported_color_modes": ["brightness"]]],
        ["entity_id": "light.porch", "state": "on", "attributes": ["friendly_name": "Porch", "supported_color_modes": ["onoff"]]],
        ["entity_id": "light.old_bulb", "state": "on", "attributes": ["friendly_name": "Old bulb", "supported_features": 19]],
        ["entity_id": "light.gone", "state": "unavailable", "attributes": ["friendly_name": "Gone", "supported_color_modes": ["rgb"]]],
        ["entity_id": "light.party", "state": "on", "attributes": [
            "friendly_name": "Party", "supported_color_modes": ["hs"], "color_mode": "hs", "brightness": 128, "rgb_color": [127, 0, 0]]],
        ["entity_id": "switch.fan", "state": "on", "attributes": ["friendly_name": "Fan"]],
        ["entity_id": "sensor.temp", "state": "21", "attributes": [:]],
    ]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard reachable else { throw DriverError.unreachable("The request timed out.") }
        let url = request.url!
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        lock.lock(); _requests.append((request.httpMethod ?? "GET", url.absoluteString, request.value(forHTTPHeaderField: "Authorization"), body)); lock.unlock()

        func respond(_ object: Any, _ status: Int = 200) -> (Data, HTTPURLResponse) {
            ((try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data(),
             HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if let serverError { return respond([:], serverError) }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else { return respond(["message": "401: Unauthorized"], 401) }

        var path = url.path
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }       // Foundation versions differ on trailing slashes
        if path == "/api" { return respond(["message": "API running."]) }
        if path == "/api/states" { return respond(entities) }
        if path.hasPrefix("/api/states/") {
            let id = String(path.dropFirst("/api/states/".count))
            lock.lock(); defer { lock.unlock() }
            return entities.first { $0["entity_id"] as? String == id }.map { respond($0) } ?? respond(["message": "Entity not found."], 404)
        }
        if path.hasPrefix("/api/services/light/") { return respond([[String: Any]]()) }
        return respond([:], 404)
    }
}

final class HomeAssistantDriverTests: XCTestCase {
    private var secrets = InMemorySecretStore()
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        secrets = InMemorySecretStore()
        suite = "LumaBarTests.ha.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func driver(_ server: FakeHomeAssistant) -> HomeAssistantDriver { HomeAssistantDriver(secrets: secrets, transport: server, defaults: defaults) }

    private func connected(_ server: FakeHomeAssistant) async throws -> (HomeAssistantDriver, [Bulb]) {
        let d = driver(server)
        return (d, try await d.connect(url: "http://homeassistant.local:8123", token: server.token))
    }

    func bulb(_ d: [Bulb], _ entity: String) throws -> Bulb { try XCTUnwrap(d.first { $0.native["entity"] == entity }) }

    // MARK: Connecting

    func testConnectImportsOnlyLightEntitiesAndSavesCredentialsSafely() async throws {
        let server = FakeHomeAssistant()
        let (d, bulbs) = try await connected(server)

        XCTAssertEqual(bulbs.map(\.name), ["Desk lamp", "Gone", "Kitchen", "Old bulb", "Party", "Porch"], "lights only, sorted; no switches or sensors")
        XCTAssertTrue(d.isConfigured)
        XCTAssertEqual(secrets.get("homeassistant.token"), server.token)
        XCTAssertEqual(d.serverURL, "http://homeassistant.local:8123")

        // The token must not be in UserDefaults, in any saved bulb, or in any URL or request body.
        let allDefaults = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(allDefaults.contains(server.token))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(bulbs), as: UTF8.self).contains(server.token))
        XCTAssertTrue(server.requests.allSatisfy { !$0.url.contains(server.token) && !String(describing: $0.body ?? [:]).contains(server.token) })
    }

    func testEveryRequestCarriesTheBearerToken() async throws {
        let server = FakeHomeAssistant()
        let (d, bulbs) = try await connected(server)
        try await d.apply(.power(true), to: bulb(bulbs, "light.kitchen"))
        XCTAssertTrue(server.requests.allSatisfy { $0.authorization == "Bearer \(server.token)" })
    }

    func testWrongTokenIsAnAuthenticationErrorAndNothingIsSaved() async {
        let server = FakeHomeAssistant()
        let d = driver(server)
        do { _ = try await d.connect(url: "http://ha.local:8123", token: "wrong"); XCTFail("expected failure") }
        catch { guard case .authentication(let m) = error as? DriverError else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("token")) }
        XCTAssertNil(secrets.get("homeassistant.token"))
        XCTAssertNil(d.serverURL)
        XCTAssertFalse(d.isConfigured)
    }

    func testUnreachableServer() async {
        let server = FakeHomeAssistant(); server.reachable = false
        do { _ = try await driver(server).connect(url: "http://ha.local:8123", token: server.token); XCTFail("expected failure") }
        catch { guard case .unreachable = error as? DriverError else { return XCTFail("\(error)") } }
    }

    func testAddressIsValidatedAndTidied() async throws {
        let server = FakeHomeAssistant()
        let d = driver(server)
        for bad in ["", "homeassistant.local:8123", "ftp://ha.local", "http://"] {
            do { _ = try await d.connect(url: bad, token: server.token); XCTFail("accepted \(bad)") }
            catch { guard case .notConfigured = error as? DriverError else { return XCTFail("\(bad): \(error)") } }
        }
        _ = try await d.connect(url: "  http://ha.local:8123///  ", token: " \(server.token)\n")
        XCTAssertEqual(d.serverURL, "http://ha.local:8123", "whitespace and trailing slashes are removed")
    }

    func testEmptyTokenIsRejectedBeforeAnyRequest() async {
        let server = FakeHomeAssistant()
        do { _ = try await driver(server).connect(url: "http://ha.local:8123", token: "  "); XCTFail("expected failure") }
        catch { guard case .notConfigured = error as? DriverError else { return XCTFail("\(error)") } }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testDisconnectRemovesTokenAndAddress() async throws {
        let (d, _) = try await connected(FakeHomeAssistant())
        d.disconnect()
        XCTAssertNil(secrets.get("homeassistant.token"))
        XCTAssertNil(d.serverURL)
        XCTAssertFalse(d.isConfigured)
    }

    // MARK: Capabilities

    func testCapabilitiesFromSupportedColourModes() async throws {
        let (_, bulbs) = try await connected(FakeHomeAssistant())
        XCTAssertEqual(try bulb(bulbs, "light.kitchen").capabilities, [.power, .brightness, .colorTemp, .color])
        XCTAssertEqual(try bulb(bulbs, "light.desk").capabilities, [.power, .brightness])
        XCTAssertEqual(try bulb(bulbs, "light.porch").capabilities, [.power], "an on/off light has no brightness control")
        XCTAssertEqual(try bulb(bulbs, "light.party").capabilities, [.power, .brightness, .color])
    }

    func testOlderServersUseSupportedFeatures() async throws {
        let (_, bulbs) = try await connected(FakeHomeAssistant())
        XCTAssertEqual(try bulb(bulbs, "light.old_bulb").capabilities, [.power, .brightness, .colorTemp, .color])   // 1 + 2 + 16
    }

    // MARK: State

    func testReadsColourTemperatureState() async throws {
        let (d, bulbs) = try await connected(FakeHomeAssistant())
        let state = try await d.getState(of: bulb(bulbs, "light.kitchen"))
        XCTAssertEqual(state, BulbState(isOn: true, dimming: 80, temperature: 3000))
    }

    func testReadsColourStateAndNormalisesItToFullIntensity() async throws {
        let (d, bulbs) = try await connected(FakeHomeAssistant())
        let state = try await d.getState(of: bulb(bulbs, "light.party"))
        XCTAssertEqual(state.rgb, RGB(r: 255, g: 0, b: 0), "HA reports the colour at its current brightness")
        XCTAssertEqual(state.dimming, 50)
    }

    func testOffLight() async throws {
        let (d, bulbs) = try await connected(FakeHomeAssistant())
        let state = try await d.getState(of: bulb(bulbs, "light.desk"))
        XCTAssertFalse(state.isOn)
    }

    func testUnavailableLightIsUnreachableWithAnExplanation() async throws {
        let (d, bulbs) = try await connected(FakeHomeAssistant())
        do { _ = try await d.getState(of: bulb(bulbs, "light.gone")); XCTFail("expected failure") }
        catch { guard case .unreachable(let m) = error as? DriverError else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("unavailable in Home Assistant")) }
    }

    // MARK: Control

    func testTurnOnWithBrightnessAndTemperature() async throws {
        let server = FakeHomeAssistant()
        let (d, bulbs) = try await connected(server)
        try await d.apply(LightCommand(state: true, dimming: 60, temp: 4000), to: bulb(bulbs, "light.kitchen"))
        let call = try XCTUnwrap(server.requests.last)
        XCTAssertEqual(call.method, "POST")
        XCTAssertTrue(call.url.hasSuffix("/api/services/light/turn_on"))
        XCTAssertEqual(call.body?["entity_id"] as? String, "light.kitchen")
        XCTAssertEqual(call.body?["brightness_pct"] as? Int, 60)
        XCTAssertEqual(call.body?["color_temp_kelvin"] as? Int, 4000)
        XCTAssertNil(call.body?["rgb_color"])
    }

    func testTurnOnWithColour() async throws {
        let server = FakeHomeAssistant()
        let (d, bulbs) = try await connected(server)
        try await d.apply(LightCommand(state: true, rgb: RGB(r: 255, g: 0, b: 128)), to: bulb(bulbs, "light.party"))
        XCTAssertEqual(server.requests.last?.body?["rgb_color"] as? [Int], [255, 0, 128])
    }

    func testTurnOffUsesTheTurnOffService() async throws {
        let server = FakeHomeAssistant()
        let (d, bulbs) = try await connected(server)
        try await d.apply(LightCommand(state: false, dimming: 50), to: bulb(bulbs, "light.kitchen"))
        let call = try XCTUnwrap(server.requests.last)
        XCTAssertTrue(call.url.hasSuffix("/api/services/light/turn_off"))
        XCTAssertEqual(call.body?["entity_id"] as? String, "light.kitchen")
        XCTAssertNil(call.body?["brightness_pct"])
    }

    func testEmptyCommandSendsNothing() async throws {
        let server = FakeHomeAssistant()
        let (d, bulbs) = try await connected(server)
        let before = server.requests.count
        try await d.apply(LightCommand(), to: bulb(bulbs, "light.kitchen"))
        XCTAssertEqual(server.requests.count, before)
    }

    func testRevokedTokenDuringControl() async throws {
        let server = FakeHomeAssistant()
        let (_, bulbs) = try await connected(server)
        secrets = InMemorySecretStore()
        try secrets.set("revoked", for: "homeassistant.token")
        let d = driver(server)
        do { try await d.apply(.power(true), to: bulb(bulbs, "light.kitchen")); XCTFail("expected failure") }
        catch { guard case .authentication = error as? DriverError else { return XCTFail("\(error)") } }
    }

    func testControlBeforeConnectingExplainsWhatToDo() async throws {
        let d = driver(FakeHomeAssistant())
        let orphan = Bulb(id: "homeassistant:light.x", name: "X", brand: "Home Assistant", driverID: "homeassistant", capabilities: .fullColor, address: "h", native: ["entity": "light.x"])
        do { _ = try await d.getState(of: orphan); XCTFail("expected failure") }
        catch { guard case .notConfigured(let m) = error as? DriverError else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("Settings")) }
    }

    func testServerErrorsAreReportedAsUnreachable() async throws {
        let server = FakeHomeAssistant()
        let (d, bulbs) = try await connected(server)
        server.serverError = 503
        do { _ = try await d.getState(of: bulb(bulbs, "light.kitchen")); XCTFail("expected failure") }
        catch { guard case .unreachable(let m) = error as? DriverError else { return XCTFail("\(error)") }; XCTAssertTrue(m.contains("503")) }
    }

    // MARK: Discovery and help

    func testDiscoverRefreshesTheListAndIsEmptyWhenNotConfigured() async throws {
        let before = await driver(FakeHomeAssistant()).discover()
        XCTAssertTrue(before.isEmpty)
        let (d, _) = try await connected(FakeHomeAssistant())
        let found = await d.discover()
        XCTAssertEqual(found.count, 6)
    }

    func testRegistrySkipsHomeAssistantUntilItIsConfigured() async {
        let d = driver(FakeHomeAssistant())
        let found = await DriverRegistry(drivers: [d]).discoverAll(enabled: ["homeassistant"])
        XCTAssertTrue(found.isEmpty)
    }

    func testHelpExplainsHowToCreateAToken() {
        let help = driver(FakeHomeAssistant()).help
        XCTAssertTrue(help.setup.contains { $0.contains("Long-lived access tokens") })
        XCTAssertTrue(help.unreachable.contains("token"))
    }
}
