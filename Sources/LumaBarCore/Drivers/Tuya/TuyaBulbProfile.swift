import Foundation

/// How a Tuya bulb lays out its data points ("DPs"). There are three common layouts, told apart by which DPs exist:
///
///  - **A** (DPs 1-5): switch 1, mode 2 (a string), brightness 3 (25-255), temperature 4 (0-255), colour 5 (`rrggbbhhhhssvv`)
///  - **B** (DPs 20-24): switch 20, mode 21, brightness 22 (10-1000), temperature 23 (0-1000), colour 24 (`hhhhssssvvvv`)
///  - **C** (DPs 1-3): switch 1, brightness 2 (25-255), temperature 3 (0-255): white only
struct TuyaBulbProfile: Equatable {
    enum Kind: String { case a = "A", b = "B", c = "C" }

    let kind: Kind
    let switchDP: String
    let modeDP: String?
    let brightnessDP: String?
    let temperatureDP: String?
    let colourDP: String?

    /// Tuya doesn't report the kelvin range of the bulb; most are 2700-6500 K.
    static let warmestKelvin = 2700
    static let coolestKelvin = 6500

    private var brightnessRange: ClosedRange<Int> { kind == .b ? 10...1000 : 25...255 }
    private var temperatureMax: Int { kind == .b ? 1000 : 255 }

    init(kind: Kind, capabilities: DeviceCapabilities) {
        self.kind = kind
        let layout: (sw: String, mode: String?, brightness: String, temperature: String, colour: String?)
        switch kind {
        case .a: layout = ("1", "2", "3", "4", "5")
        case .b: layout = ("20", "21", "22", "23", "24")
        case .c: layout = ("1", nil, "2", "3", nil)
        }
        // Only keep the DPs this particular bulb really has.
        switchDP = layout.sw
        modeDP = layout.mode
        brightnessDP = capabilities.contains(.brightness) ? layout.brightness : nil
        temperatureDP = capabilities.contains(.colorTemp) ? layout.temperature : nil
        colourDP = capabilities.contains(.color) ? layout.colour : nil
    }

    /// Works out the layout from a status reply. Nil if it doesn't look like a light.
    static func detect(from dps: [String: TuyaValue]) -> (profile: TuyaBulbProfile, capabilities: DeviceCapabilities)? {
        let kind: Kind
        if dps["20"] != nil && dps["1"] != nil { return nil }               // a socket or switch, not a bulb
        else if dps["20"] != nil && dps["21"] != nil { kind = .b }
        else if dps["1"] != nil && dps["2"] != nil { kind = dps["2"]?.stringValue != nil ? .a : .c }
        else { return nil }

        let full = TuyaBulbProfile(kind: kind, capabilities: .fullColor)
        var caps: DeviceCapabilities = [.power]
        if let dp = full.brightnessDP, dps[dp] != nil { caps.insert(.brightness) }
        if let dp = full.temperatureDP, dps[dp] != nil { caps.insert(.colorTemp) }
        if let dp = full.colourDP, dps[dp] != nil { caps.insert(.color) }
        return (TuyaBulbProfile(kind: kind, capabilities: caps), caps)
    }

    // MARK: Reading

    func state(from dps: [String: TuyaValue]) -> BulbState {
        let isOn = dps[switchDP]?.boolValue ?? false
        let mode = modeDP.flatMap { dps[$0]?.stringValue }
        var dimming = 100
        var temperature: Int?
        var rgb: RGB?

        if mode == "colour", let dp = colourDP, let text = dps[dp]?.stringValue, let parsed = parseColour(text) {
            rgb = ColorMath.rgb(hue: parsed.hue, saturation: parsed.saturation, value: 1)
            dimming = Int((parsed.value * 100).rounded())
        } else {
            if let dp = brightnessDP, let raw = dps[dp]?.intValue { dimming = percent(fromBrightness: raw) }
            if let dp = temperatureDP, let raw = dps[dp]?.intValue { temperature = kelvin(fromRaw: raw) }
        }
        return BulbState(isOn: isOn, dimming: max(1, dimming), temperature: temperature, rgb: rgb)
    }

    // MARK: Writing

    /// Whether `command` is ambiguous without knowing the bulb's current mode (white or colour).
    func needsCurrentState(for command: LightCommand) -> Bool {
        guard colourDP != nil else { return false }
        return (command.dimming != nil && command.temp == nil && command.rgb == nil)
            || (command.rgb != nil && command.dimming == nil)
    }

    func dps(for command: LightCommand, current: BulbState?) -> [String: TuyaValue] {
        var out: [String: TuyaValue] = [:]
        if let on = command.state { out[switchDP] = .bool(on) }

        if let rgb = command.rgb, let colourDP {
            if let modeDP { out[modeDP] = .string("colour") }
            let percent = command.dimming ?? current?.dimming ?? 100
            out[colourDP] = .string(encodeColour(hue: ColorMath.hue(of: rgb), saturation: ColorMath.saturation(of: rgb), percent: percent))
        } else if let kelvin = command.temp, let temperatureDP {
            if let modeDP { out[modeDP] = .string("white") }
            out[temperatureDP] = .int(raw(fromKelvin: kelvin))
            if let percent = command.dimming, let brightnessDP { out[brightnessDP] = .int(rawBrightness(fromPercent: percent)) }
        } else if let percent = command.dimming {
            if let rgb = current?.rgb, let colourDP {
                // In colour mode brightness is the V of the colour, not the white brightness DP.
                out[colourDP] = .string(encodeColour(hue: ColorMath.hue(of: rgb), saturation: ColorMath.saturation(of: rgb), percent: percent))
            } else if let brightnessDP {
                out[brightnessDP] = .int(rawBrightness(fromPercent: percent))
            }
        }
        return out
    }

    // MARK: Scaling

    private func rawBrightness(fromPercent percent: Int) -> Int {
        let p = min(max(percent, 1), 100)
        return kind == .b
            ? min(max(p * 10, brightnessRange.lowerBound), brightnessRange.upperBound)
            : Int((Double(brightnessRange.lowerBound) + Double(brightnessRange.upperBound - brightnessRange.lowerBound) * Double(p) / 100).rounded())
    }

    private func percent(fromBrightness raw: Int) -> Int {
        kind == .b
            ? Int((Double(raw) / 10).rounded())
            : Int((Double(raw - brightnessRange.lowerBound) / Double(brightnessRange.upperBound - brightnessRange.lowerBound) * 100).rounded())
    }

    private func raw(fromKelvin kelvin: Int) -> Int {
        let span = Double(Self.coolestKelvin - Self.warmestKelvin)
        let f = min(max(Double(kelvin - Self.warmestKelvin) / span, 0), 1)
        return Int((f * Double(temperatureMax)).rounded())
    }

    private func kelvin(fromRaw raw: Int) -> Int {
        let f = Double(min(max(raw, 0), temperatureMax)) / Double(temperatureMax)
        return Int((Double(Self.warmestKelvin) + f * Double(Self.coolestKelvin - Self.warmestKelvin)).rounded())
    }

    // MARK: Colour strings

    /// B: `hhhhssssvvvv` (hex, hue 0-360, sat/val 0-1000). A: `rrggbbhhhhssvv` (hex, sat/val 0-255).
    private func encodeColour(hue: Double, saturation: Double, percent: Int) -> String {
        let value = Double(min(max(percent, 10), 100)) / 100
        let h = Int((hue * 360).rounded()) % 361
        if kind == .b {
            return String(format: "%04x%04x%04x", h, Int((saturation * 1000).rounded()), Int((value * 1000).rounded()))
        }
        let rgb = ColorMath.rgb(hue: hue, saturation: saturation, value: value)
        return String(format: "%02x%02x%02x%04x%02x%02x", rgb.r, rgb.g, rgb.b, h, Int((saturation * 255).rounded()), Int((value * 255).rounded()))
    }

    private func parseColour(_ text: String) -> (hue: Double, saturation: Double, value: Double)? {
        func number(_ start: Int, _ length: Int) -> Int? {
            guard text.count >= start + length else { return nil }
            let s = text.index(text.startIndex, offsetBy: start)
            return Int(text[s..<text.index(s, offsetBy: length)], radix: 16)
        }
        if kind == .b {
            guard text.count == 12, let h = number(0, 4), let s = number(4, 4), let v = number(8, 4) else { return nil }
            return (Double(h) / 360, Double(s) / 1000, Double(v) / 1000)
        }
        guard text.count == 14, let h = number(6, 4), let s = number(10, 2), let v = number(12, 2) else { return nil }
        return (Double(h) / 360, Double(s) / 255, Double(v) / 255)
    }
}
