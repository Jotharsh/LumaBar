import XCTest
@testable import LumaBarCore

final class WizMessageTests: XCTestCase {
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testSetPilotPowerOn() throws {
        let json = WizMessage.setPilot(.power(true))
        XCTAssertEqual(string(json), #"{"method":"setPilot","params":{"state":true}}"#)
    }

    func testSetPilotOmitsUnsetFields() throws {
        let params = try XCTUnwrap(try object(WizMessage.setPilot(.brightness(50)))["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["dimming"])
        XCTAssertEqual(params["dimming"] as? Int, 50)
    }

    func testSetPilotColour() throws {
        let json = WizMessage.setPilot(.color(RGB(r: 255, g: 0, b: 10), dimming: 80))
        XCTAssertEqual(string(json), #"{"method":"setPilot","params":{"b":10,"dimming":80,"g":0,"r":255}}"#)
    }

    func testSetPilotScene() throws {
        let params = try XCTUnwrap(try object(WizMessage.setPilot(.scene(11)))["params"] as? [String: Any])
        XCTAssertEqual(params["sceneId"] as? Int, 11)
    }

    func testDimmingAndTemperatureAreClamped() throws {
        XCTAssertEqual(LightCommand.brightness(0).dimming, 10)
        XCTAssertEqual(LightCommand.brightness(500).dimming, 100)
        XCTAssertEqual(LightCommand.temperature(1000).temp, 2200)
        XCTAssertEqual(LightCommand.temperature(9000).temp, 6500)
        let rgb = RGB(r: -5, g: 300, b: 128)
        XCTAssertEqual([rgb.r, rgb.g, rgb.b], [0, 255, 128])
    }

    func testGetPilot() throws {
        XCTAssertEqual(string(WizMessage.getPilot), #"{"method":"getPilot"}"#)
    }

    func testRegistration() throws {
        let json = try object(WizMessage.registration(phoneIP: "192.168.1.20"))
        XCTAssertEqual(json["method"] as? String, "registration")
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        XCTAssertEqual(params["phoneMac"] as? String, "AABBCCDDEEFF")
        XCTAssertEqual(params["register"] as? Bool, false)
        XCTAssertEqual(params["phoneIp"] as? String, "192.168.1.20")
        XCTAssertEqual(params["id"] as? String, "1")
    }

    // MARK: merging

    func testMergeNewerFieldsWin() {
        let merged = LightCommand(state: true, dimming: 30).merged(with: .brightness(60))
        XCTAssertEqual(merged, LightCommand(state: true, dimming: 60))
    }

    func testMergeTemperatureReplacesColour() {
        let colour = LightCommand.color(RGB(r: 1, g: 2, b: 3), dimming: 40)
        let merged = colour.merged(with: .temperature(3000))
        XCTAssertEqual(merged.temp, 3000)
        XCTAssertNil(merged.rgb)
        XCTAssertEqual(merged.dimming, 40)
    }

    func testMergeColourReplacesTemperature() {
        let merged = LightCommand.temperature(3000).merged(with: .color(RGB(r: 9, g: 8, b: 7)))
        XCTAssertNil(merged.temp)
        XCTAssertEqual(merged.rgb, RGB(r: 9, g: 8, b: 7))
    }

    // MARK: responses and state

    func testParseGetPilotWhiteMode() throws {
        let reply = #"{"method":"getPilot","env":"pro","result":{"mac":"a8bb50aabbcc","rssi":-60,"state":true,"sceneId":0,"temp":2700,"dimming":42}}"#
        let state = try XCTUnwrap(try WizMessage.parseResponse(Data(reply.utf8)).bulbState)
        XCTAssertEqual(state, BulbState(isOn: true, dimming: 42, temperature: 2700))
    }

    func testParseGetPilotColourMode() throws {
        let reply = #"{"method":"getPilot","result":{"mac":"a8bb50aabbcc","state":true,"sceneId":0,"r":255,"g":10,"b":0,"c":0,"w":0,"dimming":70}}"#
        let state = try XCTUnwrap(try WizMessage.parseResponse(Data(reply.utf8)).bulbState)
        XCTAssertEqual(state.rgb, RGB(r: 255, g: 10, b: 0))
        XCTAssertNil(state.temperature)
    }

    func testParseRegistrationReply() throws {
        let reply = #"{"method":"registration","env":"pro","result":{"mac":"a8bb50aabbcc","success":true}}"#
        let response = try WizMessage.parseResponse(Data(reply.utf8))
        XCTAssertEqual(response.result?.mac, "a8bb50aabbcc")
        XCTAssertNil(response.bulbState)
    }

    func testParseGarbageThrows() {
        XCTAssertThrowsError(try WizMessage.parseResponse(Data("nope".utf8)))
    }

    func testRestoreParams() {
        XCTAssertEqual(BulbState(isOn: false, dimming: 50).restoreParams(), .power(false))
        XCTAssertEqual(BulbState(isOn: true, dimming: 50, temperature: 3000).restoreParams(),
                       LightCommand(state: true, dimming: 50, temp: 3000))
        XCTAssertEqual(BulbState(isOn: true, dimming: 80, rgb: RGB(r: 1, g: 2, b: 3)).restoreParams(),
                       LightCommand(state: true, dimming: 80, rgb: RGB(r: 1, g: 2, b: 3)))
        XCTAssertEqual(BulbState(isOn: true, dimming: 80, temperature: 2700, sceneId: 6).restoreParams(),
                       LightCommand(state: true, dimming: 80, sceneId: 6))
    }

    func testPresetParams() {
        let preset = Preset(name: "X", brightness: 20, temperature: 2500)
        XCTAssertEqual(preset.command, LightCommand(state: true, dimming: 20, temp: 2500))
    }
}

final class SceneTests: XCTestCase {
    func testCatalogCoversScenes1To32WithUniqueNames() {
        XCTAssertEqual(LightScene.wiz.map(\.id), Array(1...32))
        XCTAssertEqual(Set(LightScene.wiz.map(\.name)).count, 32)
        XCTAssertTrue(LightScene.wiz.allSatisfy { !$0.name.isEmpty })
    }

    func testKnownSceneNames() {
        XCTAssertEqual(LightScene.wizScene(id: 1)?.name, "Ocean")
        XCTAssertEqual(LightScene.wizScene(id: 4)?.name, "Party")
        XCTAssertEqual(LightScene.wizScene(id: 32)?.name, "Steampunk")
        XCTAssertNil(LightScene.wizScene(id: 33))
    }

    func testSceneWithSpeedJSON() {
        let json = String(decoding: WizMessage.setPilot(LightCommand(state: true, sceneId: 4, speed: 120)), as: UTF8.self)
        XCTAssertEqual(json, #"{"method":"setPilot","params":{"sceneId":4,"speed":120,"state":true}}"#)
    }

    func testSpeedIsClamped() {
        XCTAssertEqual(LightCommand.scene(1, speed: 1).speed, 10)
        XCTAssertEqual(LightCommand.scene(1, speed: 999).speed, 200)
    }

    func testSpeedOnlyChangeKeepsTheScene() {
        let merged = LightCommand.scene(4, speed: 50).merged(with: LightCommand(speed: 150))
        XCTAssertEqual(merged.sceneId, 4)
        XCTAssertEqual(merged.speed, 150)
    }

    func testColourOrWhiteLeavesSceneMode() {
        let scene = LightCommand.scene(4, speed: 50)
        XCTAssertNil(scene.merged(with: .temperature(3000)).sceneId)
        XCTAssertNil(scene.merged(with: .temperature(3000)).speed)
        XCTAssertNil(scene.merged(with: .color(RGB(r: 1, g: 2, b: 3))).sceneId)
    }

    func testGetPilotInSceneModeReportsSceneAndSpeed() throws {
        let reply = #"{"method":"getPilot","result":{"mac":"a8bb50aabbcc","state":true,"sceneId":4,"speed":120,"dimming":80}}"#
        let state = try XCTUnwrap(try WizMessage.parseResponse(Data(reply.utf8)).bulbState)
        XCTAssertEqual(state.sceneId, 4)
        XCTAssertEqual(state.speed, 120)
        XCTAssertEqual(state.restoreParams(), LightCommand(state: true, dimming: 80, sceneId: 4, speed: 120))
    }

    func testSaturation() {
        XCTAssertEqual(ColorMath.saturation(of: RGB(r: 255, g: 255, b: 255)), 0)
        XCTAssertEqual(ColorMath.saturation(of: RGB(r: 255, g: 0, b: 0)), 1)
        XCTAssertEqual(ColorMath.saturation(of: RGB(r: 255, g: 128, b: 128)), 0.498, accuracy: 0.01)
    }

    func testHelpMentionsTheSettingByName() {
        XCTAssertTrue(WizHelp.localControl.contains("Allow local communication"))
        XCTAssertTrue(WizHelp.localControl.contains("same Wi-Fi"))
    }
}
