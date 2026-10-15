import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class EncryptedNetworkTests: XCTestCase {
    private let cipher = APIPayloadCipher(password: "network-test-password")
    private var login: APIModels.V1GuestLoginReq {
        .init(currentVersion: "1.0", deviceIdentifier: "测试设备🎬")
    }

    func testEncryptsJSONBodyAndDecryptsEnvelopeIncludingGuestLogin() async throws {
        let reply = try cipher.encryptForTransport(Data(#"{"code":200,"data":{"accessToken":"encrypted-token","user":{"userNo":"123","nickname":"小明"}}}"#.utf8))
        let client = try makeClient(response: reply) { target in
            XCTAssertEqual(target.headers?["Content-Type"], "text/plain; charset=utf-8")
            XCTAssertEqual(target.headers?["Accept"], "text/plain")
            XCTAssertFalse(target.headers?.keys.contains { $0.lowercased() == "x-payload-encryption" } ?? false)
            XCTAssertEqual(target.headers?["language"], AppLanguage.current.rawValue)
            XCTAssertNil(target.headers?["content-type"])
            XCTAssertNil(target.headers?["x-payload-encryption"])
            XCTAssertNil(try? JSONSerialization.jsonObject(with: target.body))
            do {
                let json = try self.cipher.decrypt(try XCTUnwrap(Data(base64Encoded: target.body)))
                let request = try JSONDecoder().decode(APIModels.V1GuestLoginReq.self, from: json)
                XCTAssertEqual(request.currentVersion, "1.0")
                XCTAssertEqual(request.deviceIdentifier, "测试设备🎬")
            } catch { XCTFail("Request must contain authenticated encrypted JSON: \(error)") }
        }
        let result = try await client.request(AppAPI.v1AuthGuestLogin, body: login, unwrapEnvelope: true)
        XCTAssertEqual(result.accessToken, "encrypted-token")
        XCTAssertEqual(result.user?.nickname, "小明")
    }

    func testDecryptsDirectAndTolerantResponsesWithOnlyBearerAuthorization() async throws {
        let reply = try cipher.encryptForTransport(Data(#"{"accessToken":123}"#.utf8))
        let client = try makeClient(response: reply) { target in
            XCTAssertFalse(target.requestHeaders.keys.contains { $0.lowercased() == "accesstoken" })
            XCTAssertEqual(target.headers?["Authorization"], "Bearer guest-token")
        }
        client.setAccessToken("guest-token")
        let endpoint = APIEndpoint<APIModels.V1GuestLoginReq, APIModels.V1GuestLoginRes>(path: "/test/business")
        do {
            _ = try await client.request(endpoint, body: login)
            XCTFail("Strict JSON decoding must still reject incorrect types")
        } catch APIError.decoding { }
        let result = try await client.request(endpoint, body: login, decoding: .tolerant)
        XCTAssertNil(result.accessToken)
    }

    func testEncryptedBusinessErrorPreservesCodeAndMessage() async throws {
        let reply = try cipher.encryptForTransport(Data(#"{"code":403,"data":null,"message":"denied"}"#.utf8))
        let client = try makeClient(response: reply)
        do {
            _ = try await client.request(AppAPI.v1TheaterHome, body: .init(), unwrapEnvelope: true)
            XCTFail("Expected business error after decryption")
        } catch APIError.business(let code, let message) {
            XCTAssertEqual(code, 403)
            XCTAssertEqual(message, "denied")
        }
    }

    func testSuccessfulHTTPResponsesCannotDowngradeToPlaintextOrIgnoreTampering() async throws {
        var tampered = try cipher.encrypt(Data(#"{"accessToken":"token"}"#.utf8))
        tampered[tampered.count - 1] ^= 1
        let wrongKey = try APIPayloadCipher(password: "wrong-password").encrypt(Data("{}".utf8))
        for reply in [Data(), Data("{}".utf8), Data(#"{"accessToken":"plain-token"}"#.utf8), tampered.base64EncodedData(), wrongKey.base64EncodedData(), wrongKey, Data("%%%invalid-base64%%%".utf8)] {
            let client = try makeClient(response: reply)
            do {
                _ = try await client.request(AppAPI.v1AuthGuestLogin, body: login)
                XCTFail("Invalid ciphertext must fail before JSON decoding")
            } catch APIError.decryption { }
        }
    }

    func testHTTPFailureKeepsStatusEvenWhenItsBodyIsNotEncrypted() async throws {
        let client = try makeClient(response: Data("upstream unavailable".utf8), status: 503)
        do {
            _ = try await client.request(AppAPI.v1AuthGuestLogin, body: login)
            XCTFail("Expected HTTP status error")
        } catch APIError.httpStatus(let status) { XCTAssertEqual(status, 503) }
    }

    func testAuthenticatedNonJSONResponseStillFailsDecoding() async throws {
        let client = try makeClient(response: cipher.encryptForTransport(Data("not-json".utf8)))
        do {
            _ = try await client.request(AppAPI.v1AuthGuestLogin, body: login)
            XCTFail("Authenticated plaintext must still be valid JSON")
        } catch APIError.decoding { }
    }

    func testCancellationCancelsEncryptedRequest() async throws {
        let started = expectation(description: "Encrypted request sent")
        let client = try makeClient(response: cipher.encryptForTransport(Data("{}".utf8)), delay: 5) { _ in started.fulfill() }
        let task = _Concurrency.Task { try await client.request(AppAPI.v1AuthGuestLogin, body: login) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    private func makeClient(response: Data, status: Int = 200, delay: TimeInterval = 0,
                            inspect: @escaping (APITarget) -> Void = { _ in }) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            inspect(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(status, response) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in delay > 0 ? .delayed(seconds: delay) : .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
            provider: provider, payloadCipher: cipher,
            headerProvider: { _ in ["language": "zh-Hans", "content-type": "application/json", "x-payload-encryption": "0"] })
    }
}
