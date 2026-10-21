import XCTest
@testable import LumaBarCore

final class DriverFoundationTests: XCTestCase {
    // MARK: Bulb model and migration

    func testBulbSavedBeforeDriversExistedStillLoads() throws {
        let legacy = #"[{"mac":"a8bb50aabbcc","ip":"192.168.1.20","name":"Desk lamp"}]"#
        let bulbs = try JSONDecoder().decode([Bulb].self, from: Data(legacy.utf8))

        XCTAssertEqual(bulbs.count, 1)
        XCTAssertEqual(bulbs[0].id, "wiz:a8bb50aabbcc")
        XCTAssertEqual(bulbs[0].driverID, "wiz")
        XCTAssertEqual(bulbs[0].brand, "WiZ")
        XCTAssertEqual(bulbs[0].address, "192.168.1.20")
        XCTAssertEqual(bulbs[0].name, "Desk lamp")
        XCTAssertTrue(bulbs[0].capabilities.contains(.scenes))
    }

    func testBulbRoundTrips() throws {
        let bulb = Bulb(id: "yeelight:0x1", name: "Lamp", brand: "Yeelight", driverID: "yeelight",
                        capabilities: [.power, .brightness], address: "10.0.0.5", native: ["port": "55443"])
        let decoded = try JSONDecoder().decode(Bulb.self, from: JSONEncoder().encode(bulb))
        XCTAssertEqual(decoded, bulb)
    }

    func testBulbNeverSerialisesSecrets() throws {
        // Secrets are referenced by key from the Keychain; the model has no field for them.
        let bulb = Bulb(id: "tuya:abc", name: "T", brand: "Tuya", driverID: "tuya", capabilities: .fullColor,
                        address: "10.0.0.9", native: ["version": "3.4"])
        let json = String(decoding: try JSONEncoder().encode(bulb), as: UTF8.self).lowercased()
        XCTAssertFalse(json.contains("localkey") || json.contains("token") || json.contains("password"))
    }

    // MARK: Capability filtering

    func testWhiteOnlyBulbDropsColourAndScenes() {
        let command = LightCommand(state: true, dimming: 50, temp: 3000, rgb: RGB(r: 1, g: 2, b: 3), sceneId: 4, speed: 100)
        let filtered = command.filtered(for: [.power, .brightness, .colorTemp])
        XCTAssertEqual(filtered?.dimming, 50)
        XCTAssertEqual(filtered?.temp, 3000)
        XCTAssertNil(filtered?.rgb)
        XCTAssertNil(filtered?.sceneId)
        XCTAssertNil(filtered?.speed)
    }

    func testDimmableOnlyBulbKeepsJustPowerAndBrightness() {
        let filtered = LightCommand(state: true, dimming: 40, temp: 3000).filtered(for: [.power, .brightness])
        XCTAssertEqual(filtered, LightCommand(state: true, dimming: 40))
    }

    func testCommandBecomesNilWhenNothingSupported() {
        XCTAssertNil(LightCommand.color(RGB(r: 255, g: 0, b: 0)).filtered(for: [.power, .brightness]))
        XCTAssertNil(LightCommand.scene(3).filtered(for: .fullColor))
    }

    func testFullCapabilitiesLeaveCommandUntouched() {
        let command = LightCommand(state: true, dimming: 50, temp: 3000)
        XCTAssertEqual(command.filtered(for: [.power, .brightness, .colorTemp, .color, .scenes]), command)
    }

    // MARK: Secrets

    func testInMemorySecretStore() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(store.get("k"))
        try store.set("v", for: "k")
        XCTAssertEqual(store.get("k"), "v")
        try store.set(nil, for: "k")
        XCTAssertNil(store.get("k"))
    }

    func testKeychainStoreRoundTripUpdateAndDelete() throws {
        let store = KeychainSecretStore(service: "LumaBarTests.\(UUID().uuidString)")
        defer { try? store.set(nil, for: "token") }
        do {
            try store.set("first", for: "token")
            XCTAssertEqual(store.get("token"), "first")
            try store.set("second", for: "token")
            XCTAssertEqual(store.get("token"), "second")
            try store.set(nil, for: "token")
            XCTAssertNil(store.get("token"))
        } catch let error as SecretStoreError where error.status == -25308 || error.status == -34018 {
            throw XCTSkip("Keychain unavailable in this environment (status \(error.status))")
        }
    }
}
