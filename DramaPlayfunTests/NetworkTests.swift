import XCTest
import Moya
import Alamofire
import UIKit
@testable import DramaPlayfun

@MainActor
final class NetworkTests: XCTestCase {
    private var login: APIModels.V1GuestLoginReq {
        .init(currentVersion: "1.0", deviceIdentifier: "test-device")
    }

    private func client(status: Int = 200, json: String, delay: TimeInterval = 0,
                        headers: [String: String] = ["X-Test-Token": "stub-only"],
                        inspect: @escaping (APITarget) -> Void = { _ in }) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            inspect(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(status, Data(json.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in delay > 0 ? .delayed(seconds: delay) : .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider, headerProvider: { _ in headers })
    }

    func testTypedRequestEncodesDocumentedBodyAndHeaders() async throws {
        let client = try client(json: #"{"accessToken":"token","user":{"userNo":"123","nickname":null}}"#) { target in
            XCTAssertEqual(target.path, "/mobile/v1/auth/guest/login")
            XCTAssertEqual(target.method, .post)
            XCTAssertEqual(target.headers?["Content-Type"], "application/json")
            XCTAssertEqual(target.headers?["X-Test-Token"], "stub-only")
            let body = try? JSONSerialization.jsonObject(with: target.body) as? [String: String]
            XCTAssertEqual(body?["currentVersion"], "1.0")
            XCTAssertEqual(body?["deviceIdentifier"], "test-device")
        }
        let result = try await client.request(AppAPI.v1AuthGuestLogin, body: login)
        XCTAssertEqual(result.accessToken, "token")
        XCTAssertEqual(result.user?.userNo, "123")
        XCTAssertNil(result.user?.nickname)
    }

    func testRuntimeHeadersOverrideConfigurationOnEveryEndpoint() async throws {
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let systemName = UIDevice.current.systemName
        let systemVersion = UIDevice.current.systemVersion
        var paths: [String] = []
        let client = try client(json: "{}", headers: [
            "appVersion": "stale-version", "APPVERSION": "another-stale-version",
            "modelName": "manual-device", "MODELNAME": "another-manual-device",
            "platform": "manual-platform", "PLATFORM": "another-manual-platform",
            "systemVersion": "manual-system", "SYSTEMVERSION": "another-manual-system",
            "language": "zh-Hans"
        ]) { target in
            paths.append(target.path)
            let headers = target.requestHeaders
            XCTAssertEqual(headers["appVersion"], version)
            XCTAssertEqual(headers["platform"], systemName)
            XCTAssertEqual(headers["systemVersion"], "\(systemName) \(systemVersion)")
            #if targetEnvironment(simulator)
            XCTAssertEqual(headers["modelName"], "Simulator")
            #else
            XCTAssertFalse(headers["modelName"]?.isEmpty ?? true)
            XCTAssertNotEqual(headers["modelName"], "manual-device")
            #endif
            for key in ["appVersion", "modelName", "platform", "systemVersion"] {
                XCTAssertEqual(headers.keys.filter { $0.lowercased() == key.lowercased() }.count, 1)
            }
            XCTAssertEqual(headers["language"], "zh-Hans")
        }
        let expectedPaths = [AppAPI.v1ClientTransportEncryptionConfig.path,
                             AppAPI.v1AuthGuestLogin.path, "/test/business"]
        for path in expectedPaths {
            let endpoint = APIEndpoint<APIModels.V1GuestLoginReq, APIModels.V1GuestLoginRes>(path: path)
            _ = try await client.request(endpoint, body: login)
        }
        XCTAssertEqual(paths, expectedPaths)
    }

    func testDeviceModelNamesResolveHardwareIdentifiersWithoutGuessingUnknownModels() {
        XCTAssertEqual(DeviceModelName.resolve("iPhone18,3"), "iPhone 17")
        XCTAssertEqual(DeviceModelName.resolve("iPad16,5"), "iPad Pro 13-inch (M4)")
        XCTAssertEqual(DeviceModelName.resolve("iPad16,6"), "iPad Pro 13-inch (M4)")
        XCTAssertEqual(DeviceModelName.resolve("iPad17,4"), "iPad Pro 13-inch (M5)")
        XCTAssertEqual(DeviceModelName.resolve("iPhone99,1"), "iPhone99,1")
    }

    func testHTTPErrorIsNotDecodedAsSuccessfulEmptyResponse() async throws {
        let client = try client(status: 401, json: "{}")
        do {
            _ = try await client.request(AppAPI.v1AuthGuestLogin, body: login)
            XCTFail("Expected HTTP error")
        } catch APIError.httpStatus(let status) { XCTAssertEqual(status, 401) }
    }

    func testWrappedBusinessErrorKeepsServerCodeAndMessage() async throws {
        let client = try client(json: #"{"code":403,"data":null,"message":"denied"}"#)
        do {
            _ = try await client.request(AppAPI.v1TheaterHome, body: .init(), unwrapEnvelope: true)
            XCTFail("Expected business error")
        } catch APIError.business(let code, let message) {
            XCTAssertEqual(code, 403)
            XCTAssertEqual(message, "denied")
        }
    }

    func testMalformedAndNonObjectResponsesFail() async throws {
        for payload in ["", "not-json", "[]", "null"] {
            let client = try client(json: payload)
            do {
                _ = try await client.request(AppAPI.v1AuthGuestLogin, body: login, decoding: .tolerant)
                XCTFail("Unexpected success: \(payload)")
            } catch APIError.decoding { }
        }
    }

    func testStrictAndCleanJSONDecodingAreExplicit() async throws {
        let client = try client(json: #"{"accessToken":123}"#)
        do {
            _ = try await client.request(AppAPI.v1AuthGuestLogin, body: login)
            XCTFail("Strict decoding must reject a number for a string")
        } catch APIError.decoding { }
        let result = try await client.request(AppAPI.v1AuthGuestLogin, body: login, decoding: .tolerant)
        XCTAssertNil(result.accessToken, "CleanJSON drops incompatible optional values")
        let displayClient = try self.client(json: #"{"count":"3","title":null}"#)
        let endpoint = APIEndpoint<APIModels.V1GuestLoginReq, DisplayResponse>(path: "/stub/display")
        let display = try await displayClient.request(endpoint, body: login, decoding: .tolerant)
        XCTAssertEqual(display.count, 3)
        XCTAssertEqual(display.title, "")
    }

    func testCancellationDuringRequestReturnsCancellationError() async throws {
        let started = expectation(description: "Request started")
        let client = try client(json: "{}", delay: 5) { _ in started.fulfill() }
        let task = _Concurrency.Task { try await client.request(AppAPI.v1AuthGuestLogin, body: login) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testCancellationBeforeStartDoesNotSendRequest() async throws {
        let client = try client(json: "{}") { _ in XCTFail("Cancelled task must not send") }
        let task = _Concurrency.Task { try await client.request(AppAPI.v1AuthGuestLogin, body: login) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testConfigurationRejectsInvalidServerURLs() throws {
        for value in ["http://example.invalid", "https://user:secret@example.invalid", "https://example.invalid?token=secret"] {
            XCTAssertThrowsError(try APIConfiguration(baseURL: XCTUnwrap(URL(string: value))))
        }
        XCTAssertThrowsError(try APIConfiguration(baseURL: XCTUnwrap(URL(string: "https://example.invalid")), timeout: -1))
    }

    #if DEBUG
    func testDebugHeadersSendAccessTokenAndBearerAuthorization() {
        let headers = DebugHTTPHeaders.addingAuthorization(to: ["accessToken": "sample-token", "countryCode": "TW"])
        XCTAssertEqual(headers["accessToken"], "sample-token")
        XCTAssertEqual(headers["Authorization"], "Bearer sample-token")
        XCTAssertEqual(headers["countryCode"], "TW")
        XCTAssertNil(DebugHTTPHeaders.addingAuthorization(to: [:])["Authorization"])
    }

    func testDebugLogRedactsSensitiveNestedFields() {
        let data = Data(#"{"accessToken":"secret-value","profile":{"phone":"123456","deviceId":"device-secret","ip":"2001:db8::1","nickname":"小明","coverUrl":"https://cdn.example.invalid/cover.jpg?x-media-token=signed-value"},"items":[{"Authorization":"Bearer secret-value"}]}"#.utf8)
        let output = APIDebugLogger.formattedBody(data)
        XCTAssertFalse(output.contains("secret-value"))
        XCTAssertFalse(output.contains("123456"))
        XCTAssertFalse(output.contains("device-secret"))
        XCTAssertFalse(output.contains("2001:db8::1"))
        XCTAssertFalse(output.contains("signed-value"))
        XCTAssertTrue(output.contains("小明"))
        XCTAssertTrue(output.contains("<redacted>"))
    }
    #endif

    func testExtensionValuesPreserveTypesAndLargeIntegers() throws {
        let original = JSONValue.object(["id": .integer(9_007_199_254_740_993), "value": .array([.null, .bool(true), .string("123"), .number(1.25)])])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), original)
    }
}

nonisolated private struct DisplayResponse: Decodable {
    let count: Int
    let title: String
}
