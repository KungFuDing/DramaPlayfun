import Foundation
import CleanJSON

/// Payload work must leave MainActor even with default actor isolation enabled.
/// These structured calls retain the caller's cancellation and priority.
nonisolated enum APIPayloadProcessing {
    struct EncodedRequest: Sendable {
        let plaintextBody: Data
        let wireBody: Data
    }

    struct DecodedResponse<Output: Sendable>: Sendable {
        let plaintextBody: Data?
        let result: Result<Output, APIError>
    }

    @concurrent
    static func encode<Body: Encodable & Sendable>(
        _ body: Body, cipher: APIPayloadCipher?
    ) async throws -> EncodedRequest {
        try Task.checkCancellation()
        let plaintext: Data
        do { plaintext = try JSONEncoder().encode(body) }
        catch { throw APIError.encoding(error) }
        try Task.checkCancellation()
        let wireBody: Data
        if let cipher {
            do { wireBody = try cipher.encryptForTransport(plaintext) }
            catch { throw APIError.encryption(error) }
        } else {
            wireBody = plaintext
        }
        try Task.checkCancellation()
        return EncodedRequest(plaintextBody: plaintext, wireBody: wireBody)
    }

    @concurrent
    static func decode<Output: Decodable & Sendable>(
        _ type: Output.Type, from data: Data, cipher: APIPayloadCipher?,
        decoding: APIResponseDecoding, unwrapEnvelope: Bool
    ) async throws -> DecodedResponse<Output> {
        try Task.checkCancellation()
        let plaintext: Data
        if let cipher {
            do { plaintext = try cipher.decryptFromTransport(data) }
            catch {
                return DecodedResponse(plaintextBody: nil, result: .failure(.decryption(error)))
            }
        } else {
            plaintext = data
        }
        try Task.checkCancellation()
        let result: Result<Output, APIError>
        do {
            result = .success(try decodeObject(type, from: plaintext,
                decoding: decoding, unwrapEnvelope: unwrapEnvelope))
        } catch let error as APIError {
            result = .failure(error)
        }
        try Task.checkCancellation()
        // Keep decrypted data for the existing diagnostics, including business/JSON failures.
        return DecodedResponse(plaintextBody: plaintext, result: result)
    }

    private static func decodeObject<Output: Decodable>(
        _ type: Output.Type, from data: Data,
        decoding: APIResponseDecoding, unwrapEnvelope: Bool
    ) throws -> Output {
        let object: [String: Any]
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected a JSON object"))
            }
            object = root
        } catch { throw APIError.decoding(error) }
        if unwrapEnvelope, let code = object["code"] as? Int {
            guard code == 200 else { throw APIError.business(code, object["message"] as? String) }
            do {
                let envelope: APIEnvelope<Output>
                switch decoding {
                case .strict: envelope = try JSONDecoder().decode(APIEnvelope<Output>.self, from: data)
                case .tolerant: envelope = try CleanJSONDecoder().decode(APIEnvelope<Output>.self, from: data)
                }
                guard let payload = envelope.data else {
                    throw DecodingError.valueNotFound(Output.self,
                        .init(codingPath: [], debugDescription: "Missing envelope data"))
                }
                return payload
            } catch { throw APIError.decoding(error) }
        }
        do {
            switch decoding {
            case .strict: return try JSONDecoder().decode(Output.self, from: data)
            case .tolerant: return try CleanJSONDecoder().decode(Output.self, from: data)
            }
        } catch { throw APIError.decoding(error) }
    }
}

nonisolated private struct APIEnvelope<Payload: Decodable>: Decodable {
    let data: Payload?
}
