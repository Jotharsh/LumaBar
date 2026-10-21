import Foundation

/// Keeps a bulb under Yeelight's command quota (about 60 a minute). Callers ask `reserve` how long to wait
/// before sending; it also spaces commands slightly so a slider drag doesn't flood the bulb.
struct YeelightRateLimiter {
    var maxPerMinute = 55
    var minimumSpacing: TimeInterval = 0.25
    private var sent: [Date] = []

    init(maxPerMinute: Int = 55, minimumSpacing: TimeInterval = 0.25) {
        self.maxPerMinute = maxPerMinute
        self.minimumSpacing = minimumSpacing
    }

    /// Records a send and returns how long the caller must wait before making it.
    mutating func reserve(now: Date) -> TimeInterval {
        sent.removeAll { now.timeIntervalSince($0) >= 60 }
        var sendAt = now
        if let last = sent.last { sendAt = max(sendAt, last.addingTimeInterval(minimumSpacing)) }
        if sent.count >= maxPerMinute {
            // The window is full: wait until the oldest command in it is a minute old.
            sendAt = max(sendAt, sent[sent.count - maxPerMinute].addingTimeInterval(60))
        }
        sent.append(sendAt)
        return max(0, sendAt.timeIntervalSince(now))
    }
}

/// Yeelight bulbs over the LAN (TCP 55443). LAN Control must be switched on in the Yeelight app.
public final class YeelightDriver: BulbDriver {
    public static let driverID = "yeelight"
    public let id = YeelightDriver.driverID
    public let displayName = "Yeelight"
    public let brand = "Yeelight"
    public let supportsManualIP = true

    private let connector: ByteConnector
    private let searchTargets: [(host: String, port: UInt16)]
    private let searchDuration: TimeInterval
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let state = Locked()

    /// How long a "the light is on" observation is trusted before power is re-sent.
    private let powerCacheLifetime: TimeInterval = 30

    private final class Locked: @unchecked Sendable {
        let lock = NSLock()
        var limiters: [String: YeelightRateLimiter] = [:]
        var powerSeen: [String: (on: Bool, at: Date)] = [:]
        var nextRequestID = 0
    }

    public init(connector: @escaping ByteConnector = { host, port in try await NWByteChannel.connect(host: host, port: port) },
                searchTargets: [(host: String, port: UInt16)]? = nil,
                searchDuration: TimeInterval = 2.0,
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.connector = connector
        self.searchTargets = searchTargets ?? [(YeelightProtocol.searchAddress, YeelightProtocol.searchPort)]
        self.searchDuration = searchDuration
        self.sleeper = sleeper
    }

    public var help: DriverHelp {
        DriverHelp(
            driverName: "Yeelight",
            unreachable: "Turn on LAN Control for this bulb in the Yeelight app (open the bulb, then its settings, then LAN Control), and make sure your Mac is on the same Wi-Fi.",
            checks: [
                "Some newer Yeelight app versions and bulb models hide LAN Control. If you can't find it, check the Yeelight forum for your model.",
                "The bulb must be powered on and on the same network as your Mac, not a guest network.",
                "Routers with \"client isolation\" block local traffic between devices.",
                "Yeelight bulbs accept about 60 commands a minute, so LumaBar slows down very fast slider changes.",
            ],
            setup: [
                "Set the bulb up in the Yeelight app first.",
                "In the Yeelight app, open the bulb, tap its settings, and turn on LAN Control.",
                "Keep your Mac on the same Wi-Fi as the bulb, then use Search Network.",
                "If a bulb isn't found, add it by its IP address.",
            ])
    }

    // MARK: Discovery

    public func discover() async -> [Bulb] {
        let replies = await UDPProbe.collect(payload: YeelightProtocol.searchMessage, targets: searchTargets, duration: searchDuration)
        var found: [String: Bulb] = [:]
        for reply in replies {
            guard let ad = YeelightProtocol.parseAdvertisement(reply) else { continue }
            found[ad.id] = bulb(from: ad)
        }
        return found.values.sorted { $0.id < $1.id }
    }

    private func bulb(from ad: YeelightProtocol.Advertisement) -> Bulb {
        Bulb(id: "\(id):\(ad.id)", name: ad.name.isEmpty ? "Yeelight \(ad.id.suffix(4))" : ad.name, brand: brand, driverID: id,
             capabilities: ad.capabilities, address: ad.host, native: ["port": String(ad.port), "model": ad.model])
    }

    /// Manual add: asks the bulb for its properties. Capabilities are inferred, since a direct query
    /// (unlike discovery) doesn't list the supported methods: an empty `rgb`/`ct` means "not a colour bulb".
    public func probe(host: String) async throws -> Bulb {
        let values = try await run(host: host, port: YeelightProtocol.port, key: host, [("get_prop", ["power", "bright", "ct", "rgb", "name"])])
        guard let props = values.first, props.count >= 5 else { throw DriverError.protocolError("The bulb sent an unexpected reply.") }
        var caps: DeviceCapabilities = [.power]
        if !props[1].isEmpty { caps.insert(.brightness) }
        if !props[2].isEmpty { caps.insert(.colorTemp) }
        if !props[3].isEmpty { caps.insert(.color) }
        let name = props[4].isEmpty ? "Yeelight \(host.split(separator: ".").last ?? "")" : props[4]
        return Bulb(id: "\(id):\(host)", name: name, brand: brand, driverID: id, capabilities: caps, address: host,
                    native: ["port": String(YeelightProtocol.port)])
    }

    // MARK: Control

    public func getState(of bulb: Bulb) async throws -> BulbState {
        let values = try await run(bulb, [("get_prop", ["power", "bright", "ct", "rgb", "color_mode"])])
        guard let props = values.first, props.count >= 5 else { throw DriverError.protocolError("The bulb sent an unexpected reply.") }
        let isOn = props[0] == "on"
        remember(power: isOn, for: bulb)
        let mode = props[4]
        let rgbValue = Int(props[3])
        return BulbState(isOn: isOn,
                         dimming: Int(props[1]) ?? 100,
                         temperature: mode == "1" ? nil : Int(props[2]),
                         rgb: mode == "1" ? rgbValue.map { RGB(r: $0 >> 16 & 0xFF, g: $0 >> 8 & 0xFF, b: $0 & 0xFF) } : nil)
    }

    public func apply(_ command: LightCommand, to bulb: Bulb) async throws {
        var requests: [(String, [Any])] = []
        let transition: [Any] = ["smooth", 300]

        if command.state == false {
            requests.append(("set_power", ["off"] + transition))
        } else {
            if command.state == true, !knownOn(bulb) { requests.append(("set_power", ["on"] + transition)) }
            if let rgb = command.rgb {
                requests.append(("set_rgb", [rgb.r << 16 | rgb.g << 8 | rgb.b] + transition))
            } else if let kelvin = command.temp {
                requests.append(("set_ct_abx", [kelvin] + transition))
            }
            if let percent = command.dimming { requests.append(("set_bright", [percent] + transition)) }
        }
        guard !requests.isEmpty else { return }
        _ = try await run(bulb, requests)
        if let on = command.state { remember(power: on, for: bulb) }
    }

    // MARK: Plumbing

    private func knownOn(_ bulb: Bulb) -> Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        guard let seen = state.powerSeen[bulb.id], seen.on, Date().timeIntervalSince(seen.at) < powerCacheLifetime else { return false }
        return true
    }

    private func remember(power on: Bool, for bulb: Bulb) {
        state.lock.lock(); state.powerSeen[bulb.id] = (on, Date()); state.lock.unlock()
    }

    private func run(_ bulb: Bulb, _ requests: [(String, [Any])]) async throws -> [[String]] {
        try await run(host: bulb.address, port: bulb.native["port"].flatMap { UInt16($0) } ?? YeelightProtocol.port, key: bulb.id, requests)
    }

    /// One connection per operation; requests go out one at a time, each waiting for its own reply.
    private func run(host: String, port: UInt16, key: String, _ requests: [(String, [Any])]) async throws -> [[String]] {
        let channel: ByteChannel
        do {
            channel = try await connector(host, port)
        } catch DriverError.unreachable(let reason) {
            throw DriverError.unreachable("\(reason) If the bulb is on and on this network, LAN Control is probably off in the Yeelight app.")
        }
        defer { channel.close() }

        var buffer = Data()
        var results: [[String]] = []
        for (method, params) in requests {
            let delay = reserveSlot(for: key)
            if delay > 0 { await sleeper(delay) }

            let id = nextID()
            try await channel.send(YeelightProtocol.request(id: id, method: method, params: params))

            replyLoop: while true {
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let (replyID, reply) = YeelightProtocol.parseReply(line) else { continue }
                    if case .notification = reply { continue }       // a state-change broadcast, not our answer
                    guard replyID == id else { continue }
                    switch reply {
                    case .ok(let values): results.append(values); break replyLoop
                    case .error(let code, let message): throw Self.translate(code: code, message: message)
                    case .notification: break
                    }
                }
                buffer.append(try await channel.receive())
            }
        }
        return results
    }

    private func reserveSlot(for key: String) -> TimeInterval {
        state.lock.lock(); defer { state.lock.unlock() }
        var limiter = state.limiters[key] ?? YeelightRateLimiter()
        let delay = limiter.reserve(now: Date())
        state.limiters[key] = limiter
        return delay
    }

    private func nextID() -> Int {
        state.lock.lock(); defer { state.lock.unlock() }
        state.nextRequestID += 1
        return state.nextRequestID
    }

    static func translate(code: Int, message: String) -> DriverError {
        if message.contains("quota") { return .rejected("The bulb is rate limiting commands. Try again in a moment.") }
        if message.contains("unsupported") { return .unsupported("This bulb doesn't support that.") }
        return .rejected(message)
    }
}
