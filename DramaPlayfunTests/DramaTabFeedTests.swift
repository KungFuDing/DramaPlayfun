import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class DramaTabFeedTests: XCTestCase {
    private func client(response: @escaping (APITarget, [String: Any]) -> String,
                        delay: @escaping (APITarget) -> StubBehavior = { _ in .immediate }) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any] ?? [:]
            let json = response(target, body)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: delay)
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!), provider: provider)
    }

    func testHomeUsesTagIDsAndKeepsPagesSeparate() async throws {
        let network = try client { target, body in
            if target.path == "/mobile/v1/drama/tag/list" {
                return #"{"code":200,"data":{"list":[{"tagId":9,"tagName":"自定义标签"},{"tagId":10,"tagName":"另一标签"},{"tagId":9,"tagName":"重复"}]}}"#
            }
            guard target.path == "/mobile/v1/drama/tag/series/list", body["pageSize"] as? Int == 2 else {
                return #"{"code":500,"data":null}"#
            }
            if body["tagId"] as? Int == 10 {
                return #"{"code":200,"data":{"list":[{"dramaId":10,"dramaTitle":"另一标签剧"}],"hasMore":false}}"#
            }
            guard body["tagId"] as? Int == 9 else { return #"{"code":500,"data":null}"# }
            if body["page"] as? Int == 1 {
                return #"{"code":200,"data":{"list":[{"dramaId":91,"rootDramaId":90,"dramaTitle":"标签剧甲","badge":"new","tagNames":["玄幻"]},{"dramaId":92,"dramaTitle":"标签剧乙"}],"hasMore":true}}"#
            }
            return #"{"code":200,"data":{"list":[{"dramaId":92,"dramaTitle":"重复"},{"dramaId":93,"dramaTitle":"标签剧丙"}],"hasMore":false}}"#
        }
        let feed = DramaTabFeedStore(network: network, source: .homeTags, pageSize: 2)
        await feed.loadTabsIfNeeded()
        XCTAssertEqual(feed.tabs.map(\.title), ["精选", "自定义标签", "另一标签"])
        XCTAssertEqual(feed.selectedID, "featured")
        await feed.loadSelectedIfNeeded()
        XCTAssertTrue(feed.pages.isEmpty)
        feed.selectedID = "tag-9"
        await feed.loadSelectedIfNeeded()
        XCTAssertEqual(feed.selectedPage.dramas.map(\.id), ["91", "92"])
        XCTAssertEqual(feed.selectedPage.dramas.first?.rootDramaID, 90)
        XCTAssertEqual(feed.selectedPage.dramas.first?.displayBadge, "新品")
        await feed.loadMore()
        XCTAssertEqual(feed.selectedPage.dramas.map(\.id), ["91", "92", "93"])
        XCTAssertFalse(feed.selectedPage.hasMore)
        feed.selectedID = "tag-10"
        await feed.loadSelectedIfNeeded()
        XCTAssertEqual(feed.selectedPage.dramas.map(\.id), ["10"])
        feed.selectedID = "tag-9"
        XCTAssertEqual(feed.selectedPage.dramas.map(\.id), ["91", "92", "93"])
        await feed.refreshSelected()
        XCTAssertEqual(feed.selectedPage.page, 1)
        XCTAssertEqual(feed.selectedPage.dramas.map(\.id), ["91", "92"])
    }

    func testRankingsUseRankingTypeCategoryIDAndServerOrder() async throws {
        let network = try client { target, body in
            if target.path == "/mobile/v1/drama/category/list", body["type"] as? String == "ranking" {
                return #"{"code":200,"data":{"list":[{"categoryId":42,"categoryName":"服务端榜单"}]}}"#
            }
            guard target.path == "/mobile/v2/theater/rank/list", body["categoryId"] as? Int == 42,
                  body["pageSize"] as? Int == 2 else { return #"{"code":500,"data":null}"# }
            if body["page"] as? Int == 1 {
                return #"{"code":200,"data":{"list":[{"dramaId":8,"dramaTitle":"榜首"},{"dramaId":2,"dramaTitle":"榜二"}]}}"#
            }
            return #"{"code":200,"data":{"list":[{"dramaId":3,"dramaTitle":"榜三"}]}}"#
        }
        let feed = DramaTabFeedStore(network: network, source: .rankings, pageSize: 2)
        await feed.loadTabsIfNeeded()
        XCTAssertEqual(feed.tabs.map(\.title), ["服务端榜单"])
        XCTAssertEqual(feed.selectedID, "ranking-42")
        await feed.loadSelectedIfNeeded()
        XCTAssertEqual(feed.selectedPage.dramas.map(\.id), ["8", "2"])
        XCTAssertTrue(feed.selectedPage.hasMore)
        await feed.loadMore()
        XCTAssertEqual(feed.selectedPage.dramas.map(\.id), ["8", "2", "3"])
        XCTAssertFalse(feed.selectedPage.hasMore)
    }

    func testRefreshDiscardsOlderTagPagination() async throws {
        let network = try client(response: { target, body in
            if target.path == "/mobile/v1/drama/tag/list" {
                return #"{"code":200,"data":{"list":[{"tagId":1,"tagName":"测试"}]}}"#
            }
            return body["page"] as? Int == 2
                ? #"{"code":200,"data":{"list":[{"dramaId":2,"dramaTitle":"旧分页"}],"hasMore":false}}"#
                : #"{"code":200,"data":{"list":[{"dramaId":1,"dramaTitle":"第一页"}],"hasMore":true}}"#
        }, delay: { target in
            let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
            return body?["page"] == 2 ? .delayed(seconds: 0.25) : .immediate
        })
        let feed = DramaTabFeedStore(network: network, source: .homeTags)
        await feed.loadTabsIfNeeded()
        feed.selectedID = "tag-1"
        await feed.loadSelectedIfNeeded()
        let oldPage = _Concurrency.Task { await feed.loadMore() }
        for _ in 0..<100 where !feed.selectedPage.isLoadingMore { await _Concurrency.Task.yield() }
        XCTAssertTrue(feed.selectedPage.isLoadingMore)
        await feed.refreshSelected()
        await oldPage.value
        XCTAssertEqual(feed.selectedPage.dramas.map(\.id), ["1"])
        XCTAssertEqual(feed.selectedPage.page, 1)
        XCTAssertTrue(feed.selectedPage.hasMore)
        XCTAssertFalse(feed.selectedPage.isLoadingMore)
    }
}
