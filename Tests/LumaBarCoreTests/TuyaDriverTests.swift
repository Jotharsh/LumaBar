import XCTest
@testable import LumaBarCore

/// Layout B: a typical RGB+CCT bulb (DPs 20-24).
private let rgbBulbDPS: [String: TuyaValue] = [
    "20": .bool(true), "21": .string("white"), "22": .int(500), "23": .int(500), "24": .string("000003e803e8"),
]

final class TuyaSessionTests: XCTestCase {
    private let key = Data("0123456789abcdef".utf8)

    private func session(_ device: FakeTuya, key: Data? = nil, version: TuyaVersion? = nil) -> TuyaSession {
        TuyaSession(channel: device.connect(), deviceID: device.deviceID, localKey: key ?? device.deviceKey, version: version ?? device.version)
    }

    func testVersion33QueryAndControl() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let s = session(device)
        let awaited1 = try await s.queryStatus()
        XCTAssertEqual(awaited1, rgbBulbDPS)

        try await s.setDPS(["20": .bool(false), "22": .int(250)])
        XCTAssertEqual(device.dps["20"], .bool(false))
        XCTAssertEqual(device.dps["22"], .int(250))
        XCTAssertEqual(device.commands.count, 1)
    }

    func testVersion34NegotiatesASessionKeyThenQueriesAndControls() async throws {
        let device = FakeTuya(version: .v34, dps: rgbBulbDPS)
        let s = session(device)
        try await s.negotiate()
        let awaited2 = try await s.queryStatus()
        XCTAssertEqual(awaited2, rgbBulbDPS)

        try await s.setDPS(["21": .string("colour"), "24": .string("0000 03e8 01f4".replacingOccurrences(of: " ", with: ""))])
        XCTAssertEqual(device.dps["21"], .string("colour"))
        XCTAssertEqual(device.dps["24"], .string("000003e801f4"))
    }

    func testVersion34WithAWrongKeyFailsTheHandshakeAsAnAuthenticationProblem() async {
        let device = FakeTuya(version: .v34, dps: rgbBulbDPS)
        let s = session(device, key: Data("fedcba9876543210".utf8))
        do {
            try await s.negotiate()
            XCTFail("expected the handshake to fail")
        } catch {
            guard case .authentication = error as? DriverError else { return XCTFail("\(error)") }
        }
    }

    func testVersion33WithAWrongKeyIsReportedAsAWrongKey() async {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let s = session(device, key: Data("fedcba9876543210".utf8))
        do {
            _ = try await s.queryStatus()
            XCTFail("expected failure")
        } catch {
            guard case .authentication = error as? DriverError else { return XCTFail("\(error)") }
        }
    }

    func testRepliesArrivingInTinyChunksAreReassembled() async throws {
        for version in TuyaVersion.allCases {
            let device = FakeTuya(version: version, dps: rgbBulbDPS)
            device.chunkSize = 5
            let s = session(device)
            try await s.negotiate()
            let awaited3 = try await s.queryStatus()
            XCTAssertEqual(awaited3, rgbBulbDPS, "version \(version.rawValue)")
        }
    }

    func testUnsolicitedStatusFramesAreSkipped() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        device.pushesStatusFirst = true
        let awaited4 = try await session(device).queryStatus()
        XCTAssertEqual(awaited4, rgbBulbDPS)
    }

    func testControlSentIsByteForByteWhatTheReferenceDescribes() async throws {
        // The version-3.3 control frame: header outside the encryption, CRC32 trailer, cmd 7.
        final class Capture: ByteChannel, @unchecked Sendable {
            var sent = Data()
            func send(_ data: Data) async throws { sent = data }
            func receive() async throws -> Data { throw DriverError.unreachable("n/a") }
            func close() {}
        }
        let capture = Capture()
        let s = TuyaSession(channel: capture, deviceID: "devid", localKey: key, version: .v33)
        _ = try? await s.setDPS(["20": .bool(true)])

        let (frame, _) = try XCTUnwrap(try TuyaFraming.decode(capture.sent, hmacKey: nil, hasReturnCode: false))
        XCTAssertEqual(frame.command, 7)
        XCTAssertEqual(frame.payload.prefix(15), Data("3.3".utf8) + Data(count: 12))
        let plain = try TuyaCrypto.aesECB(encrypt: false, key: key, data: frame.payload.dropFirst(15))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertEqual(json["devId"] as? String, "devid")
        XCTAssertEqual(json["uid"] as? String, "devid")
        XCTAssertEqual((json["dps"] as? [String: Any])?["20"] as? Bool, true)
        XCTAssertNotNil(json["t"])
    }
}

final class TuyaProfileTests: XCTestCase {
    func testDetectsLayoutBWithFullCapabilities() throws {
        let (profile, caps) = try XCTUnwrap(TuyaBulbProfile.detect(from: rgbBulbDPS))
        XCTAssertEqual(profile.kind, .b)
        XCTAssertEqual(caps, [.power, .brightness, .colorTemp, .color])
    }

    func testDetectsLayoutA() throws {
        let dps: [String: TuyaValue] = ["1": .bool(true), "2": .string("white"), "3": .int(128), "4": .int(0), "5": .string("000000000000ff")]
        let (profile, caps) = try XCTUnwrap(TuyaBulbProfile.detect(from: dps))
        XCTAssertEqual(profile.kind, .a)
        XCTAssertEqual(caps, [.power, .brightness, .colorTemp, .color])
    }

    func testDetectsWhiteOnlyLayoutC() throws {
        let dps: [String: TuyaValue] = ["1": .bool(true), "2": .int(100), "3": .int(0)]
        let (profile, caps) = try XCTUnwrap(TuyaBulbProfile.detect(from: dps))
        XCTAssertEqual(profile.kind, .c)
        XCTAssertEqual(caps, [.power, .brightness, .colorTemp], "no colour control for a white-only bulb")
    }

    func testDetectsDimmableOnlyBulbWithoutTemperatureOrColour() throws {
        let dps: [String: TuyaValue] = ["20": .bool(true), "21": .string("white"), "22": .int(60)]
        XCTAssertEqual(TuyaBulbProfile.detect(from: dps)?.capabilities, [.power, .brightness])
    }

    func testRejectsDevicesThatAreNotBulbs() {
        XCTAssertNil(TuyaBulbProfile.detect(from: ["1": .bool(true), "20": .bool(false)]), "a socket or switch")
        XCTAssertNil(TuyaBulbProfile.detect(from: ["9": .int(1)]))
    }

    func testReadsWhiteStateWithScaling() throws {
        let (profile, _) = try XCTUnwrap(TuyaBulbProfile.detect(from: rgbBulbDPS))
        let state = profile.state(from: rgbBulbDPS)
        XCTAssertEqual(state, BulbState(isOn: true, dimming: 50, temperature: 4600))
    }

    func testReadsColourState() throws {
        let (profile, _) = try XCTUnwrap(TuyaBulbProfile.detect(from: rgbBulbDPS))
        var dps = rgbBulbDPS
        dps["21"] = .string("colour")
        dps["24"] = .string("007803e801f4")             // hue 120, sat 100%, value 50%
        let state = profile.state(from: dps)
        XCTAssertEqual(state.rgb, RGB(r: 0, g: 255, b: 0))
        XCTAssertEqual(state.dimming, 50)
        XCTAssertNil(state.temperature)
    }

    func testWritesLayoutBValues() throws {
        let (p, _) = try XCTUnwrap(TuyaBulbProfile.detect(from: rgbBulbDPS))
        XCTAssertEqual(p.dps(for: LightCommand(state: true, dimming: 60), current: BulbState(isOn: true, dimming: 50, temperature: 3000)),
                       ["20": .bool(true), "22": .int(600)])
        XCTAssertEqual(p.dps(for: LightCommand(state: true, temp: 4000), current: nil),
                       ["20": .bool(true), "21": .string("white"), "23": .int(342)])
        XCTAssertEqual(p.dps(for: LightCommand(state: true, dimming: 80, rgb: RGB(r: 255, g: 0, b: 0)), current: nil),
                       ["20": .bool(true), "21": .string("colour"), "24": .string("000003e80320")])
    }

    func testBrightnessInColourModeChangesTheColourValueNotTheWhiteBrightness() throws {
        let (p, _) = try XCTUnwrap(TuyaBulbProfile.detect(from: rgbBulbDPS))
        let current = BulbState(isOn: true, dimming: 50, rgb: RGB(r: 255, g: 0, b: 0))
        let dps = p.dps(for: LightCommand(dimming: 100), current: current)
        XCTAssertEqual(dps, ["24": .string("000003e803e8")])
        XCTAssertNil(dps["22"])
    }

    func testColourWithoutBrightnessKeepsTheCurrentBrightness() throws {
        let (p, _) = try XCTUnwrap(TuyaBulbProfile.detect(from: rgbBulbDPS))
        XCTAssertTrue(p.needsCurrentState(for: LightCommand(rgb: RGB(r: 0, g: 0, b: 255))))
        let dps = p.dps(for: LightCommand(rgb: RGB(r: 0, g: 0, b: 255)), current: BulbState(isOn: true, dimming: 30, temperature: 3000))
        XCTAssertEqual(dps["24"], .string("00f0 03e8 012c".replacingOccurrences(of: " ", with: "")))   // value 30% = 300 = 0x12c
    }

    func testLayoutAColourStringIncludesRGBAndHSV() throws {
        let dps: [String: TuyaValue] = ["1": .bool(true), "2": .string("white"), "3": .int(128), "4": .int(0), "5": .string("000000000000ff")]
        let (p, _) = try XCTUnwrap(TuyaBulbProfile.detect(from: dps))
        let out = p.dps(for: LightCommand(dimming: 100, rgb: RGB(r: 255, g: 0, b: 0)), current: nil)
        XCTAssertEqual(out["5"], .string("ff000000 00ffff".replacingOccurrences(of: " ", with: "")))
        XCTAssertEqual(out["2"], .string("colour"))
    }

    func testWhiteOnlyBulbIgnoresColourCommands() throws {
        let (p, _) = try XCTUnwrap(TuyaBulbProfile.detect(from: ["1": .bool(true), "2": .int(100), "3": .int(0)]))
        XCTAssertEqual(p.dps(for: LightCommand(state: true, rgb: RGB(r: 1, g: 2, b: 3)), current: nil), ["1": .bool(true)])
    }
}

final class TuyaDriverTests: XCTestCase {
    private let secrets = InMemorySecretStore()
    private let key = "0123456789abcdef"

    private func driver(_ device: FakeTuya) -> TuyaDriver { TuyaDriver(secrets: secrets, connector: device.connector) }

    private func register(_ driver: TuyaDriver, device: FakeTuya, version: TuyaVersion? = nil, key: String? = nil) async throws -> Bulb {
        try await driver.register(deviceID: device.deviceID, name: "Desk", host: "192.168.1.50", localKey: key ?? self.key, version: version)
    }

    // MARK: Setup wizard

    func testRegisterDetectsVersion33AndCapabilities() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let bulb = try await register(driver(device), device: device)
        XCTAssertEqual(bulb.id, "tuya:\(device.deviceID)")
        XCTAssertEqual(bulb.native["version"], "3.3")
        XCTAssertEqual(bulb.capabilities, [.power, .brightness, .colorTemp, .color])
        XCTAssertEqual(bulb.address, "192.168.1.50")
    }

    func testRegisterAutoDetectsVersion34() async throws {
        let device = FakeTuya(version: .v34, dps: rgbBulbDPS)
        let bulb = try await register(driver(device), device: device)
        XCTAssertEqual(bulb.native["version"], "3.4")
    }

    func testTheLocalKeyIsStoredInTheSecretStoreAndNeverInTheBulb() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let bulb = try await register(driver(device), device: device)

        XCTAssertEqual(secrets.get("tuya.localKey.\(device.deviceID)"), key)
        let json = String(decoding: try JSONEncoder().encode(bulb), as: UTF8.self)
        XCTAssertFalse(json.contains(key), "the key must not be in anything that gets saved to UserDefaults")
    }

    func testWrongKeyIsReportedAsAKeyProblemAndNothingIsStored() async {
        for version in TuyaVersion.allCases {
            let device = FakeTuya(version: version, dps: rgbBulbDPS)
            do {
                _ = try await register(driver(device), device: device, key: "fedcba9876543210")
                XCTFail("expected failure")
            } catch {
                guard case .authentication = error as? DriverError else { return XCTFail("v\(version.rawValue): \(error)") }
            }
            XCTAssertNil(secrets.get("tuya.localKey.\(device.deviceID)"), "a key that didn't work is never saved")
        }
    }

    func testUnreachableBulbIsReportedAsUnreachable() async {
        let driver = TuyaDriver(secrets: secrets, connector: { _, _ in throw DriverError.unreachable("Connection refused") })
        do {
            _ = try await driver.register(deviceID: "abc", name: "", host: "192.168.1.50", localKey: key, version: nil)
            XCTFail("expected failure")
        } catch {
            guard case .unreachable = error as? DriverError else { return XCTFail("\(error)") }
        }
    }

    func testWizardInputIsValidatedWithSpecificMessages() async {
        let d = TuyaDriver(secrets: secrets, connector: { _, _ in throw DriverError.unreachable("x") })
        func message(id: String = "abc", host: String = "192.168.1.5", key: String = "0123456789abcdef") async -> String? {
            do { _ = try await d.register(deviceID: id, name: "", host: host, localKey: key, version: .v33); return nil }
            catch { return (error as? DriverError)?.errorDescription }
        }
        let noID = await message(id: " ")
        XCTAssertEqual(noID, "Enter the device ID.")
        let badIP = await message(host: "not-an-ip")
        XCTAssertEqual(badIP, "Enter the bulb's IPv4 address, like 192.168.1.50.")
        let shortKey = await message(key: "short")
        XCTAssertTrue(shortKey?.contains("exactly 16 characters (it's 5)") == true, shortKey ?? "nil")
    }

    func testNonBulbDeviceIsRejectedWithItsDataPoints() async {
        let device = FakeTuya(version: .v33, dps: ["1": .bool(true), "20": .bool(false), "9": .int(0)])
        do {
            _ = try await register(driver(device), device: device, version: .v33)
            XCTFail("expected failure")
        } catch {
            guard case .unsupported(let message) = error as? DriverError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("doesn't look like a light bulb"))
        }
    }

    // MARK: Control

    func testApplyBrightnessAndTemperatureWriteTheRightDataPoints() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let d = driver(device)
        let bulb = try await register(d, device: device)

        try await d.apply(LightCommand(state: true, dimming: 60), to: bulb)
        XCTAssertEqual(device.dps["22"], .int(600))

        try await d.apply(LightCommand(state: true, temp: 6500), to: bulb)
        XCTAssertEqual(device.dps["23"], .int(1000))
        XCTAssertEqual(device.dps["21"], .string("white"))
    }

    func testApplyColourKeepsTheBulbsCurrentBrightness() async throws {
        let device = FakeTuya(version: .v34, dps: rgbBulbDPS)       // brightness 50%
        let d = driver(device)
        let bulb = try await register(d, device: device)

        try await d.apply(LightCommand(state: true, rgb: RGB(r: 255, g: 0, b: 0)), to: bulb)

        XCTAssertEqual(device.dps["21"], .string("colour"))
        XCTAssertEqual(device.dps["24"], .string("000003e801f4"), "hue 0, saturation 100%, value 50% (the bulb's current brightness)")
    }

    func testGetStateReadsTheBulb() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let d = driver(device)
        let bulb = try await register(d, device: device)
        let state = try await d.getState(of: bulb)
        XCTAssertEqual(state, BulbState(isOn: true, dimming: 50, temperature: 4600))
    }

    func testSimultaneousCommandsUseOneConnectionAtATime() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let d = driver(device)
        let bulb = try await register(d, device: device)

        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1...6 {
                group.addTask { try await d.apply(LightCommand(state: true, dimming: 10 * i), to: bulb) }
            }
            _ = try? await group.waitForAll()
        }

        XCTAssertEqual(device.maxConcurrentConnections, 1, "Tuya bulbs only allow one local connection")
        XCTAssertEqual(device.commands.count, 6)
    }

    func testUnreachableDuringControlIsAnUnreachableError() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let d = driver(device)
        let bulb = try await register(d, device: device)
        let offline = TuyaDriver(secrets: secrets, connector: { _, _ in throw DriverError.unreachable("No route to host") })
        do {
            try await offline.apply(.power(true), to: bulb)
            XCTFail("expected failure")
        } catch {
            guard case .unreachable = error as? DriverError else { return XCTFail("\(error)") }
        }
    }

    func testMissingKeyAsksForSetupAgain() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let bulb = try await register(driver(device), device: device)
        let fresh = TuyaDriver(secrets: InMemorySecretStore(), connector: device.connector)   // e.g. Keychain item deleted
        do {
            _ = try await fresh.getState(of: bulb)
            XCTFail("expected failure")
        } catch {
            guard case .authentication(let message) = error as? DriverError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("local key"))
        }
    }

    func testForgettingABulbDeletesItsKey() async throws {
        let device = FakeTuya(version: .v33, dps: rgbBulbDPS)
        let d = driver(device)
        let bulb = try await register(d, device: device)
        XCTAssertNotNil(secrets.get("tuya.localKey.\(device.deviceID)"))
        d.forget(bulb)
        XCTAssertNil(secrets.get("tuya.localKey.\(device.deviceID)"))
    }

    func testHelpExplainsHowToGetKeys() {
        let help = driver(FakeTuya(version: .v33, dps: [:])).help
        XCTAssertTrue(help.setup.contains { $0.contains("iot.tuya.com") })
        XCTAssertTrue(help.setup.contains { $0.contains("local key") })
        XCTAssertTrue(help.unreachable.contains("local key"))
    }
}
