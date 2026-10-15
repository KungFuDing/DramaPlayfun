import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class TransportEncryptionConfigTests: XCTestCase {
    private let cipher = APIPayloadCipher(password: "transport-config-test")
    private var configPath: String { AppAPI.v1ClientTransportEncryptionConfig.path }
    private let business = APIEndpoint<APIModels.V1GetTransportEncryptionConfigReq, APIModels.V1GuestLoginRes>(path: "/test/business")
    private var login: APIModels.V1GuestLoginReq { .init(currentVersion: "1", deviceIdentifier: "test-device") }
    private var plaintextPaths: [String] {
        [AppAPI.v1ClientServiceNotice.path, AppAPI.v1ClientAppConfig.path,
         AppAPI.v1ClientAppUpdateCheck.path, configPath]
    }

    func testPlaintextEndpointsSkipConfigurationLoadingWithOrWithoutCipher() async throws {
        for includeCipher in [true, false] {
            var paths: [String] = []
            let client = try makeClient(response: { target in
                paths.append(target.path)
                return self.plaintextResponse(for: target)
            }, includeCipher: includeCipher)

            try await requestPlaintextEndpoints(using: client)

            XCTAssertEqual(paths, plaintextPaths, "Plaintext endpoints must not trigger a configuration fetch")
        }
    }

    func testPlaintextEndpointsPreserveEncryptionForOtherRequestsInBothModes() async throws {
        let reply = try cipher.encryptForTransport(Data(#"{"accessToken":"encrypted-token"}"#.utf8))
        for usesServerConfiguration in [true, false] {
            var paths: [String] = []
            let client = try makeClient(response: { target in
                paths.append(target.path)
                if target.path != self.business.path { return self.plaintextResponse(for: target) }
                XCTAssertEqual(target.headers?["Content-Type"], "text/plain; charset=utf-8")
                XCTAssertEqual(target.headers?["Accept"], "text/plain")
                do {
                    let body = try self.cipher.decryptFromTransport(target.body)
                    XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], [:])
                } catch { XCTFail("Business request must remain encrypted: \(error)") }
                return reply
            }, usesServerEncryptionConfiguration: usesServerConfiguration)

            let before = try await client.request(business, body: .init())
            XCTAssertEqual(before.accessToken, "encrypted-token")
            try await requestPlaintextEndpoints(using: client)
            let after = try await client.request(business, body: .init())
            XCTAssertEqual(after.accessToken, "encrypted-token")

            let expected = (usesServerConfiguration ? [configPath] : [])
                + [business.path] + plaintextPaths + [business.path]
            XCTAssertEqual(paths, expected)
        }
    }

    func testEnabledConfigurationIsPlaintextAndPrecedesEncryptedLogin() async throws {
        let reply = try cipher.encryptForTransport(Data(#"{"code":200,"data":{"accessToken":"token"}}"#.utf8))
        var paths: [String] = []
        let client = try makeClient { target in
            paths.append(target.path)
            if target.path == self.configPath {
                self.assertPlaintextConfig(target)
                return self.configResponse(enabled: true)
            }
            XCTAssertFalse(target.headers?.keys.contains { $0.lowercased() == "x-payload-encryption" } ?? false)
            do {
                let request = try JSONDecoder().decode(APIModels.V1GuestLoginReq.self, from: self.cipher.decrypt(try XCTUnwrap(Data(base64Encoded: target.body))))
                XCTAssertEqual(request.deviceIdentifier, "test-device")
            } catch { XCTFail("Login must be encrypted: \(error)") }
            return reply
        }
        let result = try await client.request(AppAPI.v1AuthGuestLogin, body: login, unwrapEnvelope: true)
        XCTAssertEqual(result.accessToken, "token")
        XCTAssertEqual(paths, [configPath, AppAPI.v1AuthGuestLogin.path])
    }

    func testDisabledConfigurationKeepsRequestsAndResponsesPlaintext() async throws {
        let client = try makeClient { target in
            if target.path == self.configPath { return self.configResponse(enabled: false) }
            XCTAssertNil(target.headers?["X-Payload-Encryption"])
            XCTAssertNil(target.headers?["x-payload-encryption"])
            XCTAssertEqual(target.headers?["Content-Type"], "application/json")
            XCTAssertEqual(target.headers?["Accept"], "application/json")
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: target.body))
            return Data(#"{"code":200,"data":{"accessToken":"plain-token"}}"#.utf8)
        }
        let result = try await client.request(AppAPI.v1AuthGuestLogin, body: login, unwrapEnvelope: true)
        XCTAssertEqual(result.accessToken, "plain-token")
    }

    func testConcurrentBusinessRequestsShareAndCacheConfiguration() async throws {
        var configCount = 0
        var businessCount = 0
        let reply = try cipher.encryptForTransport(Data(#"{"accessToken":"token"}"#.utf8))
        let client = try makeClient(response: { target in
            if target.path == self.configPath {
                configCount += 1
                return self.configResponse(enabled: true)
            }
            businessCount += 1
            return reply
        }, delay: { $0.path == self.configPath ? 0.1 : 0 })
        async let first = client.request(business, body: .init())
        async let second = client.request(business, body: .init())
        let results = try await (first, second)
        XCTAssertEqual(results.0.accessToken, "token")
        XCTAssertEqual(results.1.accessToken, "token")
        _ = try await client.request(business, body: .init())
        XCTAssertEqual(configCount, 1)
        XCTAssertEqual(businessCount, 3)
    }

    func testConfigurationFailureBlocksBusinessTrafficAndCanRetry() async throws {
        var fail = true
        var configCount = 0
        var businessCount = 0
        let client = try makeClient { target in
            if target.path == self.configPath {
                configCount += 1
                return fail ? Data(#"{"code":500,"message":"暂不可用","data":null}"#.utf8)
                    : self.configResponse(enabled: false)
            }
            businessCount += 1
            return Data(#"{"accessToken":"token"}"#.utf8)
        }
        do {
            _ = try await client.request(business, body: .init())
            XCTFail("Business traffic must wait for a confirmed configuration")
        } catch APIError.business(let code, _) { XCTAssertEqual(code, 500) }
        XCTAssertEqual(businessCount, 0)
        fail = false
        _ = try await client.request(business, body: .init())
        XCTAssertEqual(configCount, 2)
        XCTAssertEqual(businessCount, 1)
    }

    func testMissingOrInvalidEnabledFieldCannotSilentlyDisableEncryption() async throws {
        for json in [#"{"code":200,"data":{}}"#, #"{"code":200,"data":{"enabled":null}}"#,
                     #"{"code":200,"data":{"enabled":"false"}}"#] {
            let client = try makeClient { target in
                XCTAssertEqual(target.path, self.configPath)
                return Data(json.utf8)
            }
            do {
                _ = try await client.request(business, body: .init())
                XCTFail("Invalid configuration must fail")
            } catch APIError.decoding { }
        }
    }

    func testEnabledServerConfigurationRequiresCipher() async throws {
        let client = try makeClient(response: { target in
            XCTAssertEqual(target.path, self.configPath)
            return self.configResponse(enabled: true)
        }, includeCipher: false)
        do {
            _ = try await client.request(business, body: .init())
            XCTFail("An enabled configuration cannot send plaintext without a cipher")
        } catch APIError.missingEncryptionKey { }
    }

    func testRefreshChangesFutureRequestsWithoutChangingAnInFlightResponse() async throws {
        var enabled = true
        var configCount = 0
        let encryptedReply = try cipher.encryptForTransport(Data(#"{"accessToken":"encrypted-token"}"#.utf8))
        let started = expectation(description: "Encrypted business request started")
        let client = try makeClient(response: { target in
            if target.path == self.configPath {
                configCount += 1
                self.assertPlaintextConfig(target)
                return self.configResponse(enabled: enabled)
            }
            if target.headers?["Content-Type"] == "text/plain; charset=utf-8" {
                started.fulfill()
                return encryptedReply
            }
            return Data(#"{"accessToken":"plain-token"}"#.utf8)
        }, delay: { $0.headers?["Content-Type"] == "text/plain; charset=utf-8" ? 0.2 : 0 })
        client.setAccessToken("existing-token")
        let pending = _Concurrency.Task { try await client.request(business, body: .init()) }
        await fulfillment(of: [started], timeout: 2)
        enabled = false
        try await client.reloadTransportEncryptionConfiguration()
        let oldResult = try await pending.value
        XCTAssertEqual(oldResult.accessToken, "encrypted-token")
        let newResult = try await client.request(business, body: .init())
        XCTAssertEqual(newResult.accessToken, "plain-token")
        enabled = true
        try await client.reloadTransportEncryptionConfiguration()
        XCTAssertEqual(configCount, 3)
    }

    func testCancellingOneWaiterDoesNotCancelSharedConfigurationOrSendItsBusinessRequest() async throws {
        let started = expectation(description: "Configuration fetch started")
        var configCount = 0
        var businessCount = 0
        let reply = try cipher.encryptForTransport(Data(#"{"accessToken":"token"}"#.utf8))
        let client = try makeClient(response: { target in
            if target.path == self.configPath {
                configCount += 1
                started.fulfill()
                return self.configResponse(enabled: true)
            }
            businessCount += 1
            return reply
        }, delay: { $0.path == self.configPath ? 5 : 0 })
        let cancelled = _Concurrency.Task { try await client.request(business, body: .init()) }
        await fulfillment(of: [started], timeout: 2)
        cancelled.cancel()
        let result = try await client.request(business, body: .init())
        XCTAssertEqual(result.accessToken, "token")
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(configCount, 1)
        XCTAssertEqual(businessCount, 1)
    }

    private func configResponse(enabled: Bool) -> Data {
        Data("{\"code\":200,\"data\":{\"enabled\":\(enabled)}}".utf8)
    }

    private func requestPlaintextEndpoints(using client: APIClient) async throws {
        let notice = try await client.request(AppAPI.v1ClientServiceNotice, body: .init(), unwrapEnvelope: true)
        XCTAssertEqual(notice.status, "off")
        let appConfig = try await client.request(AppAPI.v1ClientAppConfig, body: .init(), unwrapEnvelope: true)
        XCTAssertEqual(appConfig.customerServiceEmail, "support@example.invalid")
        let update = try await client.request(AppAPI.v1ClientAppUpdateCheck,
            body: .init(currentVersion: "1"), unwrapEnvelope: true)
        XCTAssertEqual(update.latestVersion, "2")
        let encryptionConfig = try await client.request(AppAPI.v1ClientTransportEncryptionConfig,
            body: .init(), unwrapEnvelope: true)
        XCTAssertTrue(encryptionConfig.enabled)
    }

    private func plaintextResponse(for target: APITarget) -> Data {
        XCTAssertEqual(target.headers?["Content-Type"], "application/json")
        XCTAssertEqual(target.headers?["Accept"], "application/json")
        XCTAssertFalse(target.headers?.keys.contains { $0.lowercased() == "x-payload-encryption" } ?? false)
        let expectedBody = target.path == AppAPI.v1ClientAppUpdateCheck.path ? ["currentVersion": "1"] : [:]
        XCTAssertEqual(try? JSONSerialization.jsonObject(with: target.body) as? [String: String], expectedBody)
        switch target.path {
        case AppAPI.v1ClientServiceNotice.path:
            return Data(#"{"code":200,"data":{"status":"off"}}"#.utf8)
        case AppAPI.v1ClientAppConfig.path:
            return Data(#"{"code":200,"data":{"customerServiceEmail":"support@example.invalid"}}"#.utf8)
        case AppAPI.v1ClientAppUpdateCheck.path:
            return Data(#"{"code":200,"data":{"latestVersion":"2"}}"#.utf8)
        case configPath:
            return configResponse(enabled: true)
        default:
            XCTFail("Unexpected plaintext endpoint: \(target.path)")
            return Data()
        }
    }

    private func assertPlaintextConfig(_ target: APITarget) {
        XCTAssertEqual(target.headers?["Content-Type"], "application/json")
        XCTAssertNil(target.headers?["X-Payload-Encryption"])
        XCTAssertNil(target.headers?["accessToken"])
        XCTAssertNil(target.headers?["Authorization"])
        XCTAssertNil(target.headers?["AUTHORIZATION"])
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: target.body) as? [String: String])?.count, 0)
    }

    private func makeClient(response: @escaping (APITarget) -> Data,
                            delay: @escaping (APITarget) -> TimeInterval = { _ in 0 },
                            includeCipher: Bool = true,
                            usesServerEncryptionConfiguration: Bool = true) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let responseData = response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, responseData) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { target in
            let seconds = delay(target)
            return seconds > 0 ? .delayed(seconds: seconds) : .immediate
        })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
            provider: provider, payloadCipher: includeCipher ? cipher : nil,
            usesServerEncryptionConfiguration: usesServerEncryptionConfiguration,
            headerProvider: { _ in ["accessToken": "old-token", "AUTHORIZATION": "Bearer old-token",
                                     "x-payload-encryption": "1"] })
    }
}
