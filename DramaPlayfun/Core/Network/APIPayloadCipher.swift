import Foundation
import CryptoKit

/// AES-GCM combines [12-byte nonce][ciphertext][16-byte tag], without AAD.
/// Transport bodies contain the Base64 encoding of these combined bytes.
nonisolated struct APIPayloadCipher: Sendable {
    private let key: SymmetricKey

    init(password: String) {
        key = SymmetricKey(data: SHA256.hash(data: Data(password.utf8)))
    }

    func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw PayloadError.invalidCombinedData }
        return combined
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 12 + 16 else { throw PayloadError.invalidCombinedData }
        let sealed = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealed, using: key)
    }

    func encryptForTransport(_ plaintext: Data) throws -> Data {
        try encrypt(plaintext).base64EncodedData()
    }

    func decryptFromTransport(_ payload: Data) throws -> Data {
        guard let combined = Data(base64Encoded: payload) else { throw PayloadError.invalidBase64Data }
        return try decrypt(combined)
    }

    private enum PayloadError: Error {
        case invalidCombinedData
        case invalidBase64Data
    }
}
