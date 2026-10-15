import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class GuestSessionTests: XCTestCase {
    func testLoginReplacesBothHeadersAndRunsOnce() async throws {
        let recorder = GuestRequestRecorder()
        let network = try makeNetwork(recorder: recorder, responses: [
            #"{"code":200,"data":{"accessToken":"new-guest-token"}}"#
        ], headers: ["accessToken": "old-token", "AUTHORIZATION": "Bearer old-token",
                     "appVersion": "1.3.1", "deviceId": "test-device", "language": "zh-Hans"])
        let defaults = isolatedDefaults()
        let session = GuestSessionStore(network: network, defaults: defaults)
        let appVersion = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(session.currentVersion, appVersion)
        await session.signInIfNeeded()
        await session.signInIfNeeded()
        XCTAssertTrue(session.isReady)
        XCTAssertFalse(session.isLoading)
        XCTAssertNil(session.errorMessage)
        let endpoint = APIEndpoint<APIModels.V1GuestLoginReq, APIModels.V1GuestLoginRes>(path: "/test/business")
        _ = try await network.request(endpoint, body: .init(currentVersion: "1", deviceIdentifier: "device"), unwrapEnvelope: true)
        let requests = recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].path, AppAPI.v1AuthGuestLogin.path)
        XCTAssertNil(requests[0].headers?["accessToken"])
        XCTAssertNil(requests[0].headers?["AUTHORIZATION"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].body) as? [String: String])
        XCTAssertEqual(body["currentVersion"], appVersion)
        XCTAssertEqual(requests[0].headers?["appVersion"], appVersion)
        XCTAssertEqual(requests[1].headers?["appVersion"], appVersion)
        XCTAssertEqual(body["deviceIdentifier"], "test-device")
        XCTAssertEqual(requests[1].headers?["accessToken"], "new-guest-token")
        XCTAssertEqual(requests[1].headers?["Authorization"], "Bearer new-guest-token")
        XCTAssertNil(requests[1].headers?["AUTHORIZATION"])
        XCTAssertEqual(requests[1].headers?["language"], "zh-Hans")
    }

    func testMissingTokenKeepsGateClosedAndCanRetry() async throws {
        let recorder = GuestRequestRecorder()
        let network = try makeNetwork(recorder: recorder, responses: [
            #"{"code":200,"data":{"accessToken":" "}}"#,
            #"{"code":200,"data":{"accessToken":"retry-token"}}"#
        ])
        let session = GuestSessionStore(network: network, defaults: isolatedDefaults())
        await session.signInIfNeeded()
        XCTAssertFalse(session.isReady)
        XCTAssertFalse(session.isLoading)
        XCTAssertNotNil(session.errorMessage)
        await session.signInIfNeeded()
        XCTAssertTrue(session.isReady)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testBusinessFailureAndDeviceIdentifierPersists() async throws {
        let recorder = GuestRequestRecorder()
        let network = try makeNetwork(recorder: recorder, responses: [
            #"{"code":500,"message":"unavailable","data":null}"#
        ])
        let defaults = isolatedDefaults()
        let first = GuestSessionStore(network: network, defaults: defaults)
        await first.signInIfNeeded()
        XCTAssertFalse(first.isReady)
        XCTAssertNotNil(first.errorMessage)
        let second = GuestSessionStore(network: network, defaults: defaults)
        await second.signInIfNeeded()
        let bodies = try recorder.requests.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: String])
        }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertFalse(try XCTUnwrap(bodies.first?["deviceIdentifier"]).isEmpty)
        XCTAssertEqual(bodies[0]["deviceIdentifier"], bodies[1]["deviceIdentifier"])
        XCTAssertFalse(second.isReady)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "GuestSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeNetwork(recorder: GuestRequestRecorder, responses: [String],
                             headers: [String: String] = [:]) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let index = recorder.record(target)
            let json = responses[min(index, responses.count - 1)]
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider, headerProvider: { _ in headers })
    }
}

nonisolated private final class GuestRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [APITarget] = []
    var requests: [APITarget] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func record(_ target: APITarget) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = storage.count
        storage.append(target)
        return index
    }
}
