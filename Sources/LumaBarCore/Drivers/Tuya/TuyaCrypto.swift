import Foundation
import CommonCrypto
import CryptoKit

/// The primitives Tuya's local protocol is built from. All system frameworks, no dependencies.
enum TuyaCrypto {
    private static let wrongKey = "Couldn't decrypt the device's reply. The local key is probably wrong."

    /// AES-128 in ECB mode, which is what Tuya uses for the 3.x protocols. `pad` = PKCS#7.
    ///
    /// Padding is done here rather than by CommonCrypto: its ECB mode doesn't validate padding when
    /// decrypting, so a wrong key would "succeed" and return garbage. Checking it strictly turns a
    /// wrong key into a clear error (about 255 times in 256 for a single block).
    static func aesECB(encrypt: Bool, key: Data, data: Data, pad: Bool = true) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw DriverError.authentication("The local key must be exactly 16 characters.")
        }
        var input = data
        if encrypt && pad {
            let padding = kCCBlockSizeAES128 - data.count % kCCBlockSizeAES128
            input.append(Data(repeating: UInt8(padding), count: padding))
        }
        guard input.count % kCCBlockSizeAES128 == 0 else {
            throw DriverError.authentication(encrypt ? "Internal error: data isn't block aligned." : wrongKey)
        }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count, nil,
                            inBytes.baseAddress, input.count,
                            out.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw DriverError.authentication(wrongKey) }
        output.removeSubrange(written...)

        if !encrypt && pad {
            guard let last = output.last, last >= 1, Int(last) <= kCCBlockSizeAES128, output.count >= Int(last),
                  output.suffix(Int(last)).allSatisfy({ $0 == last }) else {
                throw DriverError.authentication(wrongKey)
            }
            output.removeLast(Int(last))
        }
        return output
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
