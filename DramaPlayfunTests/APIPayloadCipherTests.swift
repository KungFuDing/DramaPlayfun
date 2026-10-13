import XCTest
import CryptoKit
@testable import DramaPlayfun

final class APIPayloadCipherTests: XCTestCase {
    func testDecryptsIndependentAES256GCMUTF8Vector() throws {
        // Generated with Node.js crypto: SHA-256(UTF-8 password), AES-256-GCM,
        // nonce 000102030405060708090a0b, no AAD, and a 16-byte tag.
        let hex = "000102030405060708090a0bfff0543680a95d1e55b85f487ab45fab28fb3574baa1912517cafc6ec84dfa8f0dc4cb64b2ade3a277437b4a456e1e39e2918f00352ee46d1b03ec5d6b85"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let cipher = APIPayloadCipher(password: "cross-platform-测试🔐")
        let result = try cipher.decrypt(Data(bytes))
        XCTAssertEqual(String(data: result, encoding: .utf8), #"{"message":"三端一致 🎬","amount":20030}"#)
    }

    func testEncryptionUsesRandomTwelveByteNonceAndSixteenByteTag() throws {
        let plaintext = Data(#"{"剧名":"今日签到 🎬","金币":30}"#.utf8)
        let cipher = APIPayloadCipher(password: "test-password")
        let first = try cipher.encrypt(plaintext)
        let second = try cipher.encrypt(plaintext)
        XCTAssertEqual(first.count, plaintext.count + 12 + 16)
        XCTAssertEqual(second.count, plaintext.count + 12 + 16)
        XCTAssertNotEqual(first.prefix(12), second.prefix(12))
        XCTAssertEqual(try cipher.decrypt(first), plaintext)
        XCTAssertEqual(try cipher.decrypt(second), plaintext)
        let box = try AES.GCM.SealedBox(combined: first)
        XCTAssertEqual(box.nonce.withUnsafeBytes { $0.count }, 12)
        XCTAssertEqual(box.tag.count, 16)
    }

    func testEmptyPlaintextRoundTripsAsNonceAndTag() throws {
        let cipher = APIPayloadCipher(password: "test-password")
        let encrypted = try cipher.encrypt(Data())
        XCTAssertEqual(encrypted.count, 28)
        XCTAssertEqual(try cipher.decrypt(encrypted), Data())
    }

    func testTransportEncodesCombinedBinaryAsBase64() throws {
        let cipher = APIPayloadCipher(password: "test-password")
        let plaintext = Data(#"{"签到":"领取 🎁"}"#.utf8)
        let payload = try cipher.encryptForTransport(plaintext)
        let combined = try XCTUnwrap(Data(base64Encoded: payload))
        XCTAssertEqual(payload, combined.base64EncodedData())
        XCTAssertEqual(combined.count, plaintext.count + 28)
        XCTAssertEqual(try cipher.decrypt(combined), plaintext)
        XCTAssertEqual(try cipher.decryptFromTransport(payload), plaintext)
        XCTAssertThrowsError(try cipher.decryptFromTransport(Data("%%%".utf8)))
        XCTAssertThrowsError(try cipher.decryptFromTransport(combined))
    }

    func testWrongKeyAndTamperedNonceCiphertextOrTagAreRejected() throws {
        let cipher = APIPayloadCipher(password: "test-password")
        let encrypted = try cipher.encrypt(Data("payload".utf8))
        XCTAssertThrowsError(try APIPayloadCipher(password: "wrong-password").decrypt(encrypted))
        for index in [0, 12, encrypted.count - 1] {
            var tampered = encrypted
            tampered[index] ^= 1
            XCTAssertThrowsError(try cipher.decrypt(tampered))
        }
    }

    func testTruncatedAndBase64WrappedPayloadsAreRejected() throws {
        let cipher = APIPayloadCipher(password: "test-password")
        for length in [0, 11, 12, 27] {
            XCTAssertThrowsError(try cipher.decrypt(Data(repeating: 0, count: length)))
        }
        let encrypted = try cipher.encrypt(Data("payload".utf8))
        XCTAssertThrowsError(try cipher.decrypt(Data(encrypted.dropLast())))
        XCTAssertThrowsError(try cipher.decrypt(Data(encrypted.base64EncodedString().utf8)))
    }
}
