import XCTest
@testable import LumaBarCore

/// A Yeelight bulb speaking its JSON-lines protocol, in memory.
final class FakeYeelight: @unchecked Sendable {
    private let lock = NSLock()
    private var _props: [String: String]
    private var _requests: [(method: String, params: [Any])] = []
    private var _connections = 0
    var notifyBeforeReplies = false
    var failWith: (code: Int, message: String)?
    var refuseConnections = false
    var chunkSize = 0

    init(power: String = "on", bright: String = "50", ct: String = "4000", rgb: String = "16711680", colorMode: String = "2", name: String = "Desk") {
        _props = ["power": power, "bright": bright, "ct": ct, "rgb": rgb, "color_mode": colorMode, "name": name]
    }

    var props: [String: String] { lock.lock(); defer { lock.unlock() }; return _props }
    var requests: [(method: String, params: [Any])] { lock.lock(); defer { lock.unlock() }; return _requests }
    var methods: [String] { requests.map(\.method) }
    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }

    var connector: ByteConnector {
        { [self] _, _ in
            if refuseConnections { throw DriverError.unreachable("Connection refused") }
            lock.lock(); _connections += 1; lock.unlock()
            return Connection(device: self)
        }
    }

    fileprivate func handle(_ object: [String: Any]) -> [Data] {
        guard let id = object["id"] as? Int, let method = object["method"] as? String else { return [] }
        let params = object["params"] as? [Any] ?? []
        lock.lock(); _requests.append((method, params)); lock.unlock()

        var lines: [[String: Any]] = []
        if notifyBeforeReplies { lines.append(["method": "props", "params": ["power": "on"]]) }

        if let failure = failWith {
            lines.append(["id": id, "error": ["code": failure.code, "message": failure.message]])
        } else {
            lock.lock()
            switch method {
            case "set_power": _props["power"] = params.first as? String
            case "set_bright": _props["bright"] = "\(params[0])"
            case "set_ct_abx": _props["ct"] = "\(params[0])"; _props["color_mode"] = "2"
            case "set_rgb": _props["rgb"] = "\(params[0])"; _props["color_mode"] = "1"
            default: break
            }
            lock.unlock()
            if method == "get_prop" {
                lines.append(["id": id, "result": params.map { _props[$0 as? String ?? ""] ?? "" }])
            } else {
                lines.append(["id": id, "result": ["ok"]])
            }
        }
        return lines.map { ((try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) ?? Data()) + Data("\r\n".utf8) }
    }

    private final class Connection: ByteChannel, @unchecked Sendable {
        let device: FakeYeelight
        private var inbox = Data()
        private var outbox: [Data] = []
        init(device: FakeYeelight) { self.device = device }
        func close() {}

        func send(_ data: Data) async throws {
            inbox.append(data)
            while let newline = inbox.firstIndex(of: 0x0A) {
                let line = Data(inbox[inbox.startIndex..<newline])
                inbox.removeSubrange(inbox.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                for reply in device.handle(object) {
                    if device.chunkSize > 0 {
                        var rest = reply
                        while !rest.isEmpty { outbox.append(rest.prefix(device.chunkSize)); rest = Data(rest.dropFirst(device.chunkSize)) }
                    } else {
                        outbox.append(reply)
                    }
                }
            }
        }

        func receive() async throws -> Data {
            guard !outbox.isEmpty else { throw DriverError.unreachable("The device didn't answer in time.") }
            return outbox.removeFirst()
        }
    }
}

private func bulb(_ caps: DeviceCapabilities = .fullColor, id: String = "0x1") -> Bulb {
    Bulb(id: "yeelight:\(id)", name: "Desk", brand: "Yeelight", driverID: "yeelight", capabilities: caps, address: "192.168.1.9", native: ["port": "55443"])
}

final class YeelightProtocolTests: XCTestCase {
    func testRequestFormat() {
        let data = YeelightProtocol.request(id: 1, method: "set_power", params: ["on", "smooth", 300])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"id\":1,\"method\":\"set_power\",\"params\":[\"on\",\"smooth\",300]}\r\n")
    }

    func testReplyParsing() {
        XCTAssertEqual(YeelightProtocol.parseReply(Data(#"{"id":2,"result":["ok"]}"#.utf8))?.reply, .ok(["ok"]))
        XCTAssertEqual(YeelightProtocol.parseReply(Data(#"{"id":2,"result":["ok"]}"#.utf8))?.id, 2)
        XCTAssertEqual(YeelightProtocol.parseReply(Data(#"{"id":3,"error":{"code":-1,"message":"client quota exceeded"}}"#.utf8))?.reply,
                       .error(code: -1, message: "client quota exceeded"))
        XCTAssertEqual(YeelightProtocol.parseReply(Data(#"{"method":"props","params":{"power":"on"}}"#.utf8))?.reply, .notification)
        XCTAssertNil(YeelightProtocol.parseReply(Data("garbage".utf8)))
    }

    private let advert = "HTTP/1.1 200 OK\r\nCache-Control: max-age=3600\r\nDate: \r\nExt: \r\nLocation: yeelight://192.168.1.239:55443\r\nServer: POSIX UPnP/1.0 YGLC/1\r\nid: 0x000000000015243f\r\nmodel: color\r\nfw_ver: 18\r\nsupport: get_prop set_default set_power toggle set_bright start_cf stop_cf set_scene cron_add cron_get cron_del set_ct_abx set_rgb\r\npower: on\r\nbright: 100\r\ncolor_mode: 2\r\nct: 4000\r\nrgb: 16711680\r\nhue: 100\r\nsat: 35\r\nname: my_bulb\r\n\r\n"

    func testAdvertisementFromTheDocumentedFormat() throws {
        let ad = try XCTUnwrap(YeelightProtocol.parseAdvertisement(Datagram(data: Data(advert.utf8), source: "192.168.1.239")))
        XCTAssertEqual(ad.id, "0x000000000015243f")
        XCTAssertEqual(ad.host, "192.168.1.239")
        XCTAssertEqual(ad.port, 55443)
        XCTAssertEqual(ad.name, "my_bulb")
        XCTAssertEqual(ad.capabilities, [.power, .brightness, .colorTemp, .color])
        XCTAssertTrue(ad.isOn)
    }

    func testWhiteBulbAdvertisementHasNoColour() throws {
        let white = advert.replacingOccurrences(of: " set_rgb", with: "")
        let ad = try XCTUnwrap(YeelightProtocol.parseAdvertisement(Datagram(data: Data(white.utf8), source: "1.2.3.4")))
        XCTAssertEqual(ad.capabilities, [.power, .brightness, .colorTemp])
    }

    func testNonAdvertisementsAreIgnored() {
        XCTAssertNil(YeelightProtocol.parseAdvertisement(Datagram(data: Data("hello".utf8), source: "1.2.3.4")))
        XCTAssertNil(YeelightProtocol.parseAdvertisement(Datagram(data: Data("HTTP/1.1 200 OK\r\nmodel: color\r\n\r\n".utf8), source: "1.2.3.4")), "no id")
    }
}

final class YeelightRateLimiterTests: XCTestCase {
    func testFirstSendsAreOnlySpaced() {
        var limiter = YeelightRateLimiter(maxPerMinute: 5, minimumSpacing: 0.25)
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(limiter.reserve(now: t), 0)
        XCTAssertEqual(limiter.reserve(now: t), 0.25, accuracy: 1e-9)
        XCTAssertEqual(limiter.reserve(now: t), 0.5, accuracy: 1e-9)
    }

    func testTheSixthCommandInAMinuteWaitsForTheFirstToAgeOut() {
        var limiter = YeelightRateLimiter(maxPerMinute: 5, minimumSpacing: 0)
        let t = Date(timeIntervalSince1970: 1000)
        for _ in 0..<5 { XCTAssertEqual(limiter.reserve(now: t), 0) }
        XCTAssertEqual(limiter.reserve(now: t.addingTimeInterval(10)), 50, accuracy: 1e-9, "wait until 60s after the first")
    }

    func testTheWindowSlides() {
        var limiter = YeelightRateLimiter(maxPerMinute: 2, minimumSpacing: 0)
        let t = Date(timeIntervalSince1970: 1000)
        _ = limiter.reserve(now: t); _ = limiter.reserve(now: t)
        XCTAssertEqual(limiter.reserve(now: t.addingTimeInterval(61)), 0, "a minute later the old commands no longer count")
    }

    func testNeverExceedsTheQuotaOverALongBurst() {
        var limiter = YeelightRateLimiter()
        var clock = Date(timeIntervalSince1970: 1000)
        var sendTimes: [Date] = []
        for _ in 0..<200 {                                   // a very long slider drag
            let wait = limiter.reserve(now: clock)
            sendTimes.append(clock.addingTimeInterval(wait))
            clock = clock.addingTimeInterval(wait)
        }
        for (i, t) in sendTimes.enumerated() {
            let inWindow = sendTimes[i...].filter { $0.timeIntervalSince(t) < 60 }.count
            XCTAssertLessThanOrEqual(inWindow, 55, "more than 55 commands within 60 s starting at #\(i)")
        }
    }
}

final class YeelightDriverTests: XCTestCase {
    private func driver(_ device: FakeYeelight, sleeps: SleepLog = SleepLog()) -> YeelightDriver {
        YeelightDriver(connector: device.connector, searchTargets: [], searchDuration: 0.2, sleeper: { sleeps.record($0) })
    }

    final class SleepLog: @unchecked Sendable {
        private let lock = NSLock(); private var _delays: [TimeInterval] = []
        func record(_ d: TimeInterval) { lock.lock(); _delays.append(d); lock.unlock() }
        var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _delays }
    }

    func testReadsWhiteState() async throws {
        let state = try await driver(FakeYeelight(power: "on", bright: "70", ct: "3500", colorMode: "2")).getState(of: bulb())
        XCTAssertEqual(state, BulbState(isOn: true, dimming: 70, temperature: 3500))
    }

    func testReadsColourState() async throws {
        let state = try await driver(FakeYeelight(bright: "40", rgb: "65280", colorMode: "1")).getState(of: bulb())
        XCTAssertEqual(state.rgb, RGB(r: 0, g: 255, b: 0))
        XCTAssertEqual(state.dimming, 40)
        XCTAssertNil(state.temperature)
    }

    func testPowerOffIsOneRequest() async throws {
        let device = FakeYeelight()
        try await driver(device).apply(.power(false), to: bulb())
        XCTAssertEqual(device.methods, ["set_power"])
        XCTAssertEqual(device.props["power"], "off")
    }

    func testWarmWhiteAtBrightnessSendsPowerThenTemperatureThenBrightness() async throws {
        let device = FakeYeelight(power: "off")
        try await driver(device).apply(LightCommand(state: true, dimming: 30, temp: 2700), to: bulb())
        XCTAssertEqual(device.methods, ["set_power", "set_ct_abx", "set_bright"])
        XCTAssertEqual(device.props["ct"], "2700")
        XCTAssertEqual(device.props["bright"], "30")
        XCTAssertEqual(device.props["power"], "on")
    }

    func testColourIsSentAsAPackedRGBInteger() async throws {
        let device = FakeYeelight()
        try await driver(device).apply(LightCommand(state: true, rgb: RGB(r: 255, g: 128, b: 0)), to: bulb())
        XCTAssertEqual(device.props["rgb"], "\(255 << 16 | 128 << 8)")
        XCTAssertEqual(device.props["color_mode"], "1")
    }

    func testStaysWithinQuotaByNotResendingPowerOnWhileKnownOn() async throws {
        let device = FakeYeelight(power: "off")
        let d = driver(device)
        let b = bulb()
        try await d.apply(LightCommand(state: true, dimming: 20), to: b)
        try await d.apply(LightCommand(state: true, dimming: 40), to: b)
        try await d.apply(LightCommand(state: true, dimming: 60), to: b)
        XCTAssertEqual(device.methods, ["set_power", "set_bright", "set_bright", "set_bright"], "power-on is sent once, not on every slider tick")
    }

    func testRepliesAreMatchedByIDEvenWithNotificationsInBetween() async throws {
        let device = FakeYeelight()
        device.notifyBeforeReplies = true
        let state = try await driver(device).getState(of: bulb())
        XCTAssertEqual(state.dimming, 50)
    }

    func testRepliesInTinyChunksAreReassembled() async throws {
        let device = FakeYeelight()
        device.chunkSize = 3
        let state = try await driver(device).getState(of: bulb())
        XCTAssertEqual(state.temperature, 4000)
    }

    func testQuotaErrorFromTheBulbIsAFriendlyRejection() async {
        let device = FakeYeelight()
        device.failWith = (-1, "client quota exceeded")
        do {
            try await driver(device).apply(.power(true), to: bulb())
            XCTFail("expected failure")
        } catch {
            guard case .rejected(let message) = error as? DriverError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("rate limiting"))
        }
    }

    func testRefusedConnectionPointsAtLANControl() async {
        let device = FakeYeelight()
        device.refuseConnections = true
        do {
            _ = try await driver(device).getState(of: bulb())
            XCTFail("expected failure")
        } catch {
            guard case .unreachable(let message) = error as? DriverError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("LAN Control"), message)
        }
    }

    func testHelpTellsTheUserToEnableLANControlInTheYeelightApp() {
        let help = driver(FakeYeelight()).help
        XCTAssertTrue(help.unreachable.contains("LAN Control"))
        XCTAssertTrue(help.unreachable.contains("Yeelight app"))
        XCTAssertTrue(help.setup.contains { $0.contains("LAN Control") })
    }

    func testCommandsAreSpacedOutRatherThanSentInABurst() async throws {
        let device = FakeYeelight(power: "off")
        let log = SleepLog()
        try await driver(device, sleeps: log).apply(LightCommand(state: true, dimming: 30, temp: 2700), to: bulb())   // 3 requests
        XCTAssertEqual(log.delays.count, 2, "the 2nd and 3rd request each wait; the 1st goes straight out")
        // Sleeping is mocked here, so no time passes: the 2nd waits one spacing, the 3rd waits two.
        XCTAssertEqual(log.delays[0], 0.25, accuracy: 0.05)
        XCTAssertEqual(log.delays[1], 0.50, accuracy: 0.05)
    }

    // MARK: Manual add and discovery

    func testProbeInfersColourBulb() async throws {
        let probed = try await driver(FakeYeelight()).probe(host: "192.168.1.9")
        XCTAssertEqual(probed.capabilities, [.power, .brightness, .colorTemp, .color])
        XCTAssertEqual(probed.name, "Desk")
    }

    func testProbeInfersWhiteOnlyBulb() async throws {
        let probed = try await driver(FakeYeelight(rgb: "")).probe(host: "192.168.1.9")
        XCTAssertEqual(probed.capabilities, [.power, .brightness, .colorTemp])
    }

    func testDiscoveryOverARealUDPSocket() async throws {
        let advert = "HTTP/1.1 200 OK\r\nLocation: yeelight://127.0.0.1:55443\r\nid: 0xabc\r\nmodel: mono\r\nsupport: get_prop set_power set_bright set_ct_abx\r\npower: off\r\nname: Hall\r\n\r\n"
        let fake = try FakeUDPDevice(port: 49820) { request in
            String(decoding: request, as: UTF8.self).contains("M-SEARCH") ? [Data(advert.utf8)] : []
        }
        defer { fake.stop() }
        let d = YeelightDriver(connector: FakeYeelight().connector, searchTargets: [("127.0.0.1", 49820)], searchDuration: 0.6)

        let found = await d.discover()

        XCTAssertEqual(found.map(\.id), ["yeelight:0xabc"])
        XCTAssertEqual(found.first?.name, "Hall")
        XCTAssertEqual(found.first?.capabilities, [.power, .brightness, .colorTemp])
        XCTAssertTrue(fake.received.contains { String(decoding: $0, as: UTF8.self).contains("ST: wifi_bulb") })
    }
}
