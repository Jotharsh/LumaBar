import Foundation
@testable import LumaBarCore

/// A Tuya bulb implemented from the device's side of the protocol, with no sockets: it validates
/// checksums, runs the 3.4 key exchange, decrypts commands and answers like firmware does.
final class FakeTuya: @unchecked Sendable {
    let deviceID: String
    let deviceKey: Data
    let version: TuyaVersion

    private let lock = NSLock()
    private var _dps: [String: TuyaValue]
    private var _commands: [[String: TuyaValue]] = []
    private var _connections = 0
    private var _active = 0
    private var _maxActive = 0

    /// Bytes per chunk when sending replies (to exercise reassembly). 0 = all at once.
    var chunkSize = 0
    /// Push an unrelated status frame (cmd 8) before every reply.
    var pushesStatusFirst = false
    /// Answer requests that can't be decrypted with encrypted garbage (what a 3.3 device does with a wrong key).
    var answersUndecryptable = true

    init(deviceID: String = "bf1234567890abcdef", key: String = "0123456789abcdef", version: TuyaVersion, dps: [String: TuyaValue]) {
        self.deviceID = deviceID
        self.deviceKey = Data(key.utf8)
        self.version = version
        self._dps = dps
    }

    var dps: [String: TuyaValue] { lock.lock(); defer { lock.unlock() }; return _dps }
    /// Every data-point change the device was asked to make, in order.
    var commands: [[String: TuyaValue]] { lock.lock(); defer { lock.unlock() }; return _commands }
    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }
    var maxConcurrentConnections: Int { lock.lock(); defer { lock.unlock() }; return _maxActive }

    var connector: ByteConnector {
        { [self] _, _ in self.connect() }
    }

    func connect() -> ByteChannel {
        lock.lock(); _connections += 1; _active += 1; _maxActive = max(_maxActive, _active); lock.unlock()
        return Connection(device: self)
    }

    fileprivate func connectionClosed() { lock.lock(); _active -= 1; lock.unlock() }
    fileprivate func apply(_ changes: [String: TuyaValue]) {
        lock.lock(); _commands.append(changes); for (k, v) in changes { _dps[k] = v }; lock.unlock()
    }

    // MARK: One TCP connection

    private final class Connection: ByteChannel, @unchecked Sendable {
        let device: FakeTuya
        private var inbox = Data()
        private var outbox: [Data] = []
        private var localNonce = Data()
        private let deviceNonce = Data((0..<16).map { UInt8(0xA0 + $0) })
        private var sessionKey: Data?
        private var closed = false

        init(device: FakeTuya) { self.device = device }

        func close() { if !closed { closed = true; device.connectionClosed() } }

        private var hmacKey: Data? { device.version == .v34 ? (sessionKey ?? device.deviceKey) : nil }

        func send(_ data: Data) async throws {
            inbox.append(data)
            while true {
                let decoded: (frame: TuyaFrame, consumed: Int)?
                do {
                    decoded = try TuyaFraming.decode(inbox, hmacKey: hmacKey, hasReturnCode: false)
                } catch {
                    // Failed integrity check (e.g. a 3.3 client talking to a 3.4 device, or a wrong key): stay silent.
                    inbox.removeAll()
                    return
                }
                guard let (frame, consumed) = decoded else { return }   // incomplete: wait for more bytes
                inbox.removeFirst(consumed)
                handle(frame)
            }
        }

        func receive() async throws -> Data {
            guard !outbox.isEmpty else { throw DriverError.unreachable("The device didn't answer in time.") }
            return outbox.removeFirst()
        }

        // MARK: Device behaviour

        private func handle(_ frame: TuyaFrame) {
            switch frame.command {
            case TuyaCommand.sessionKeyStart:
                guard let nonce = try? TuyaCrypto.aesECB(encrypt: false, key: device.deviceKey, data: frame.payload), nonce.count == 16 else { return }
                localNonce = nonce
                let body = deviceNonce + TuyaCrypto.hmacSHA256(key: device.deviceKey, data: nonce)
                reply(command: TuyaCommand.sessionKeyResponse, plain: body, key: device.deviceKey, hmac: device.deviceKey)

            case TuyaCommand.sessionKeyFinish:
                guard let proof = try? TuyaCrypto.aesECB(encrypt: false, key: device.deviceKey, data: frame.payload),
                      proof == TuyaCrypto.hmacSHA256(key: device.deviceKey, data: deviceNonce) else { return }
                let mixed = Data(zip(localNonce, deviceNonce).map { $0 ^ $1 })
                sessionKey = try? TuyaCrypto.aesECB(encrypt: true, key: device.deviceKey, data: mixed, pad: false)

            case TuyaCommand.dpQuery:       // 3.3
                guard (try? TuyaCrypto.aesECB(encrypt: false, key: device.deviceKey, data: frame.payload)) != nil else { return undecryptable(frame) }
                reply(command: frame.command, json: ["devId": device.deviceID, "dps": device.dps.mapValues(\.jsonObject)], key: device.deviceKey)

            case TuyaCommand.control:       // 3.3: header sits outside the encryption
                guard frame.payload.starts(with: Data("3.3".utf8)),
                      let plain = try? TuyaCrypto.aesECB(encrypt: false, key: device.deviceKey, data: frame.payload.dropFirst(15)),
                      let json = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
                      let dps = json["dps"] as? [String: Any] else { return undecryptable(frame) }
                device.apply(dps.compactMapValues { TuyaValue(json: $0) })
                reply(command: frame.command, plain: Data(), key: nil)

            case TuyaCommand.dpQueryNew:    // 3.4: the whole payload is encrypted with the session key
                guard let key = sessionKey, (try? TuyaCrypto.aesECB(encrypt: false, key: key, data: frame.payload)) != nil else { return }
                reply(command: frame.command, json: ["data": ["dps": device.dps.mapValues(\.jsonObject)]], key: key, hmac: key)

            case TuyaCommand.controlNew:    // 3.4: version header is inside the encryption
                guard let key = sessionKey,
                      let plain = try? TuyaCrypto.aesECB(encrypt: false, key: key, data: frame.payload),
                      plain.starts(with: Data("3.4".utf8)),
                      let json = try? JSONSerialization.jsonObject(with: plain.dropFirst(15)) as? [String: Any],
                      let dps = (json["data"] as? [String: Any])?["dps"] as? [String: Any] else { return }
                device.apply(dps.compactMapValues { TuyaValue(json: $0) })
                reply(command: frame.command, plain: Data(), key: nil, hmac: key)

            default:
                break
            }
        }

        private func undecryptable(_ frame: TuyaFrame) {
            guard device.answersUndecryptable else { return }
            reply(command: frame.command, json: ["Error": "json obj data unvalid"], key: device.deviceKey)
        }

        private func reply(command: UInt32, json: [String: Any], key: Data) {
            reply(command: command, json: json, key: key, hmac: nil)
        }

        private func reply(command: UInt32, json: [String: Any], key: Data, hmac: Data?) {
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
            reply(command: command, plain: data, key: key, hmac: hmac)
        }

        private func reply(command: UInt32, plain: Data, key: Data?, hmac: Data? = nil) {
            if device.pushesStatusFirst {
                emit(TuyaFraming.encode(sequence: 0, command: TuyaCommand.status, payload: Data(), hmacKey: hmacKey, returnCode: 0))
            }
            let body = key.flatMap { try? TuyaCrypto.aesECB(encrypt: true, key: $0, data: plain) } ?? plain
            emit(TuyaFraming.encode(sequence: 1, command: command, payload: body, hmacKey: hmac ?? (device.version == .v34 ? (sessionKey ?? device.deviceKey) : nil), returnCode: 0))
        }

        private func emit(_ frame: Data) {
            guard device.chunkSize > 0 else { outbox.append(frame); return }
            var rest = frame
            while !rest.isEmpty { outbox.append(rest.prefix(device.chunkSize)); rest = Data(rest.dropFirst(device.chunkSize)) }
        }
    }
}
