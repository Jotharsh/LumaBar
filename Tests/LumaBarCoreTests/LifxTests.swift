import XCTest
@testable import LumaBarCore

private func hex(_ s: String) -> Data {
    let clean = s.replacingOccurrences(of: " ", with: "")
    var data = Data(); var i = clean.startIndex
    while i < clean.endIndex { let n = clean.index(i, offsetBy: 2); data.append(UInt8(clean[i..<n], radix: 16)!); i = n }
    return data
}

/// A LIFX bulb implemented from the device's side, on a real loopback UDP socket.
final class FakeLifx: @unchecked Sendable {
    let mac: Data
    let port: UInt16
    let product: UInt32
    private let lock = NSLock()
    private var _hsbk: LifxProtocol.HSBK
    private var _power: UInt16
    private var _label: String
    private var _received: [LifxProtocol.MessageType] = []
    private var dropsRemaining: Int
    private var device: FakeUDPDevice?
    /// Sends an acknowledgement with the wrong sequence number before the right one (stale/foreign traffic).
    var sendsNoiseFirst = false

    init(port: UInt16, product: UInt32 = 27, mac: String = "d073d5001122", label: String = "Lamp",
         hsbk: LifxProtocol.HSBK = .init(hue: 0, saturation: 0, brightness: 32768, kelvin: 3500), power: UInt16 = 65535, drops: Int = 0) throws {
        self.port = port
        self.product = product
        self.mac = LifxDriver.bytes(fromHex: mac)!
        self._hsbk = hsbk; self._power = power; self._label = label; self.dropsRemaining = drops
        device = try FakeUDPDevice(port: port) { [unowned self] request in self.respond(to: request) }
    }

    func stop() { device?.stop() }
    var hsbk: LifxProtocol.HSBK { lock.lock(); defer { lock.unlock() }; return _hsbk }
    var power: UInt16 { lock.lock(); defer { lock.unlock() }; return _power }
    var received: [LifxProtocol.MessageType] { lock.lock(); defer { lock.unlock() }; return _received }

    private func respond(to request: Data) -> [Data] {
        guard let (header, payload) = LifxProtocol.parse(request), let type = LifxProtocol.MessageType(rawValue: header.type) else { return [] }
        lock.lock()
        _received.append(type)
        if dropsRemaining > 0 { dropsRemaining -= 1; lock.unlock(); return [] }
        lock.unlock()

        func reply(_ type: LifxProtocol.MessageType, _ payload: Data) -> Data {
            LifxProtocol.packet(type: type, payload: payload, source: header.source, sequence: header.sequence, target: mac)
        }
        let ackRequired = request[22] & 2 != 0
        var out: [Data] = []
        if sendsNoiseFirst {
            out.append(LifxProtocol.packet(type: .acknowledgement, source: header.source, sequence: header.sequence &+ 7, target: mac))
            out.append(LifxProtocol.packet(type: .acknowledgement, source: header.source &+ 1, sequence: header.sequence, target: mac))
        }

        switch type {
        case .getService:
            out.append(reply(.stateService, Data([1]) + LifxProtocol.le32(UInt32(port))))
        case .getVersion:
            out.append(reply(.stateVersion, LifxProtocol.le32(1) + LifxProtocol.le32(product) + LifxProtocol.le32(0)))
        case .get:
            lock.lock(); let c = _hsbk, p = _power, l = _label; lock.unlock()
            let label = Data(l.utf8) + Data(count: 32 - l.utf8.count)
            out.append(reply(.state, LifxProtocol.le16(c.hue) + LifxProtocol.le16(c.saturation) + LifxProtocol.le16(c.brightness)
                             + LifxProtocol.le16(c.kelvin) + Data(count: 2) + LifxProtocol.le16(p) + label + Data(count: 8)))
        case .setLightPower:
            lock.lock(); _power = LifxProtocol.u16(payload, 0); lock.unlock()
            if ackRequired { out.append(reply(.acknowledgement, Data())) }
        case .setColor:
            lock.lock()
            _hsbk = LifxProtocol.HSBK(hue: LifxProtocol.u16(payload, 1), saturation: LifxProtocol.u16(payload, 3),
                                      brightness: LifxProtocol.u16(payload, 5), kelvin: LifxProtocol.u16(payload, 7))
            lock.unlock()
            if ackRequired { out.append(reply(.acknowledgement, Data())) }
        default:
            break
        }
        return out
    }
}

final class LifxProtocolTests: XCTestCase {
    func testBroadcastGetServicePacketLayout() {
        // size 36 | protocol 1024 + addressable + tagged = 0x3400 | source | zero target | flags 0 | seq | type 2
        let packet = LifxProtocol.packet(type: .getService, source: 0x01020304, sequence: 9, target: nil)
        let expected = hex("2400 0034 04030201 0000000000000000 000000000000 00 09 0000000000000000 0200 0000")
        XCTAssertEqual(packet, expected)
        XCTAssertEqual(packet.count, 36)
    }

    func testUnicastPacketIsNotTaggedAndCarriesTheMAC() {
        let packet = LifxProtocol.packet(type: .get, source: 1, sequence: 1, target: hex("d073d5001122"), responseRequired: true)
        XCTAssertEqual(LifxProtocol.u16(packet, 2), 0x1400, "addressable but not tagged")
        XCTAssertEqual(packet.subdata(in: 8..<16), hex("d073d5001122 0000"))
        XCTAssertEqual(packet[22], 1, "res_required")
        XCTAssertEqual(LifxProtocol.u16(packet, 32), 101)
    }

    func testAckRequiredFlag() {
        XCTAssertEqual(LifxProtocol.packet(type: .setLightPower, source: 1, sequence: 1, target: hex("d073d5001122"), ackRequired: true)[22], 2)
    }

    func testSetColorPayloadLayoutAndTotalSize() {
        let color = LifxProtocol.HSBK(hue: 0x1111, saturation: 0x2222, brightness: 0x3333, kelvin: 3500)
        let payload = LifxProtocol.setColorPayload(color, duration: 300)
        XCTAssertEqual(payload, hex("00 1111".replacingOccurrences(of: "1111", with: "1111") + "2222 3333 ac0d 2c010000"))
        XCTAssertEqual(payload.count, 13)
        let packet = LifxProtocol.packet(type: .setColor, payload: payload, source: 1, sequence: 1, target: nil)
        XCTAssertEqual(LifxProtocol.u16(packet, 0), 49)
    }

    func testSetLightPowerPayload() {
        XCTAssertEqual(LifxProtocol.setLightPowerPayload(on: true, duration: 300), hex("ffff 2c010000"))
        XCTAssertEqual(LifxProtocol.setLightPowerPayload(on: false, duration: 0), hex("0000 00000000"))
    }

    func testParseRoundTrip() throws {
        let packet = LifxProtocol.packet(type: .stateService, payload: Data([1]) + LifxProtocol.le32(56700), source: 77, sequence: 5, target: hex("d073d5001122"))
        let (header, payload) = try XCTUnwrap(LifxProtocol.parse(packet))
        XCTAssertEqual(header.source, 77)
        XCTAssertEqual(header.sequence, 5)
        XCTAssertEqual(header.type, 3)
        XCTAssertEqual(header.target.prefix(6), hex("d073d5001122"))
        XCTAssertEqual(LifxProtocol.parseService(payload)?.port, 56700)
    }

    func testTruncatedAndOversizedPacketsAreRejected() {
        XCTAssertNil(LifxProtocol.parse(Data(count: 10)))
        var packet = LifxProtocol.packet(type: .get, source: 1, sequence: 1, target: nil)
        packet[0] = 0xFF   // claims to be longer than it is
        XCTAssertNil(LifxProtocol.parse(packet))
    }

    func testHSBKScalingAndClamping() {
        let c = LifxProtocol.HSBK(hueFraction: 0.5, saturationFraction: 1, brightnessFraction: 0.5, kelvin: 99999)
        XCTAssertEqual(c.hue, 32768)
        XCTAssertEqual(c.saturation, 65535)
        XCTAssertEqual(c.kelvin, 9000, "kelvin is clamped to the supported range")
    }

    func testProductCapabilities() {
        XCTAssertEqual(LifxProtocol.capabilities(forProduct: 27), [.power, .brightness, .colorTemp, .color])      // A19
        XCTAssertEqual(LifxProtocol.capabilities(forProduct: 50), [.power, .brightness, .colorTemp])             // Mini White to Warm
        XCTAssertEqual(LifxProtocol.capabilities(forProduct: 51), [.power, .brightness])                         // Mini White
        XCTAssertEqual(LifxProtocol.capabilities(forProduct: 99999), .fullColor, "unknown products are assumed to be colour")
    }
}

final class LifxDriverTests: XCTestCase {
    private func driver(_ port: UInt16) -> LifxDriver {
        LifxDriver(port: port, broadcastTargets: [("127.0.0.1", port)], discoveryDuration: 0.7)
    }

    private func bulb(for fake: FakeLifx, caps: DeviceCapabilities = .fullColor) -> Bulb {
        Bulb(id: "lifx:d073d5001122", name: "Lamp", brand: "LIFX", driverID: "lifx", capabilities: caps, address: "127.0.0.1",
             native: ["mac": "d073d5001122", "port": String(fake.port)])
    }

    func testDiscoveryFindsBulbsAndLearnsTheirNameAndModel() async throws {
        let fake = try FakeLifx(port: 49830, product: 50, label: "Hall"); defer { fake.stop() }
        let found = await driver(49830).discover()
        XCTAssertEqual(found.map(\.id), ["lifx:d073d5001122"])
        XCTAssertEqual(found.first?.name, "Hall")
        XCTAssertEqual(found.first?.capabilities, [.power, .brightness, .colorTemp], "Mini White to Warm has no colour")
        XCTAssertEqual(found.first?.address, "127.0.0.1")
    }

    func testDiscoveryIgnoresNoise() async throws {
        let fake = try FakeLifx(port: 49831); defer { fake.stop() }
        fake.sendsNoiseFirst = true
        let found = await driver(49831).discover()
        XCTAssertEqual(found.count, 1)
    }

    func testProbeByIP() async throws {
        let fake = try FakeLifx(port: 49832, label: "Desk"); defer { fake.stop() }
        let probed = try await driver(49832).probe(host: "127.0.0.1")
        XCTAssertEqual(probed.name, "Desk")
        XCTAssertEqual(probed.native["mac"], "d073d5001122")
    }

    func testGetStateWhite() async throws {
        let fake = try FakeLifx(port: 49833, hsbk: .init(hue: 0, saturation: 0, brightness: 32768, kelvin: 2700)); defer { fake.stop() }
        let state = try await driver(49833).getState(of: bulb(for: fake))
        XCTAssertEqual(state, BulbState(isOn: true, dimming: 50, temperature: 2700))
    }

    func testGetStateColour() async throws {
        let fake = try FakeLifx(port: 49834, hsbk: .init(hue: 21845, saturation: 65535, brightness: 65535, kelvin: 3500), power: 0); defer { fake.stop() }
        let state = try await driver(49834).getState(of: bulb(for: fake))
        XCTAssertFalse(state.isOn)
        XCTAssertEqual(state.rgb, RGB(r: 0, g: 255, b: 0))
        XCTAssertNil(state.temperature)
        XCTAssertEqual(state.dimming, 100)
    }

    func testPowerOffAndOn() async throws {
        let fake = try FakeLifx(port: 49835); defer { fake.stop() }
        let d = driver(49835), b = bulb(for: fake)
        try await d.apply(.power(false), to: b)
        XCTAssertEqual(fake.power, 0)
        try await d.apply(.power(true), to: b)
        XCTAssertEqual(fake.power, 65535)
    }

    func testBrightnessOnlyKeepsTheBulbsColour() async throws {
        let fake = try FakeLifx(port: 49836, hsbk: .init(hue: 43690, saturation: 65535, brightness: 65535, kelvin: 3500)); defer { fake.stop() }
        try await driver(49836).apply(LightCommand(state: true, dimming: 25), to: bulb(for: fake))
        XCTAssertEqual(fake.hsbk.hue, 43690)
        XCTAssertEqual(fake.hsbk.saturation, 65535)
        XCTAssertEqual(fake.hsbk.brightness, 16384, accuracy: 1)
    }

    func testWarmthSetsKelvinAndClearsSaturation() async throws {
        let fake = try FakeLifx(port: 49837, hsbk: .init(hue: 1000, saturation: 40000, brightness: 40000, kelvin: 3500)); defer { fake.stop() }
        try await driver(49837).apply(LightCommand(state: true, temp: 2700), to: bulb(for: fake))
        XCTAssertEqual(fake.hsbk, .init(hue: 0, saturation: 0, brightness: 40000, kelvin: 2700), "keeps brightness, goes white")
    }

    func testColourKeepsBrightnessUnlessGiven() async throws {
        let fake = try FakeLifx(port: 49838, hsbk: .init(hue: 0, saturation: 0, brightness: 20000, kelvin: 3500)); defer { fake.stop() }
        let d = driver(49838), b = bulb(for: fake)
        try await d.apply(LightCommand(state: true, rgb: RGB(r: 0, g: 0, b: 255)), to: b)
        XCTAssertEqual(fake.hsbk.brightness, 20000)
        XCTAssertEqual(fake.hsbk.hue, 43690, accuracy: 2)
        XCTAssertEqual(fake.hsbk.saturation, 65535)

        try await d.apply(LightCommand(state: true, dimming: 100, rgb: RGB(r: 0, g: 0, b: 255)), to: b)
        XCTAssertEqual(fake.hsbk.brightness, 65535)
    }

    func testPowerOnComesBeforeColour() async throws {
        let fake = try FakeLifx(port: 49839, power: 0); defer { fake.stop() }
        try await driver(49839).apply(LightCommand(state: true, dimming: 80, temp: 4000), to: bulb(for: fake))
        let sets = fake.received.filter { $0 == .setLightPower || $0 == .setColor }
        XCTAssertEqual(sets, [.setLightPower, .setColor])
        XCTAssertEqual(fake.power, 65535)
    }

    func testRetriesOnceWhenAPacketIsLost() async throws {
        let fake = try FakeLifx(port: 49840, drops: 1); defer { fake.stop() }
        try await driver(49840).apply(.power(false), to: bulb(for: fake))
        XCTAssertEqual(fake.power, 0)
        XCTAssertEqual(fake.received.filter { $0 == .setLightPower }.count, 2)
    }

    func testStaleAndForeignRepliesAreIgnored() async throws {
        let fake = try FakeLifx(port: 49841, hsbk: .init(hue: 0, saturation: 0, brightness: 1000, kelvin: 3500)); defer { fake.stop() }
        fake.sendsNoiseFirst = true
        let state = try await driver(49841).getState(of: bulb(for: fake))
        XCTAssertEqual(state.dimming, 2)
    }

    func testSilentBulbIsUnreachable() async throws {
        let ghost = Bulb(id: "lifx:d073d5001122", name: "Ghost", brand: "LIFX", driverID: "lifx", capabilities: .fullColor,
                         address: "127.0.0.1", native: ["mac": "d073d5001122", "port": "49899"])
        do {
            _ = try await driver(49899).getState(of: ghost)
            XCTFail("expected failure")
        } catch {
            guard case .unreachable = error as? DriverError else { return XCTFail("\(error)") }
        }
    }

    func testBulbWithoutAMACAsksToBeAddedAgain() async {
        let broken = Bulb(id: "lifx:x", name: "Broken", brand: "LIFX", driverID: "lifx", capabilities: .fullColor, address: "127.0.0.1")
        do { _ = try await driver(49898).getState(of: broken); XCTFail("expected failure") }
        catch { guard case .notConfigured = error as? DriverError else { return XCTFail("\(error)") } }
    }

    func testHelpMentionsWifiAndLocalNetwork() {
        let help = driver(1).help
        XCTAssertTrue(help.unreachable.contains("same Wi-Fi"))
        XCTAssertTrue(help.checks.contains { $0.contains("Local Network") })
    }
}
