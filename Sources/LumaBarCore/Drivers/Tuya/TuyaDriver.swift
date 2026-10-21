import Foundation

/// Tuya / Smart Life bulbs over the local TCP protocol (versions 3.3 and 3.4).
///
/// Tuya bulbs can't be discovered without their secret local key, so setup is manual: the wizard calls
/// `register`, which checks the details against the real bulb before saving anything. The key goes in
/// the `SecretStore` (the Keychain in the app); the saved `Bulb` holds only non-secret details.
public final class TuyaDriver: BulbDriver {
    public static let driverID = "tuya"
    /// Tuya's local control port.
    public static let port: UInt16 = 6668
    public let id = TuyaDriver.driverID
    public let displayName = "Tuya / Smart Life"
    public let brand = "Tuya"

    private let secrets: SecretStore
    private let connector: ByteConnector
    private let locks = DeviceLocks()

    public init(secrets: SecretStore,
                connector: @escaping ByteConnector = { host, port in try await NWByteChannel.connect(host: host, port: port) }) {
        self.secrets = secrets
        self.connector = connector
    }

    public var help: DriverHelp {
        DriverHelp(
            driverName: "Tuya",
            unreachable: "Check the bulb's IP address and local key. The key changes whenever the bulb is re-paired in the Tuya or Smart Life app, and the bulb must be on the same Wi-Fi as your Mac.",
            checks: [
                "Give the bulb a fixed IP in your router, so the saved address doesn't go stale.",
                "Tuya bulbs accept one local connection at a time. Close anything else controlling it locally.",
                "If you re-paired the bulb, its local key changed: fetch the new one and run Setup again.",
                "If auto-detect fails, try choosing protocol version 3.3 or 3.4 yourself.",
            ],
            setup: TuyaHelp.keySteps)
    }

    public func discover() async -> [Bulb] { [] }   // can't be found without its key; see `register`

    // MARK: Setup

    /// Verifies the details against the bulb, then saves the local key. Pass nil `version` to auto-detect.
    public func register(deviceID rawID: String, name: String, host rawHost: String, localKey: String,
                         version: TuyaVersion?) async throws -> Bulb {
        let deviceID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = localKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(deviceID: deviceID, host: host, localKey: key)

        var failures: [Error] = []
        for candidate in version.map({ [$0] }) ?? TuyaVersion.allCases {
            do {
                let dps = try await locks.withLock(deviceID) {
                    try await self.withSession(host: host, deviceID: deviceID, key: Data(key.utf8), version: candidate) {
                        try await $0.queryStatus()
                    }
                }
                guard let (profile, capabilities) = TuyaBulbProfile.detect(from: dps) else {
                    throw DriverError.unsupported("This device doesn't look like a light bulb (data points: \(dps.keys.sorted().joined(separator: ", "))).")
                }
                try secrets.set(key, for: Self.secretKey(deviceID))
                return Bulb(id: "\(id):\(deviceID)", name: name.isEmpty ? "Tuya \(deviceID.suffix(4))" : name,
                            brand: brand, driverID: id, capabilities: capabilities, address: host,
                            native: ["deviceID": deviceID, "version": candidate.rawValue, "kind": profile.kind.rawValue])
            } catch {
                failures.append(error)
            }
        }
        // Report the most useful reason: a bad key beats "no answer", which beats a wrong-version guess.
        throw failures.first { ($0 as? DriverError).map { if case .authentication = $0 { return true } else { return false } } ?? false }
            ?? failures.first { ($0 as? DriverError).map { if case .unreachable = $0 { return true } else { return false } } ?? false }
            ?? failures.last ?? DriverError.unreachable("No answer from the bulb.")
    }

    static func validate(deviceID: String, host: String, localKey: String) throws {
        guard !deviceID.isEmpty else { throw DriverError.notConfigured("Enter the device ID.") }
        guard host.split(separator: ".").count == 4, host.split(separator: ".").allSatisfy({ UInt8($0) != nil }) else {
            throw DriverError.notConfigured("Enter the bulb's IPv4 address, like 192.168.1.50.")
        }
        guard localKey.utf8.count == 16 else {
            throw DriverError.notConfigured("The local key must be exactly 16 characters (it's \(localKey.utf8.count)). Copy it again from your Tuya developer account.")
        }
    }

    static func secretKey(_ deviceID: String) -> String { "tuya.localKey.\(deviceID)" }

    public func forget(_ bulb: Bulb) {
        if let deviceID = bulb.native["deviceID"] { try? secrets.set(nil, for: Self.secretKey(deviceID)) }
    }

    // MARK: Control

    private struct Context {
        let deviceID: String
        let key: Data
        let version: TuyaVersion
        let profile: TuyaBulbProfile
    }

    private func context(for bulb: Bulb) throws -> Context {
        guard let deviceID = bulb.native["deviceID"], let versionText = bulb.native["version"],
              let version = TuyaVersion(rawValue: versionText),
              let kind = bulb.native["kind"].flatMap(TuyaBulbProfile.Kind.init(rawValue:)) else {
            throw DriverError.notConfigured("\(bulb.name) needs to be set up again.")
        }
        guard let key = secrets.get(Self.secretKey(deviceID)) else {
            throw DriverError.authentication("The local key for \(bulb.name) is missing. Run Tuya setup again.")
        }
        return Context(deviceID: deviceID, key: Data(key.utf8), version: version,
                       profile: TuyaBulbProfile(kind: kind, capabilities: bulb.capabilities))
    }

    public func getState(of bulb: Bulb) async throws -> BulbState {
        let ctx = try context(for: bulb)
        let dps = try await locks.withLock(ctx.deviceID) {
            try await self.withSession(host: bulb.address, deviceID: ctx.deviceID, key: ctx.key, version: ctx.version) {
                try await $0.queryStatus()
            }
        }
        return ctx.profile.state(from: dps)
    }

    public func apply(_ command: LightCommand, to bulb: Bulb) async throws {
        let ctx = try context(for: bulb)
        try await locks.withLock(ctx.deviceID) {
            try await self.withSession(host: bulb.address, deviceID: ctx.deviceID, key: ctx.key, version: ctx.version) { session in
                var current: BulbState?
                if ctx.profile.needsCurrentState(for: command) {
                    current = ctx.profile.state(from: try await session.queryStatus())
                }
                let dps = ctx.profile.dps(for: command, current: current)
                if !dps.isEmpty { try await session.setDPS(dps) }
            }
        }
    }

    /// One connection per operation: connect, (3.4) negotiate a session key, run, close.
    private func withSession<T>(host: String, deviceID: String, key: Data, version: TuyaVersion,
                                _ body: (TuyaSession) async throws -> T) async throws -> T {
        let channel = try await connector(host, TuyaDriver.port)
        let session = TuyaSession(channel: channel, deviceID: deviceID, localKey: key, version: version)
        defer { session.close() }
        try await session.negotiate()
        return try await body(session)
    }
}

/// Plain-language instructions for finding a Tuya bulb's local key.
public enum TuyaHelp {
    public static let keySteps = [
        "Set the bulb up in the Tuya Smart or Smart Life app first.",
        "Create a free account at iot.tuya.com and make a Cloud project (the \"Smart Home\" kind is the usual choice).",
        "In that project, link your Tuya/Smart Life app account (its Devices tab has a \"Link App Account\" option that shows a QR code to scan with the app).",
        "Once linked, your bulb appears in the project's device list. Note its Device ID.",
        "Get the local key: in the project's API Explorer, query the device's details, or run \"python -m tinytuya wizard\" and enter the project's Access ID and Secret. The key is 16 characters.",
        "Find the bulb's IP address in your router's device list, ideally reserving it so it never changes.",
        "Enter the Device ID, IP address and local key in LumaBar. The key is stored in your Keychain.",
        "If you ever re-pair the bulb in the Tuya app, its key changes. Fetch the new one and run setup again.",
    ]

    public static let guideURL = "https://github.com/jasonacox/tinytuya#setup-wizard---getting-local-keys"
}

/// Serialises operations per device: Tuya bulbs accept only one local connection at a time.
final class DeviceLocks: @unchecked Sendable {
    private actor Mutex {
        private var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !held { held = true; return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
        }
    }

    private let lock = NSLock()
    private var mutexes: [String: Mutex] = [:]

    private func mutex(_ key: String) -> Mutex {
        lock.lock(); defer { lock.unlock() }
        if let existing = mutexes[key] { return existing }
        let created = Mutex()
        mutexes[key] = created
        return created
    }

    func withLock<T>(_ key: String, _ body: () async throws -> T) async throws -> T {
        let m = mutex(key)
        await m.acquire()
        do {
            let result = try await body()
            await m.release()
            return result
        } catch {
            await m.release()
            throw error
        }
    }
}
