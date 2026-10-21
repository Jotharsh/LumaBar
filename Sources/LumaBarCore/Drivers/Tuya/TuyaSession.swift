import Foundation

/// A JSON scalar as Tuya data points carry them.
public enum TuyaValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)

    var jsonObject: Any {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v
        case .string(let v): return v
        }
    }

    init?(json: Any) {
        if let n = json as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .int(n.intValue) }
        } else if let s = json as? String {
            self = .string(s)
        } else {
            return nil
        }
    }

    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var intValue: Int? { if case .int(let v) = self { return v }; return nil }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
}

/// One conversation with a Tuya bulb over one connection: (for 3.4) negotiate a session key, then query or set data points.
final class TuyaSession {
    private let channel: ByteChannel
    private let deviceID: String
    private let version: TuyaVersion
    private let localKey: Data
    private var sessionKey: Data?
    private var sequence: UInt32 = 0
    private var buffer = Data()

    init(channel: ByteChannel, deviceID: String, localKey: Data, version: TuyaVersion) {
        self.channel = channel
        self.deviceID = deviceID
        self.localKey = localKey
        self.version = version
    }

    func close() { channel.close() }

    /// The key payloads are encrypted with and (for 3.4) frames are signed with.
    private var activeKey: Data { sessionKey ?? localKey }
    private var hmacKey: Data? { version == .v34 ? activeKey : nil }

    // MARK: 3.4 session key negotiation

    /// Client nonce -> device nonce + proof -> our proof. The session key is the XOR of both nonces,
    /// encrypted with the local key. Fails with an authentication error if the local key is wrong.
    func negotiate(clientNonce: Data = TuyaCrypto.randomBytes(16)) async throws {
        guard version == .v34 else { return }

        // 1. Send our nonce (encrypted and signed with the local key).
        try await send(command: TuyaCommand.sessionKeyStart, payload: clientNonce, encryptWith: localKey, hmacKey: localKey)

        // 2. The device answers with its own nonce followed by HMAC(localKey, our nonce).
        // We're already connected, so silence here means it ignored our key exchange: wrong key, or not a 3.4 device.
        let reply: TuyaFrame
        do {
            reply = try await receiveFrame(expecting: [TuyaCommand.sessionKeyResponse], hmacKey: localKey)
        } catch DriverError.unreachable {
            throw DriverError.authentication("The bulb ignored the secure handshake. The local key is probably wrong, or this bulb doesn't use protocol 3.4.")
        }
        guard reply.returnCode ?? 0 == 0 else { throw DriverError.authentication("The device refused to start a session.") }
        let plain = try TuyaCrypto.aesECB(encrypt: false, key: localKey, data: reply.payload)
        guard plain.count >= 48 else { throw DriverError.protocolError("The session reply was too short.") }
        let deviceNonce = plain.prefix(16)
        guard TuyaCrypto.hmacSHA256(key: localKey, data: clientNonce) == plain.subdata(in: 16..<48) else {
            throw DriverError.authentication("The device's session proof didn't match. The local key is probably wrong.")
        }

        // 3. Prove we know the key too.
        try await send(command: TuyaCommand.sessionKeyFinish,
                       payload: TuyaCrypto.hmacSHA256(key: localKey, data: Data(deviceNonce)),
                       encryptWith: localKey, hmacKey: localKey)

        let mixed = Data(zip(clientNonce, deviceNonce).map { $0 ^ $1 })
        sessionKey = try TuyaCrypto.aesECB(encrypt: true, key: localKey, data: mixed, pad: false)
    }

    // MARK: Data points

    func queryStatus() async throws -> [String: TuyaValue] {
        let command = version == .v34 ? TuyaCommand.dpQueryNew : TuyaCommand.dpQuery
        let body: Data
        if version == .v34 {
            body = Data("{}".utf8)
        } else {
            body = try json(["gwId": deviceID, "devId": deviceID, "uid": deviceID, "t": String(Int(Date().timeIntervalSince1970))])
        }
        try await send(command: command, payload: body, encryptWith: activeKey, hmacKey: hmacKey)
        let reply = try await receiveFrame(expecting: [command], hmacKey: hmacKey)
        guard let object = try decodeReply(reply) else { throw DriverError.protocolError("The device returned no status.") }
        return try Self.dps(in: object)
    }

    func setDPS(_ dps: [String: TuyaValue]) async throws {
        let values = dps.mapValues(\.jsonObject)
        let command: UInt32
        let body: Data
        if version == .v34 {
            command = TuyaCommand.controlNew
            body = try json(["protocol": 5, "t": Int(Date().timeIntervalSince1970), "data": ["dps": values]])
        } else {
            command = TuyaCommand.control
            body = try json(["devId": deviceID, "uid": deviceID, "t": String(Int(Date().timeIntervalSince1970)), "dps": values])
        }
        try await send(command: command, payload: body, encryptWith: activeKey, hmacKey: hmacKey)
        let reply = try await receiveFrame(expecting: [command], hmacKey: hmacKey)
        // Success is a zero return code. Some devices add a body; if it can't be read, the command still went through.
        _ = try? decodeReply(reply)
    }

    // MARK: Wire

    private func send(command: UInt32, payload: Data, encryptWith key: Data, hmacKey: Data?) async throws {
        var body = try TuyaCrypto.aesECB(encrypt: true, key: key, data: (version == .v34 && !TuyaCommand.noVersionHeader.contains(command)) ? version.versionHeader + payload : payload)
        if version == .v33 && !TuyaCommand.noVersionHeader.contains(command) {
            body = version.versionHeader + body   // 3.3 leaves the header outside the encryption
        }
        sequence += 1
        try await channel.send(TuyaFraming.encode(sequence: sequence, command: command, payload: body, hmacKey: hmacKey))
    }

    private func receiveFrame(expecting commands: Set<UInt32>, hmacKey: Data?) async throws -> TuyaFrame {
        var skipped = 0
        while true {
            while let (frame, consumed) = try TuyaFraming.decode(buffer, hmacKey: hmacKey, hasReturnCode: true) {
                buffer.removeFirst(consumed)
                if commands.contains(frame.command) { return frame }
                // Status pushes and heartbeats can arrive in between; ignore them, but not forever.
                skipped += 1
                if skipped > 20 { throw DriverError.protocolError("The device never sent the expected reply.") }
            }
            // A frame can arrive in many small TCP segments; keep reading until it's complete.
            // (The channel's own timeout ends the wait if the device goes quiet.)
            buffer.append(try await channel.receive())
        }
    }

    /// Decrypts a reply and parses it as JSON. Nil for an empty (acknowledge-only) reply.
    private func decodeReply(_ frame: TuyaFrame) throws -> [String: Any]? {
        if let code = frame.returnCode, code != 0 {
            throw DriverError.rejected("The device returned error code \(code).")
        }
        var payload = frame.payload
        guard !payload.isEmpty else { return nil }

        let key = activeKey
        let versionBytes = Data(version.rawValue.utf8)
        if version == .v33, payload.starts(with: versionBytes) { payload = payload.dropFirst(15) }
        payload = try TuyaCrypto.aesECB(encrypt: false, key: key, data: Data(payload))
        if payload.starts(with: versionBytes) { payload = payload.dropFirst(15) }
        guard !payload.isEmpty else { return nil }

        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw DriverError.authentication("The device's reply wasn't readable. The local key is probably wrong.")
        }
        return object
    }

    private static func dps(in object: [String: Any]) throws -> [String: TuyaValue] {
        let raw = (object["dps"] as? [String: Any]) ?? ((object["data"] as? [String: Any])?["dps"] as? [String: Any])
        guard let raw else { throw DriverError.protocolError("The device's status had no data points.") }
        return raw.compactMapValues { TuyaValue(json: $0) }
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
