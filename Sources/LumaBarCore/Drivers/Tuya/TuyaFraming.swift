import Foundation

public enum TuyaVersion: String, Codable, CaseIterable, Sendable {
    case v33 = "3.3"
    case v34 = "3.4"

    /// "3.x" followed by 12 zero bytes, prepended to the payload of control-style commands.
    var versionHeader: Data { Data(rawValue.utf8) + Data(count: 12) }
}

enum TuyaCommand {
    static let sessionKeyStart: UInt32 = 3
    static let sessionKeyResponse: UInt32 = 4
    static let sessionKeyFinish: UInt32 = 5
    static let control: UInt32 = 7
    static let status: UInt32 = 8
    static let heartbeat: UInt32 = 9
    static let dpQuery: UInt32 = 0x0a
    static let controlNew: UInt32 = 0x0d
    static let dpQueryNew: UInt32 = 0x10

    /// Commands whose payload doesn't get the "3.x" version header.
    static let noVersionHeader: Set<UInt32> = [dpQuery, dpQueryNew, heartbeat, sessionKeyStart, sessionKeyResponse, sessionKeyFinish]
}

struct TuyaFrame: Equatable {
    var sequence: UInt32
    var command: UInt32
    /// Present on frames sent by the device; absent on frames sent to it.
    var returnCode: UInt32?
    var payload: Data
}

/// The 0x55AA frame format:
///
///     prefix(4) = 000055AA | seq(4) | cmd(4) | length(4) | [retcode(4)] | payload | checksum | suffix(4) = 0000AA55
///
/// `length` counts everything after itself. The checksum is a CRC32 (4 bytes) for 3.3, or an
/// HMAC-SHA256 (32 bytes) keyed with the session key for 3.4. All integers are big-endian.
enum TuyaFraming {
    static let prefix: UInt32 = 0x000055AA
    static let suffix: UInt32 = 0x0000AA55
    static let headerLength = 16

    static func encode(sequence: UInt32, command: UInt32, payload: Data, hmacKey: Data?, returnCode: UInt32? = nil) -> Data {
        let checksumLength = hmacKey == nil ? 4 : 32
        let body = (returnCode.map { be($0) } ?? Data()) + payload
        var frame = be(prefix) + be(sequence) + be(command) + be(UInt32(body.count + checksumLength + 4)) + body
        if let hmacKey {
            frame += TuyaCrypto.hmacSHA256(key: hmacKey, data: frame)
        } else {
            frame += be(TuyaCrypto.crc32(frame))
        }
        return frame + be(suffix)
    }

    /// Parses one frame from the start of `buffer`. Returns nil if more bytes are needed.
    static func decode(_ buffer: Data, hmacKey: Data?, hasReturnCode: Bool) throws -> (frame: TuyaFrame, consumed: Int)? {
        let buffer = Data(buffer) // normalise indices
        guard buffer.count >= headerLength else { return nil }
        guard u32(buffer, 0) == prefix else { throw DriverError.protocolError("Not a Tuya frame (bad prefix).") }
        let length = Int(u32(buffer, 12))
        guard length <= 16 * 1024 else { throw DriverError.protocolError("Tuya frame is implausibly large.") }
        let total = headerLength + length
        guard buffer.count >= total else { return nil }

        let checksumLength = hmacKey == nil ? 4 : 32
        let retLength = hasReturnCode ? 4 : 0
        guard length >= retLength + checksumLength + 4 else { throw DriverError.protocolError("Tuya frame is too short.") }
        guard u32(buffer, total - 4) == suffix else { throw DriverError.protocolError("Tuya frame has a bad suffix.") }

        let checkedEnd = total - 4 - checksumLength
        let covered = buffer.subdata(in: 0..<checkedEnd)
        let checksum = buffer.subdata(in: checkedEnd..<(total - 4))
        if let hmacKey {
            guard TuyaCrypto.hmacSHA256(key: hmacKey, data: covered) == checksum else {
                throw DriverError.authentication("Tuya reply failed its integrity check. The local key is probably wrong.")
            }
        } else {
            guard be(TuyaCrypto.crc32(covered)) == checksum else { throw DriverError.protocolError("Tuya frame failed its CRC check.") }
        }

        let returnCode = hasReturnCode ? u32(buffer, headerLength) : nil
        let payload = buffer.subdata(in: (headerLength + retLength)..<checkedEnd)
        let frame = TuyaFrame(sequence: u32(buffer, 4), command: u32(buffer, 8), returnCode: returnCode, payload: payload)
        return (frame, total)
    }

    static func be(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }
}
