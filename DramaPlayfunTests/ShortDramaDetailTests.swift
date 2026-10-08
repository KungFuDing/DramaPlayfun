import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class ShortDramaDetailTests: XCTestCase {
    private func makeStore(response: @escaping (APITarget) -> String) throws -> ShortDramaDetailStore {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let json = response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        let client = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!), provider: provider)
        let app = AppContainer(network: client, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let drama = Drama(id: "101", title: "列表标题", summary: "", category: .all,
            episodeCount: 0, heat: 0, badge: nil, coverURL: nil)
        return ShortDramaDetailStore(drama: drama, app: app)
    }

    func testDetailAndRecommendationContractsAndServerFavoriteState() async throws {
        var favoriteRequests: [Bool] = []
        let store = try makeStore { target in
            let body = try! JSONSerialization.jsonObject(with: target.body) as! [String: Any]
            XCTAssertEqual(body["dramaId"] as? Int, 101)
            switch target.path {
            case "/mobile/v1/client/drama/detail":
                return #"{"code":200,"data":{"drama":{"dramaId":101,"dramaTitle":"接口标题","dramaDesc":"接口简介","episodePassed":68,"tagNames":["剧情","都市"],"isFavorited":true,"favoriteCount":12}}}"#
            case "/mobile/v1/client/drama/guess/like":
                return #"{"code":200,"data":{"list":[{"dramaId":201,"dramaTitle":"推荐甲","badge":"hot"},{"id":202,"dramaTitle":"推荐乙"},{"dramaId":201,"dramaTitle":"重复项"},{"dramaId":203}]}}"#
            case "/mobile/v1/client/drama/favorite":
                let favorite = body["favorite"] as! Bool
                favoriteRequests.append(favorite)
                // The server decides the final state, even when it differs from the request.
                return #"{"code":200,"data":{"isFavorited":false,"favoriteCount":11}}"#
            default: XCTFail("Unexpected endpoint \(target.path)"); return "{}"
            }
        }
        await store.loadDetail()
        await store.loadRecommendations()
        XCTAssertEqual(store.drama.title, "接口标题")
        XCTAssertEqual(store.drama.summary, "接口简介")
        XCTAssertEqual(store.drama.episodeCount, 68)
        XCTAssertTrue(store.isFavorited)
        XCTAssertTrue(store.app.library.favoriteIDs.contains("101"))
        XCTAssertEqual(store.recommendations.map(\.id), ["201", "202"])
        XCTAssertEqual(store.recommendations.first?.displayBadge, "爆款")
        let unfollowed = await store.toggleFavorite()
        XCTAssertTrue(unfollowed)
        let followed = await store.toggleFavorite()
        XCTAssertTrue(followed)
        XCTAssertEqual(favoriteRequests, [false, true])
        XCTAssertFalse(store.isFavorited, "Use server state rather than an optimistic local toggle")
        XCTAssertFalse(store.app.library.favoriteIDs.contains("101"))
        XCTAssertEqual(store.favoriteCount, 11)
    }

    func testFailedRecommendationsAndFavoriteKeepDetailAndFollowState() async throws {
        let store = try makeStore { target in
            if target.path == "/mobile/v1/client/drama/detail" {
                return #"{"code":200,"data":{"drama":{"dramaId":101,"dramaTitle":"正常详情","isFavorited":true,"favoriteCount":12}}}"#
            }
            return #"{"code":403,"message":"操作失败","data":null}"#
        }
        await store.loadDetail()
        await store.loadRecommendations()
        XCTAssertTrue(store.hasDetail)
        XCTAssertNil(store.detailError)
        XCTAssertNotNil(store.recommendationError)
        let succeeded = await store.toggleFavorite()
        XCTAssertFalse(succeeded)
        XCTAssertTrue(store.isFavorited)
        XCTAssertEqual(store.favoriteCount, 12)
        XCTAssertTrue(store.app.library.favoriteIDs.contains("101"))
        XCTAssertNotNil(store.favoriteError)
        XCTAssertFalse(store.isFavoriting)
    }
}
