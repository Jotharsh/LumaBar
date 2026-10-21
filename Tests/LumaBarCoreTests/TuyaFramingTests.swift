import XCTest
@testable import LumaBarCore

private func hex(_ s: String) -> Data {
    var data = Data()
    var index = s.startIndex
    while index < s.endIndex {
        let next = s.index(index, offsetBy: 2)
        data.append(UInt8(s[index..<next], radix: 16)!)
        index = next
    }
    return data
}

final class TuyaCryptoTests: XCTestCase {
    func testAESECBMatchesNISTVector() throws {
        // NIST SP 800-38A, F.1.1 ECB-AES128.Encrypt, block 1.
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let plain = hex("6bc1bee22e409f96e93d7e117393172a")
        let cipher = try TuyaCrypto.aesECB(encrypt: true, key: key, data: plain, pad: false)
        XCTAssertEqual(cipher, hex("3ad77bb40d7a3660a89ecaf32466ef97"))
        XCTAssertEqual(try TuyaCrypto.aesECB(encrypt: false, key: key, data: cipher, pad: false), plain)
    }

    func testPKCS7PaddingRoundTripAndLength() throws {
        let key = Data("0123456789abcdef".utf8)
        let sixteen = Data(repeating: 7, count: 16)
        let cipher = try TuyaCrypto.aesECB(encrypt: true, key: key, data: sixteen)
        XCTAssertEqual(cipher.count, 32, "a full block gets a whole extra padding block")
        XCTAssertEqual(try TuyaCrypto.aesECB(encrypt: false, key: key, data: cipher), sixteen)
        XCTAssertEqual(try TuyaCrypto.aesECB(encrypt: true, key: key, data: Data("{}".utf8)).count, 16)
    }

    func testWrongKeyIsReportedAsAnAuthenticationProblem() throws {
        let cipher = try TuyaCrypto.aesECB(encrypt: true, key: Data("0123456789abcdef".utf8), data: Data("hello world".utf8))
        XCTAssertThrowsError(try TuyaCrypto.aesECB(encrypt: false, key: Data("fedcba9876543210".utf8), data: cipher)) {
            XCTAssertTrue(($0 as? DriverError).map { if case .authentication = $0 { return true } else { return false } } ?? false)
        }
    }

    func testKeyOfTheWrongLengthIsRejected() {
        XCTAssertThrowsError(try TuyaCrypto.aesECB(encrypt: true, key: Data("short".utf8), data: Data([1])))
    }

    func testCRC32CheckValue() {
        XCTAssertEqual(TuyaCrypto.crc32(Data("123456789".utf8)), 0xCBF43926)
    }

    func testHMACSHA256MatchesRFC4231() {
        let mac = TuyaCrypto.hmacSHA256(key: Data(repeating: 0x0b, count: 20), data: Data("Hi There".utf8))
        XCTAssertEqual(mac, hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"))
    }
}

final class TuyaFramingTests: XCTestCase {
    /// Assembled by hand from the format description, not with the encoder under test.
    func testRequestFrameLayoutWithCRC() {
        let payload = Data("hello".utf8)
        var expected = hex("000055AA") + hex("00000001") + hex("00000007") + hex("0000000D") + payload   // length = 5 + 4 (crc) + 4 (suffix)
        expected += TuyaFraming.be(TuyaCrypto.crc32(expected)) + hex("0000AA55")

        XCTAssertEqual(TuyaFraming.encode(sequence: 1, command: 7, payload: payload, hmacKey: nil), expected)
        XCTAssertEqual(expected.count, 16 + 13)
    }

    func testRequestFrameLayoutWithHMAC() {
        let key = Data("0123456789abcdef".utf8)
        let payload = Data("hello".utf8)
        // length = 5 + 32 (hmac) + 4 (suffix)
        var expected = hex("000055AA") + hex("00000002") + hex("0000000D") + hex("00000029") + payload
        expected += TuyaCrypto.hmacSHA256(key: key, data: expected) + hex("0000AA55")

        XCTAssertEqual(TuyaFraming.encode(sequence: 2, command: 0x0d, payload: payload, hmacKey: key), expected)
    }

    func testResponseFrameCarriesAReturnCodeInsideTheLength() {
        let frame = TuyaFraming.encode(sequence: 9, command: 0x0a, payload: Data("x".utf8), hmacKey: nil, returnCode: 0)
        XCTAssertEqual(TuyaFraming.u32(frame, 12), UInt32(4 + 1 + 4 + 4))
        XCTAssertEqual(frame.subdata(in: 16..<20), hex("00000000"))
    }

    func testRoundTripBothChecksumKinds() throws {
        let key = Data("0123456789abcdef".utf8)
        for hmac in [nil, key] {
            let encoded = TuyaFraming.encode(sequence: 5, command: 0x10, payload: Data("{\"a\":1}".utf8), hmacKey: hmac, returnCode: 0)
            let decoded = try XCTUnwrap(try TuyaFraming.decode(encoded, hmacKey: hmac, hasReturnCode: true))
            XCTAssertEqual(decoded.frame, TuyaFrame(sequence: 5, command: 0x10, returnCode: 0, payload: Data("{\"a\":1}".utf8)))
            XCTAssertEqual(decoded.consumed, encoded.count)
        }
    }

    func testIncompleteBuffersAskForMoreBytes() throws {
        let encoded = TuyaFraming.encode(sequence: 1, command: 7, payload: Data("abc".utf8), hmacKey: nil)
        for cut in [0, 3, 15, 16, encoded.count - 1] {
            XCTAssertNil(try TuyaFraming.decode(encoded.prefix(cut), hmacKey: nil, hasReturnCode: false), "cut at \(cut)")
        }
    }

    func testTwoFramesInOneBufferAreSplitCorrectly() throws {
        let a = TuyaFraming.encode(sequence: 1, command: 7, payload: Data("one".utf8), hmacKey: nil)
        let b = TuyaFraming.encode(sequence: 2, command: 8, payload: Data("two".utf8), hmacKey: nil)
        let first = try XCTUnwrap(try TuyaFraming.decode(a + b, hmacKey: nil, hasReturnCode: false))
        XCTAssertEqual(first.consumed, a.count)
        let second = try XCTUnwrap(try TuyaFraming.decode(Data((a + b).dropFirst(first.consumed)), hmacKey: nil, hasReturnCode: false))
        XCTAssertEqual(second.frame.payload, Data("two".utf8))
    }

    func testCorruptedFrameIsRejected() {
        var frame = TuyaFraming.encode(sequence: 1, command: 7, payload: Data("abc".utf8), hmacKey: nil)
        frame[17] ^= 0xFF
        XCTAssertThrowsError(try TuyaFraming.decode(frame, hmacKey: nil, hasReturnCode: false))
        XCTAssertThrowsError(try TuyaFraming.decode(Data(repeating: 0, count: 40), hmacKey: nil, hasReturnCode: false))
    }

    func testWrongHMACKeyIsAnAuthenticationError() {
        let frame = TuyaFraming.encode(sequence: 1, command: 7, payload: Data("abc".utf8), hmacKey: Data("0123456789abcdef".utf8))
        XCTAssertThrowsError(try TuyaFraming.decode(frame, hmacKey: Data("fedcba9876543210".utf8), hasReturnCode: false)) {
            guard case .authentication = $0 as? DriverError else { return XCTFail("\($0)") }
        }
    }

    func testVersionHeaderIsThreeDotXPlusTwelveZeros() {
        XCTAssertEqual(TuyaVersion.v33.versionHeader, Data("3.3".utf8) + Data(count: 12))
        XCTAssertEqual(TuyaVersion.v34.versionHeader.count, 15)
    }
}
