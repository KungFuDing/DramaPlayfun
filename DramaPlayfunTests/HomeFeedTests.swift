import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class HomeFeedTests: XCTestCase {
    func testHomeSectionsFollowResponseAndHotPagesAppend() async throws {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let json: String
            if target.path == "/mobile/v1/theater/home" {
                json = #"{"code":200,"data":{"banners":[{"id":11,"dramaTitle":"推荐剧","bannerImage":"https://example.invalid/banner.jpg"}],"list":[{"categoryName":"专题甲","list":[{"dramaId":21,"dramaTitle":"短剧甲","coverUrl":"https://example.invalid/a.jpg","tagNames":["都市"]}]},{"categoryName":"专题乙","list":[{"dramaId":22,"dramaTitle":"短剧乙"}]}]},"message":"ok"}"#
            } else {
                let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
                json = body?["page"] == 1
                    ? #"{"code":200,"data":{"page":1,"hasMore":true,"list":[{"id":31,"dramaId":31,"dramaTitle":"热门甲","dramaDesc":"剧情简介","badge":"hot","coverUrl":"https://example.invalid/cover.jpg","tagNames":["甜宠"]}]},"message":"ok"}"#
                    : #"{"code":200,"data":{"page":2,"hasMore":false,"list":[{"dramaId":32,"dramaTitle":"热门乙","badge":""}]},"message":"ok"}"#
            }
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        let feed = HomeFeedStore(network: network)

        await feed.loadIfNeeded()
        XCTAssertEqual(feed.banners.map(\.drama.title), ["推荐剧"])
        XCTAssertEqual(feed.banners.first?.imageURL?.absoluteString, "https://example.invalid/banner.jpg")
        XCTAssertEqual(feed.shelves.map(\.title), ["专题甲", "专题乙"])
        XCTAssertEqual(feed.shelves.first?.dramas.first?.displayTags, "都市")
        XCTAssertEqual(feed.hotDramas.map(\.id), ["31"])
        XCTAssertEqual(feed.hotDramas.first?.summary, "剧情简介")
        XCTAssertEqual(feed.hotDramas.first?.displayBadge, "爆款")
        XCTAssertEqual(feed.hotDramas.first?.coverURL?.absoluteString, "https://example.invalid/cover.jpg")
        XCTAssertTrue(feed.hasMoreHot)

        await feed.loadMore()
        XCTAssertEqual(feed.hotDramas.map(\.id), ["31", "32"])
        XCTAssertNil(feed.hotDramas.last?.displayBadge)
        XCTAssertFalse(feed.hasMoreHot)
    }

    func testHotPageStillLoadsWhenHomeAggregationFails() async throws {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let isHome = target.path == "/mobile/v1/theater/home"
            let json = isHome ? #"{"code":500,"data":null,"message":"home unavailable"}"#
                : #"{"code":200,"data":{"page":1,"hasMore":false,"list":[{"dramaId":143,"dramaTitle":"医仙归来之玩转江城","tagNames":["年代","脑洞","玄幻"]}]},"message":"ok"}"#
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        let feed = HomeFeedStore(network: network)

        await feed.reload()
        XCTAssertNotNil(feed.homeErrorMessage)
        XCTAssertNil(feed.hotErrorMessage)
        XCTAssertEqual(feed.hotDramas.map(\.id), ["143"])
        XCTAssertEqual(feed.hotDramas.first?.displayTags, "年代 · 脑洞 · 玄幻")
    }

    func testRefreshDiscardsAnOlderLoadMoreResponse() async throws {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let page = ((try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int])?["page"]
            let json: String
            if target.path == "/mobile/v1/theater/home" {
                json = #"{"code":200,"data":{"banners":[],"list":[]},"message":"ok"}"#
            } else if page == 2 {
                json = #"{"code":200,"data":{"page":2,"hasMore":false,"list":[{"dramaId":2,"dramaTitle":"旧分页"}]},"message":"ok"}"#
            } else {
                json = #"{"code":200,"data":{"page":1,"hasMore":true,"list":[{"dramaId":1,"dramaTitle":"当前剧集"}]},"message":"ok"}"#
            }
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { target in
            let page = ((try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int])?["page"]
            return page == 2 ? .delayed(seconds: 0.25) : .immediate
        })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        let feed = HomeFeedStore(network: network)

        await feed.reload()
        let oldPage = _Concurrency.Task { await feed.loadMore() }
        for _ in 0..<100 where !feed.isLoadingMore { await _Concurrency.Task.yield() }
        XCTAssertTrue(feed.isLoadingMore)

        await feed.reload()
        await oldPage.value
        XCTAssertEqual(feed.hotDramas.map(\.id), ["1"])
        XCTAssertTrue(feed.hasMoreHot)
        XCTAssertFalse(feed.isLoadingMore)
    }
}
