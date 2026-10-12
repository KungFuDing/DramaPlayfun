import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class ProfileStoreTests: XCTestCase {
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

    func testNewGuestSessionRotatesAndPersistsIdentity() async throws {
        let network = try makeNetwork { _ in #"{"code":200,"data":{"accessToken":"fixture-token"}}"# }
        let name = "ProfileStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("previous-device", forKey: "guest.deviceIdentifier.v1")
        let session = GuestSessionStore(network: network, defaults: defaults)
        await session.signInIfNeeded()
        await session.startNewSession()
        XCTAssertTrue(session.isReady)
        XCTAssertNotEqual(defaults.string(forKey: "guest.deviceIdentifier.v1"), "previous-device")
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
