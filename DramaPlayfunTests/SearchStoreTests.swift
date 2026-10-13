import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class SearchStoreTests: XCTestCase {
    func testHistoryUsesServerOrderAndClearsOnlyAfterSuccess() async throws {
        var failClear = true
        let store = try makeStore { target in
            if target.path == AppAPI.v1TheaterSearchHistory.path {
                return #"{"code":200,"data":{"list":["  都市  ","重生","都市","", "甜宠"]}}"#
            }
            XCTAssertEqual(target.path, AppAPI.v1TheaterSearchHistoryClear.path)
            XCTAssertEqual((try? JSONSerialization.jsonObject(with: target.body) as? [String: String])?.count, 0)
            return failClear ? #"{"code":500,"message":"清空失败","data":null}"# : #"{"code":200,"data":{}}"#
        }
        await store.loadHistory()
        XCTAssertEqual(store.history, ["都市", "重生", "甜宠"])
        await store.clearHistory()
        XCTAssertEqual(store.history, ["都市", "重生", "甜宠"])
        XCTAssertNotNil(store.historyError)
        failClear = false
        await store.clearHistory()
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNil(store.historyError)
        XCTAssertFalse(store.isClearingHistory)
    }

    func testSearchTrimsKeywordMapsDramaAndPaginatesWithoutDuplicates() async throws {
        var pages: [Int] = []
        let store = try makeStore { target in
            XCTAssertEqual(target.path, AppAPI.v1TheaterSearch.path)
            let body = try! JSONDecoder().decode(APIModels.V1SearchTheaterReq.self, from: target.body)
            XCTAssertEqual(body.keyword, "都市")
            XCTAssertEqual(body.pageSize, 20)
            pages.append(body.page!)
            return body.page == 1
                ? #"{"code":200,"data":{"page":1,"total":2,"list":[{"id":11,"dramaId":12,"rootDramaId":10,"dramaTitle":"重生","dramaDesc":"接口简介","tagNames":["都市","甜宠"],"badge":"new","coverUrl":"https://example.invalid/a.jpg"},{"dramaId":12,"dramaTitle":"重复项"},{"dramaId":13}]}}"#
                : #"{"code":200,"data":{"page":2,"hasMore":false,"list":[{"dramaId":12,"dramaTitle":"重复项"},{"rootDramaId":14,"dramaTitle":"另一部剧","coverUrl":"file:///tmp/a"}]}}"#
        }
        await store.search(" \n都市  ")
        XCTAssertEqual(store.results.map(\.id), ["12"])
        XCTAssertEqual(store.results.first?.rootDramaID, 10)
        XCTAssertEqual(store.results.first?.summary, "接口简介")
        XCTAssertEqual(store.results.first?.tagNames, ["都市", "甜宠"])
        XCTAssertEqual(store.results.first?.displayBadge, "新品")
        XCTAssertEqual(store.results.first?.coverURL?.absoluteString, "https://example.invalid/a.jpg")
        XCTAssertEqual(store.history, ["都市"])
        XCTAssertTrue(store.hasMore)
        await store.loadMore()
        XCTAssertEqual(store.results.map(\.id), ["12", "14"])
        XCTAssertNil(store.results.last?.coverURL)
        XCTAssertFalse(store.hasMore)
        await store.loadMore()
        XCTAssertEqual(pages, [1, 2])
    }

    func testOlderSuggestionCannotReplaceNewInputOrCreateHistory() async throws {
        let started = expectation(description: "Older suggestion requested")
        let store = try makeStore(response: { target in
            XCTAssertEqual(target.path, AppAPI.v1TheaterSearchGuess.path)
            let keyword = self.keyword(target)
            if keyword == "旧" { started.fulfill() }
            return "{\"code\":200,\"data\":{\"list\":[{\"dramaId\":1,\"dramaTitle\":\"\(keyword)\"}]}}"
        }, delay: { self.keyword($0) == "旧" ? 0.2 : 0 })
        let old = _Concurrency.Task { await store.suggest("旧", debounce: .zero) }
        await fulfillment(of: [started], timeout: 2)
        await store.suggest("新", debounce: .zero)
        await old.value
        XCTAssertEqual(store.suggestions.map(\.title), ["新"])
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(store.isLoadingSuggestions)
    }

    func testNewSearchDiscardsAnOlderPaginationResponse() async throws {
        let started = expectation(description: "Older page started")
        let store = try makeStore(response: { target in
            let body = try! JSONDecoder().decode(APIModels.V1SearchTheaterReq.self, from: target.body)
            if body.page == 2 { started.fulfill() }
            let id = body.keyword == "新" ? 20 : body.page!
            return "{\"code\":200,\"data\":{\"hasMore\":\(body.keyword == "旧"),\"list\":[{\"dramaId\":\(id),\"dramaTitle\":\"\(body.keyword)\"}]}}"
        }, delay: { target in
            let body = try! JSONDecoder().decode(APIModels.V1SearchTheaterReq.self, from: target.body)
            return body.page == 2 ? 0.2 : 0
        })
        await store.search("旧")
        let olderPage = _Concurrency.Task { await store.loadMore() }
        await fulfillment(of: [started], timeout: 2)
        await store.search("新")
        await olderPage.value
        XCTAssertEqual(store.results.map(\.id), ["20"])
        XCTAssertEqual(store.history, ["新", "旧"])
        XCTAssertFalse(store.hasMore)
        XCTAssertFalse(store.isLoadingMore)
    }

    func testCancellationDuringDebounceAndEmptyInputSendNoRequests() async throws {
        let store = try makeStore { _ in XCTFail("No request should be sent"); return "{}" }
        let pending = _Concurrency.Task { await store.suggest("都市", debounce: .seconds(5)) }
        await _Concurrency.Task<Never, Never>.yield()
        pending.cancel()
        await pending.value
        await store.search(" \n ")
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertTrue(store.suggestions.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNil(store.searchError)
        XCTAssertFalse(store.isLoadingSuggestions)
    }

    func testFailedSearchDoesNotCreateHistoryAndCanRetry() async throws {
        var fail = true
        let store = try makeStore { _ in
            fail ? #"{"code":500,"message":"搜索失败","data":null}"#
                 : #"{"code":200,"data":{"list":[],"hasMore":false}}"#
        }
        await store.search("关键词")
        XCTAssertNotNil(store.searchError)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(store.isSearching)
        fail = false
        await store.search("关键词")
        XCTAssertNil(store.searchError)
        XCTAssertEqual(store.history, ["关键词"])
        XCTAssertFalse(store.hasMore)
    }

    func testClearDiscardsAnOlderHistoryResponse() async throws {
        let started = expectation(description: "History request started")
        let store = try makeStore(response: { target in
            if target.path == AppAPI.v1TheaterSearchHistory.path {
                started.fulfill()
                return #"{"code":200,"data":{"list":["旧记录"]}}"#
            }
            return #"{"code":200,"data":{}}"#
        }, delay: { $0.path == AppAPI.v1TheaterSearchHistory.path ? 0.2 : 0 })
        let old = _Concurrency.Task { await store.loadHistory() }
        await fulfillment(of: [started], timeout: 2)
        await store.clearHistory()
        await old.value
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(store.isLoadingHistory)
    }

    private func keyword(_ target: APITarget) -> String {
        ((try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any])?["keyword"] as? String ?? ""
    }

    private func makeStore(response: @escaping (APITarget) -> String,
                           delay: @escaping (APITarget) -> TimeInterval = { _ in 0 }) throws -> SearchStore {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let json = response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { target in
            let seconds = delay(target)
            return seconds > 0 ? .delayed(seconds: seconds) : .immediate
        })
        return SearchStore(network: APIClient(
            configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!), provider: provider))
    }
}
