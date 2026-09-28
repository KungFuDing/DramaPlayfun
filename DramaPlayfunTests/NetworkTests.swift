import XCTest
import Moya
import Alamofire
@testable import DramaPlayfun

@MainActor
final class NetworkTests: XCTestCase {
    private var login: APIModels.V1GuestLoginReq {
        .init(currentVersion: "1.0", deviceIdentifier: "test-device")
    }

    private func client(status: Int = 200, json: String, delay: TimeInterval = 0,
                        inspect: @escaping (APITarget) -> Void = { _ in }) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            inspect(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(status, Data(json.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in delay > 0 ? .delayed(seconds: delay) : .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider, headerProvider: { _ in ["X-Test-Token": "stub-only"] })
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

    func testHTTPErrorIsNotDecodedAsSuccessfulEmptyResponse() async throws {
        let client = try client(status: 401, json: "{}")
        do {
            _ = try await client.request(AppAPI.v1AuthGuestLogin, body: login)
            XCTFail("Expected HTTP error")
        } catch APIError.httpStatus(let status) { XCTAssertEqual(status, 401) }
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
