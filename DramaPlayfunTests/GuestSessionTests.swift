import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class GuestSessionTests: XCTestCase {
    func testLoginUsesOnlyBearerAuthorizationAndRunsOnce() async throws {
        let recorder = GuestRequestRecorder()
        let network = try makeNetwork(recorder: recorder, responses: [
            #"{"code":200,"data":{"accessToken":"new-guest-token"}}"#
        ], headers: ["accessToken": "old-token", "AUTHORIZATION": "Bearer old-token",
                     "appVersion": "1.3.1", "deviceId": "old-debug-device", "DEVICEID": "another-debug-device",
                     "language": "zh-Hans"])
        let defaults = isolatedDefaults()
        let identity = GuestTestDeviceIdentifierProvider("persistent-device")
        let session = GuestSessionStore(network: network, defaults: defaults, deviceIdentifierProvider: identity)
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
        XCTAssertEqual(body["deviceIdentifier"], "persistent-device")
        for request in requests {
            XCTAssertEqual(request.headers?["deviceId"], "persistent-device")
            XCTAssertEqual(request.requestHeaders.keys.filter { $0.lowercased() == "deviceid" }, ["deviceId"])
        }
        XCTAssertEqual(identity.calls, 1)
        XCTAssertFalse(requests[1].requestHeaders.keys.contains { $0.lowercased() == "accesstoken" })
        XCTAssertEqual(requests[1].headers?["Authorization"], "Bearer new-guest-token")
        XCTAssertNil(requests[1].headers?["AUTHORIZATION"])
        XCTAssertEqual(requests[1].headers?["language"], AppLanguage.current.rawValue)
    }

    func testMissingTokenKeepsGateClosedAndCanRetry() async throws {
        let recorder = GuestRequestRecorder()
        let network = try makeNetwork(recorder: recorder, responses: [
            #"{"code":200,"data":{"accessToken":" "}}"#,
            #"{"code":200,"data":{"accessToken":"retry-token"}}"#
        ])
        let session = GuestSessionStore(network: network, defaults: isolatedDefaults(),
            deviceIdentifierProvider: GuestTestDeviceIdentifierProvider("retry-device"))
        await session.signInIfNeeded()
        XCTAssertFalse(session.isReady)
        XCTAssertFalse(session.isLoading)
        XCTAssertNotNil(session.errorMessage)
        await session.signInIfNeeded()
        XCTAssertTrue(session.isReady)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testBusinessFailureAndRecreatedSessionReuseDeviceIdentifier() async throws {
        let recorder = GuestRequestRecorder()
        let network = try makeNetwork(recorder: recorder, responses: [
            #"{"code":500,"message":"unavailable","data":null}"#
        ])
        let defaults = isolatedDefaults()
        let identity = GuestTestDeviceIdentifierProvider("existing-device")
        let first = GuestSessionStore(network: network, defaults: defaults, deviceIdentifierProvider: identity)
        await first.signInIfNeeded()
        XCTAssertFalse(first.isReady)
        XCTAssertNotNil(first.errorMessage)
        let second = GuestSessionStore(network: network, defaults: defaults, deviceIdentifierProvider: identity)
        await second.signInIfNeeded()
        let bodies = try recorder.requests.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: String])
        }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertFalse(try XCTUnwrap(bodies.first?["deviceIdentifier"]).isEmpty)
        XCTAssertEqual(bodies[0]["deviceIdentifier"], bodies[1]["deviceIdentifier"])
        XCTAssertEqual(recorder.requests.map { $0.headers?["deviceId"] }, ["existing-device", "existing-device"])
        XCTAssertFalse(second.isReady)
    }

    func testIdentityFailureSendsNoRequestsAndRetryPreparesIdentityBeforeEncryptionBootstrap() async throws {
        let recorder = GuestRequestRecorder()
        let network = try makeNetwork(recorder: recorder, responses: [
            #"{"code":200,"data":{"enabled":false}}"#,
            #"{"code":200,"data":{"accessToken":"retry-token"}}"#
        ], headers: ["deviceId": "old-debug-device"], usesServerEncryptionConfiguration: true)
        let identity = GuestTestDeviceIdentifierProvider("persistent-device")
        identity.result = .failure(GuestTestIdentityError.unavailable)
        let session = GuestSessionStore(network: network, defaults: isolatedDefaults(),
            deviceIdentifierProvider: identity)

        await session.signInIfNeeded()

        XCTAssertFalse(session.isReady)
        XCTAssertFalse(session.isLoading)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertTrue(recorder.requests.isEmpty, "Identity must be persisted before any bootstrap or login request")

        identity.result = .success("persistent-device")
        await session.signInIfNeeded()

        XCTAssertTrue(session.isReady)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(identity.calls, 2)
        let requests = recorder.requests
        XCTAssertEqual(requests.map(\.path), [AppAPI.v1ClientTransportEncryptionConfig.path, AppAPI.v1AuthGuestLogin.path])
        for request in requests {
            XCTAssertEqual(request.headers?["deviceId"], "persistent-device")
            XCTAssertFalse(request.requestHeaders.keys.contains { $0.lowercased() == "authorization" })
        }
        let login = try XCTUnwrap(requests.last)
        let body = try JSONDecoder().decode(APIModels.V1GuestLoginReq.self, from: login.body)
        XCTAssertEqual(body.deviceIdentifier, "persistent-device")
    }

    func testStaticDeviceIdentifiersAreDiscardedWithoutResolvedIdentity() async throws {
        let recorder = GuestRequestRecorder()
        let network = try makeNetwork(recorder: recorder, responses: [
            #"{"code":200,"data":{"accessToken":"fixture-token"}}"#
        ], headers: ["deviceId": "old-debug-device", "DEVICEID": "uppercase-debug-device"])

        _ = try await network.request(AppAPI.v1AuthGuestLogin,
            body: .init(currentVersion: "1", deviceIdentifier: "body-device"), unwrapEnvelope: true)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertFalse(request.requestHeaders.keys.contains { $0.lowercased() == "deviceid" })
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "GuestSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeNetwork(recorder: GuestRequestRecorder, responses: [String],
                             headers: [String: String] = [:],
                             usesServerEncryptionConfiguration: Bool = false) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let index = recorder.record(target)
            let json = responses[min(index, responses.count - 1)]
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider, usesServerEncryptionConfiguration: usesServerEncryptionConfiguration,
                         headerProvider: { _ in headers })
    }
}

@MainActor
private final class GuestTestDeviceIdentifierProvider: DeviceIdentifierProviding {
    var result: Result<String, Error>
    private(set) var calls = 0

    init(_ identifier: String) { result = .success(identifier) }

    func identifier() throws -> String {
        calls += 1
        return try result.get()
    }
}

nonisolated private enum GuestTestIdentityError: Error {
    case unavailable
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
