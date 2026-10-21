import Foundation

/// LIFX bulbs over the LAN (UDP 56700). No account or app setting is needed: LIFX bulbs always accept local control.
public final class LifxDriver: BulbDriver {
    public static let driverID = "lifx"
    public let id = LifxDriver.driverID
    public let displayName = "LIFX"
    public let brand = "LIFX"
    public let supportsManualIP = true

    private let port: UInt16
    private let broadcastTargets: [(host: String, port: UInt16)]?
    private let discoveryDuration: TimeInterval
    private let source: UInt32
    private let counter = Counter()

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt8 = 0
        func next() -> UInt8 { lock.lock(); defer { lock.unlock() }; value &+= 1; return value }
    }

    /// - Parameters:
    ///   - port: the bulbs' UDP port (56700; tests use another).
    ///   - broadcastTargets: where discovery is sent. Nil means the LAN's broadcast addresses.
    public init(port: UInt16 = 56700, broadcastTargets: [(host: String, port: UInt16)]? = nil, discoveryDuration: TimeInterval = 2.0) {
        self.port = port
        self.broadcastTargets = broadcastTargets
        self.discoveryDuration = discoveryDuration
        self.source = UInt32.random(in: 2...UInt32.max)       // identifies our packets in replies
    }

    public var help: DriverHelp {
        DriverHelp(
            driverName: "LIFX",
            unreachable: "Make sure the bulb is powered on and connected to the same Wi-Fi network as your Mac. LIFX needs no extra setting for local control.",
            checks: [
                "Set the bulb up in the LIFX app first, so it has joined your Wi-Fi.",
                "A guest network, a VPN, or a router with \"client isolation\" blocks local control.",
                "Allow LumaBar in System Settings ▸ Privacy & Security ▸ Local Network.",
                "Bulbs on a different subnet (or a mesh network that separates devices) can't be found by search; add them by IP address instead.",
            ],
            setup: [
                "Set the bulb up in the LIFX app so it's on your Wi-Fi.",
                "Keep your Mac on the same Wi-Fi network, then use Search Network.",
                "If a bulb isn't found, add it by its IP address.",
            ])
    }

    // MARK: Discovery

    public func discover() async -> [Bulb] {
        let packet = LifxProtocol.packet(type: .getService, source: source, sequence: counter.next(), target: nil)
        let targets = broadcastTargets ?? ([("255.255.255.255", port)] + LocalNetwork.broadcastAddresses().map { ($0, port) })
        let replies = await UDPProbe.collect(payload: packet, targets: targets, duration: discoveryDuration)

        var devices: [String: (ip: String, mac: Data, port: UInt16)] = [:]
        for reply in replies {
            guard let (header, payload) = LifxProtocol.parse(reply.data), header.type == LifxProtocol.MessageType.stateService.rawValue,
                  header.source == source, let service = LifxProtocol.parseService(payload), service.service == 1 else { continue }
            devices[Self.hex(header.target)] = (reply.source, header.target, UInt16(truncatingIfNeeded: service.port))
        }

        var bulbs: [Bulb] = []
        await withTaskGroup(of: Bulb?.self) { group in
            for (mac, device) in devices {
                group.addTask { await self.describe(mac: mac, macBytes: device.mac, host: device.ip, port: device.port) }
            }
            for await bulb in group { if let bulb { bulbs.append(bulb) } }
        }
        return bulbs.sorted { $0.id < $1.id }
    }

    public func probe(host: String) async throws -> Bulb {
        // Broadcast-style GetService, but sent straight to this address.
        let sequence = counter.next()
        let packet = LifxProtocol.packet(type: .getService, source: source, sequence: sequence, target: nil)
        let source = self.source
        guard let reply = await UDPProbe.request(payload: packet, host: host, port: port, accept: { datagram in
            guard let (h, _) = LifxProtocol.parse(datagram.data) else { return false }
            return h.source == source && h.type == LifxProtocol.MessageType.stateService.rawValue
        }), let (header, _) = LifxProtocol.parse(reply.data) else {
            throw DriverError.unreachable("No LIFX bulb answered at \(host).")
        }
        guard let bulb = await describe(mac: Self.hex(header.target), macBytes: header.target, host: host, port: port) else {
            throw DriverError.protocolError("The bulb didn't describe itself.")
        }
        return bulb
    }

    /// Asks a found bulb for its name and model, so the UI can name it and show only controls it supports.
    private func describe(mac: String, macBytes: Data, host: String, port: UInt16) async -> Bulb? {
        let state = try? await requestState(host: host, port: port, mac: macBytes)
        var caps: DeviceCapabilities = .fullColor
        if let (_, payload) = try? await exchange(type: .getVersion, payload: Data(), host: host, port: port, mac: macBytes, expecting: .stateVersion),
           let version = LifxProtocol.parseVersion(payload) {
            caps = LifxProtocol.capabilities(forProduct: version.product)
        }
        let label = state?.label ?? ""
        return Bulb(id: "\(id):\(mac)", name: label.isEmpty ? "LIFX \(mac.suffix(6).uppercased())" : label, brand: brand, driverID: id,
                    capabilities: caps, address: host, native: ["mac": mac, "port": String(port)])
    }

    // MARK: Control

    public func getState(of bulb: Bulb) async throws -> BulbState {
        let (host, port, mac) = try endpoint(of: bulb)
        let light = try await requestState(host: host, port: port, mac: mac)
        let c = light.color
        let isWhite = c.saturation < 1311              // under 2% saturation reads as white
        return BulbState(isOn: light.power > 0,
                         dimming: max(1, Int((c.brightnessFraction * 100).rounded())),
                         temperature: isWhite ? Int(c.kelvin) : nil,
                         rgb: isWhite ? nil : ColorMath.rgb(hue: c.hueFraction, saturation: c.saturationFraction, value: 1))
    }

    public func apply(_ command: LightCommand, to bulb: Bulb) async throws {
        let (host, port, mac) = try endpoint(of: bulb)
        let duration: UInt32 = 300

        if command.state == false {
            try await send(.setLightPower, LifxProtocol.setLightPowerPayload(on: false, duration: duration), host: host, port: port, mac: mac)
            return
        }
        if command.state == true {
            try await send(.setLightPower, LifxProtocol.setLightPowerPayload(on: true, duration: duration), host: host, port: port, mac: mac)
        }

        guard command.rgb != nil || command.temp != nil || command.dimming != nil else { return }
        // LIFX sets hue, saturation, brightness and kelvin together, so anything left unspecified is read first.
        let needsCurrent = command.dimming == nil || (command.rgb == nil && command.temp == nil)
        let current = needsCurrent ? try await requestState(host: host, port: port, mac: mac).color : nil

        let brightness = command.dimming.map { Double($0) / 100 } ?? current?.brightnessFraction ?? 1
        let color: LifxProtocol.HSBK
        if let rgb = command.rgb {
            color = LifxProtocol.HSBK(hueFraction: ColorMath.hue(of: rgb), saturationFraction: ColorMath.saturation(of: rgb), brightnessFraction: brightness,
                                      kelvin: Int(current?.kelvin ?? 3500))
        } else if let kelvin = command.temp {
            color = LifxProtocol.HSBK(hueFraction: 0, saturationFraction: 0, brightnessFraction: brightness, kelvin: kelvin)
        } else if let current {
            color = LifxProtocol.HSBK(hue: current.hue, saturation: current.saturation,
                                      brightness: UInt16((brightness * 65535).rounded()), kelvin: current.kelvin)
        } else {
            return
        }
        try await send(.setColor, LifxProtocol.setColorPayload(color, duration: duration), host: host, port: port, mac: mac)
    }

    // MARK: Plumbing

    private func endpoint(of bulb: Bulb) throws -> (host: String, port: UInt16, mac: Data) {
        guard let mac = bulb.native["mac"].flatMap(Self.bytes(fromHex:)) else {
            throw DriverError.notConfigured("\(bulb.name) needs to be added again.")
        }
        return (bulb.address, bulb.native["port"].flatMap { UInt16($0) } ?? port, mac)
    }

    private func requestState(host: String, port: UInt16, mac: Data) async throws -> LifxProtocol.LightState {
        let (_, payload) = try await exchange(type: .get, payload: Data(), host: host, port: port, mac: mac, expecting: .state)
        guard let state = LifxProtocol.parseState(payload) else { throw DriverError.protocolError("The bulb sent an unexpected state.") }
        return state
    }

    /// A command that is confirmed by an acknowledgement.
    private func send(_ type: LifxProtocol.MessageType, _ payload: Data, host: String, port: UInt16, mac: Data) async throws {
        _ = try await exchange(type: type, payload: payload, host: host, port: port, mac: mac, expecting: .acknowledgement, ack: true)
    }

    /// Sends one packet and waits for the reply that matches our source id and sequence number (resent once on silence).
    private func exchange(type: LifxProtocol.MessageType, payload: Data, host: String, port: UInt16, mac: Data,
                          expecting: LifxProtocol.MessageType, ack: Bool = false) async throws -> (LifxProtocol.Header, Data) {
        let sequence = counter.next()
        let packet = LifxProtocol.packet(type: type, payload: payload, source: source, sequence: sequence, target: mac,
                                         ackRequired: ack, responseRequired: !ack)
        let source = self.source
        guard let reply = await UDPProbe.request(payload: packet, host: host, port: port, accept: { datagram in
            guard let (h, _) = LifxProtocol.parse(datagram.data) else { return false }
            return h.source == source && h.sequence == sequence && h.type == expecting.rawValue
        }), let parsed = LifxProtocol.parse(reply.data) else {
            throw DriverError.unreachable("The bulb didn't answer.")
        }
        return parsed
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func bytes(fromHex text: String) -> Data? {
        guard text.count == 12 else { return nil }
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
