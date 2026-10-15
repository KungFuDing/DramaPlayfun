import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testConfigurationHasFixedDefaultsBeforeLoading() throws {
        let network = try makeNetwork { _ in #"{"code":200,"data":{}}"# }
        let store = ProfileStore(network: network)

        assertDefaultConfiguration(store)
    }

    func testConfigurationUsesTrimmedRemoteValues() async throws {
        let network = try makeNetwork { target in
            guard target.path == AppAPI.v1ClientAppConfig.path else {
                return #"{"code":200,"data":{}}"#
            }
            return #"{"code":200,"data":{"userAgreementUrl":"  https://example.com/terms  ","privacyPolicyUrl":"\nhttps://example.com/privacy\t","customerServiceEmail":"  support@example.com\n"}}"#
        }
        let store = ProfileStore(network: network)

        await store.loadSettings()

        XCTAssertEqual(store.config.userAgreementUrl, "https://example.com/terms")
        XCTAssertEqual(store.config.privacyPolicyUrl, "https://example.com/privacy")
        XCTAssertEqual(store.config.customerServiceEmail, "support@example.com")
    }

    func testPartialConfigurationFallsBackForEachMissingField() async throws {
        let network = try makeNetwork { target in
            guard target.path == AppAPI.v1ClientAppConfig.path else {
                return #"{"code":200,"data":{}}"#
            }
            return #"{"code":200,"data":{"userAgreementUrl":"https://example.com/terms","privacyPolicyUrl":" \n\t ","customerServiceEmail":null}}"#
        }
        let store = ProfileStore(network: network)

        await store.loadSettings()

        XCTAssertEqual(store.config.userAgreementUrl, "https://example.com/terms")
        XCTAssertEqual(store.config.privacyPolicyUrl, "https://dramaplayfun.com/privacy-policy.html")
        XCTAssertEqual(store.config.customerServiceEmail, "contact@idoltimeltd.co.uk")
    }

    func testConfigurationRejectsURLsWithoutHTTPHost() async throws {
        let responses = [
            #"{"code":200,"data":{"userAgreementUrl":"/terms","privacyPolicyUrl":"javascript:alert(1)","customerServiceEmail":"support@example.com"}}"#,
            #"{"code":200,"data":{"userAgreementUrl":"https:///","privacyPolicyUrl":"file:///privacy","customerServiceEmail":"support@example.com"}}"#,
        ]
        for response in responses {
            let network = try makeNetwork { target in
                target.path == AppAPI.v1ClientAppConfig.path ? response : #"{"code":200,"data":{}}"#
            }
            let store = ProfileStore(network: network)

            await store.loadSettings()

            XCTAssertEqual(store.config.userAgreementUrl, "https://dramaplayfun.com/en/terms-of-use.html")
            XCTAssertEqual(store.config.privacyPolicyUrl, "https://dramaplayfun.com/privacy-policy.html")
            XCTAssertEqual(store.config.customerServiceEmail, "support@example.com")
        }
    }

    func testAbsentOrFailedConfigurationKeepsDefaults() async throws {
        let responses = [
            #"{"code":200,"data":{}}"#,
            #"{"code":200,"data":null}"#,
            #"{"code":200}"#,
            #"{"code":200,"data":{"userAgreementUrl":"","privacyPolicyUrl":null,"customerServiceEmail":" \n\t "}}"#,
            #"{"code":500,"message":"配置获取失败","data":null}"#,
        ]
        for response in responses {
            let network = try makeNetwork { target in
                target.path == AppAPI.v1ClientAppConfig.path ? response : #"{"code":200,"data":{}}"#
            }
            let store = ProfileStore(network: network)

            await store.loadSettings()

            assertDefaultConfiguration(store)
        }
    }

    func testConfigurationRefreshResetsMissingFieldsToDefaults() async throws {
        let responses = ConfigurationResponses([
            #"{"code":200,"data":{"userAgreementUrl":"https://example.com/terms","privacyPolicyUrl":"https://example.com/privacy","customerServiceEmail":"support@example.com"}}"#,
            #"{"code":200,"data":{"customerServiceEmail":"updated@example.com"}}"#,
            #"{"code":200,"data":{}}"#,
        ])
        let network = try makeNetwork { target in
            target.path == AppAPI.v1ClientAppConfig.path ? responses.next() : #"{"code":200,"data":{}}"#
        }
        let store = ProfileStore(network: network)

        await store.loadSettings()
        XCTAssertEqual(store.config.userAgreementUrl, "https://example.com/terms")
        XCTAssertEqual(store.config.privacyPolicyUrl, "https://example.com/privacy")
        XCTAssertEqual(store.config.customerServiceEmail, "support@example.com")

        await store.loadSettings()
        XCTAssertEqual(store.config.userAgreementUrl, "https://dramaplayfun.com/en/terms-of-use.html")
        XCTAssertEqual(store.config.privacyPolicyUrl, "https://dramaplayfun.com/privacy-policy.html")
        XCTAssertEqual(store.config.customerServiceEmail, "updated@example.com")

        await store.loadSettings()
        assertDefaultConfiguration(store)
    }

    func testFavoritesPaginationDeduplicatesAndRefreshReplaces() async throws {
        let network = try makeNetwork { target in
            let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
            if body?["page"] == 2 {
                return #"{"code":200,"data":{"hasMore":false,"list":[{"dramaId":1,"dramaTitle":"甲"},{"dramaId":2,"dramaTitle":"乙"}]}}"#
            }
            return #"{"code":200,"data":{"hasMore":true,"list":[{"dramaId":1,"dramaTitle":"甲"}]}}"#
        }
        let store = ProfileStore(network: network)
        await store.load(.favorites)
        await store.load(.favorites)
        XCTAssertEqual(store.collections[.favorites]?.map(\.id), ["1", "2"])
        XCTAssertEqual(store.hasMore[.favorites], false)
        await store.load(.favorites, refresh: true)
        XCTAssertEqual(store.collections[.favorites]?.map(\.id), ["1"])
    }

    func testFailedDeactivationPreservesAccount() async throws {
        let network = try makeNetwork { target in
            if target.path == AppAPI.v1AuthDeactivate.path {
                return #"{"code":500,"message":"注销失败","data":null}"#
            }
            return #"{"code":200,"data":{"nickname":"晚风","coinAmount":360}}"#
        }
        let store = ProfileStore(network: network)
        await store.reloadProfile()
        do { try await store.deactivate(); XCTFail("注销失败应抛出错误") } catch { }
        XCTAssertEqual(store.nickname, "晚风")
        XCTAssertEqual(store.profile.coinAmount, 360)
    }

    func testDeactivationStartsNewGuestSessionWithoutRotatingDeviceIdentifier() async throws {
        let recorder = ProfileGuestRequestRecorder()
        let network = try makeNetwork { target in
            recorder.record(target)
            return #"{"code":200,"data":{"accessToken":"fixture-token"}}"#
        }
        let name = "ProfileStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("previous-device", forKey: "guest.deviceIdentifier.v1")
        let session = GuestSessionStore(network: network, defaults: defaults,
            deviceIdentifierProvider: ProfileTestDeviceIdentifierProvider())
        let profile = ProfileStore(network: network)
        await session.signInIfNeeded()
        try await profile.deactivate()
        await session.startNewSession()
        XCTAssertTrue(session.isReady)
        XCTAssertNil(session.errorMessage)
        let requests = recorder.requests
        XCTAssertEqual(requests.map(\.path), [AppAPI.v1AuthGuestLogin.path,
            AppAPI.v1AuthDeactivate.path, AppAPI.v1AuthGuestLogin.path])
        for request in requests {
            XCTAssertEqual(request.headers?["deviceId"], "previous-device")
            if request.path == AppAPI.v1AuthGuestLogin.path {
                let login = try JSONDecoder().decode(APIModels.V1GuestLoginReq.self, from: request.body)
                XCTAssertEqual(login.deviceIdentifier, "previous-device")
                XCTAssertNil(request.headers?["Authorization"])
            } else {
                XCTAssertEqual(request.headers?["Authorization"], "Bearer fixture-token")
            }
        }
    }

    private func assertDefaultConfiguration(_ store: ProfileStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.config.userAgreementUrl, "https://dramaplayfun.com/en/terms-of-use.html", file: file, line: line)
        XCTAssertEqual(store.config.privacyPolicyUrl, "https://dramaplayfun.com/privacy-policy.html", file: file, line: line)
        XCTAssertEqual(store.config.customerServiceEmail, "contact@idoltimeltd.co.uk", file: file, line: line)
    }

    private func makeNetwork(response: @escaping @Sendable (APITarget) -> String) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(response(target).utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!), provider: provider)
    }
}

@MainActor
private struct ProfileTestDeviceIdentifierProvider: DeviceIdentifierProviding {
    func identifier() throws -> String { "previous-device" }
}

nonisolated private final class ProfileGuestRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [APITarget] = []

    var requests: [APITarget] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ target: APITarget) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(target)
    }
}

nonisolated private final class ConfigurationResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]

    init(_ responses: [String]) { self.responses = responses }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return responses.isEmpty ? #"{"code":200,"data":{}}"# : responses.removeFirst()
    }
}
