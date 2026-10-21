import Foundation

/// LIFX's LAN protocol: little-endian binary packets over UDP port 56700.
///
///     header (36 bytes) = frame (8) + frame address (16) + protocol header (12), then the payload
///
/// Frame:          size u16 | protocol(12 bits)=1024, addressable(1), tagged(1), origin(2) | source u32
/// Frame address:  target (6-byte MAC + 2 zero bytes) | 6 reserved | flags u8 (bit0 res_required, bit1 ack_required) | sequence u8
/// Protocol:       8 reserved | type u16 | 2 reserved
enum LifxProtocol {
    static let port: UInt16 = 56700
    static let headerLength = 36

    enum MessageType: UInt16 {
        case getService = 2, stateService = 3
        case getVersion = 32, stateVersion = 33
        case acknowledgement = 45
        case get = 101, setColor = 102, state = 107
        case setLightPower = 117, stateLightPower = 118
    }

    struct Header: Equatable {
        var size: Int
        var tagged: Bool
        var source: UInt32
        var target: Data          // 6 bytes
        var sequence: UInt8
        var type: UInt16
    }

    /// - Parameter target: the bulb's 6-byte MAC, or nil to address every bulb (sets the `tagged` bit).
    static func packet(type: MessageType, payload: Data = Data(), source: UInt32, sequence: UInt8,
                       target: Data?, ackRequired: Bool = false, responseRequired: Bool = false) -> Data {
        var data = Data()
        data.append(le16(UInt16(headerLength + payload.count)))
        data.append(le16(1024 | (1 << 12) | (target == nil ? (1 << 13) : 0)))   // protocol 1024, addressable, tagged?
        data.append(le32(source))
        data.append((target ?? Data(count: 6)) + Data(count: 2))
        data.append(Data(count: 6))
        data.append((responseRequired ? 1 : 0) | (ackRequired ? 2 : 0))
        data.append(sequence)
        data.append(Data(count: 8))
        data.append(le16(type.rawValue))
        data.append(Data(count: 2))
        return data + payload
    }

    static func parse(_ data: Data) -> (header: Header, payload: Data)? {
        let d = Data(data)
        guard d.count >= headerLength else { return nil }
        let size = Int(u16(d, 0))
        guard size >= headerLength, size <= d.count else { return nil }
        let header = Header(size: size, tagged: u16(d, 2) & (1 << 13) != 0, source: u32(d, 4),
                            target: d.subdata(in: 8..<14), sequence: d[23], type: u16(d, 32))
        return (header, d.subdata(in: headerLength..<size))
    }

    // MARK: Payloads

    struct HSBK: Equatable {
        var hue: UInt16
        var saturation: UInt16
        var brightness: UInt16
        var kelvin: UInt16

        init(hue: UInt16, saturation: UInt16, brightness: UInt16, kelvin: UInt16) {
            self.hue = hue; self.saturation = saturation; self.brightness = brightness; self.kelvin = kelvin
        }

        /// From 0...1 fractions (hue as a fraction of a full turn). Named differently from the raw initializer so an
        /// integer literal can never silently resolve to this one and be clamped to 1.0.
        init(hueFraction h: Double, saturationFraction s: Double, brightnessFraction b: Double, kelvin: Int) {
            func scale(_ v: Double) -> UInt16 { UInt16((min(max(v, 0), 1) * 65535).rounded()) }
            self.init(hue: scale(h), saturation: scale(s), brightness: scale(b), kelvin: UInt16(min(max(kelvin, 1500), 9000)))
        }

        var hueFraction: Double { Double(hue) / 65535 }
        var saturationFraction: Double { Double(saturation) / 65535 }
        var brightnessFraction: Double { Double(brightness) / 65535 }
    }

    /// SetColor: reserved u8, HSBK (4 x u16), transition ms u32.
    static func setColorPayload(_ color: HSBK, duration: UInt32) -> Data {
        Data([0]) + le16(color.hue) + le16(color.saturation) + le16(color.brightness) + le16(color.kelvin) + le32(duration)
    }

    /// SetLightPower: level u16 (0 or 65535), transition ms u32.
    static func setLightPowerPayload(on: Bool, duration: UInt32) -> Data {
        le16(on ? 65535 : 0) + le32(duration)
    }

    struct LightState: Equatable {
        var color: HSBK
        var power: UInt16
        var label: String
    }

    /// State (107): HSBK (4 x u16), reserved i16, power u16, label (32 bytes), reserved u64.
    static func parseState(_ payload: Data) -> LightState? {
        let p = Data(payload)
        guard p.count >= 52 else { return nil }
        let label = String(decoding: p.subdata(in: 12..<44).prefix { $0 != 0 }, as: UTF8.self)
        return LightState(color: HSBK(hue: u16(p, 0), saturation: u16(p, 2), brightness: u16(p, 4), kelvin: u16(p, 6)),
                          power: u16(p, 10), label: label)
    }

    /// StateService (3): service u8 (1 = UDP), port u32.
    static func parseService(_ payload: Data) -> (service: UInt8, port: UInt32)? {
        let p = Data(payload)
        guard p.count >= 5 else { return nil }
        return (p[0], u32(p, 1))
    }

    /// StateVersion (33): vendor u32, product u32, reserved u32.
    static func parseVersion(_ payload: Data) -> (vendor: UInt32, product: UInt32)? {
        let p = Data(payload)
        guard p.count >= 8 else { return nil }
        return (u32(p, 0), u32(p, 4))
    }

    // MARK: Product capabilities

    /// What a product can do. The table is partial: unknown products are assumed to be full colour.
    static func capabilities(forProduct product: UInt32) -> DeviceCapabilities {
        let whiteOnly: Set<UInt32> = [10, 11, 18, 19, 50, 51, 60, 61, 66]   // 800 / 900 whites, Mini White (to Warm)
        let fixedWhite: Set<UInt32> = [51, 61, 66]                          // Mini White: no temperature control
        var caps: DeviceCapabilities = [.power, .brightness]
        if !fixedWhite.contains(product) { caps.insert(.colorTemp) }
        if !whiteOnly.contains(product) { caps.insert(.color) }
        return caps
    }

    // MARK: Byte helpers (little-endian)

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]) }
    static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[d.startIndex + o]) | UInt32(d[d.startIndex + o + 1]) << 8 | UInt32(d[d.startIndex + o + 2]) << 16 | UInt32(d[d.startIndex + o + 3]) << 24
    }
}
