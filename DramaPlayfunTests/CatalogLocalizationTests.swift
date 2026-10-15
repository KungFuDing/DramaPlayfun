import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class CatalogLocalizationTests: XCTestCase {
    func testExistingDemoModelsUpdateLabelsWithoutChangingIdentity() throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        let drama = try XCTUnwrap(DemoDramaRepository.dramas.first { $0.id == "campus" })
        let identity = drama.hashValue

        LocalizationStore.shared.select(.english)
        XCTAssertEqual(drama.title, "Reborn as the Campus Queen")
        XCTAssertEqual(drama.displayTags, "Live Action")
        XCTAssertEqual(DramaFeedTab.featured.displayTitle, "Featured")

        LocalizationStore.shared.select(.traditionalChinese)
        XCTAssertEqual(drama.title, "重生之我逆襲做校花")
        XCTAssertEqual(drama.summary, "重啟人生，這一次她要為自己贏一次。")
        XCTAssertEqual(drama.displayTags, "真人劇")
        XCTAssertEqual(DramaFeedTab.featured.displayTitle, "精選")
        XCTAssertEqual(drama.hashValue, identity)
        XCTAssertEqual(drama.category.rawValue, "真人剧")
    }

    func testLegacyDramaDecodingPreservesServerContentInBothLanguages() throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        let oldPayload = Data(#"{"id":"campus","title":"服务端剧名","summary":"服务端简介","category":"真人剧","episodeCount":6,"heat":12,"tagNames":["服务端标签"]}"#.utf8)
        let drama = try JSONDecoder().decode(Drama.self, from: oldPayload)
        for language in AppLanguage.allCases {
            LocalizationStore.shared.select(language)
            XCTAssertEqual(drama.title, "服务端剧名")
            XCTAssertEqual(drama.summary, "服务端简介")
            XCTAssertEqual(drama.displayTags, "服务端标签")
        }
        let encoded = try JSONEncoder().encode(drama)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "服务端剧名")
        XCTAssertEqual(object["summary"] as? String, "服务端简介")
        XCTAssertNil(object["storedTitle"])
        XCTAssertNil(object["storedSummary"])
        XCTAssertEqual(try JSONDecoder().decode(Drama.self, from: encoded), drama)
    }

    func testEncodedDemoRemainsLocalizableAfterDecoding() throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        LocalizationStore.shared.select(.english)
        let original = try XCTUnwrap(DemoDramaRepository.dramas.first { $0.id == "palace" })
        let restored = try JSONDecoder().decode(Drama.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.title, "Reborn to Rule the Palace")
        LocalizationStore.shared.select(.traditionalChinese)
        XCTAssertEqual(restored.title, "重生後，我執掌鳳印")
        XCTAssertEqual(restored, original)
    }

    func testGeneratedEpisodeLabelsUpdateAndCustomTitlesRemainIntact() async throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        let episodes = try await DemoDramaRepository().fetchEpisodes(dramaID: "campus")
        let generated = try XCTUnwrap(episodes.first)
        let custom = Episode(id: "custom", number: 1, title: "服务端标题", requiresMembership: false)
        LocalizationStore.shared.select(.english)
        XCTAssertEqual(generated.displayTitle, "Episode 1")
        XCTAssertEqual(custom.displayTitle, "服务端标题")
        LocalizationStore.shared.select(.traditionalChinese)
        XCTAssertEqual(generated.displayTitle, "第1集")
        XCTAssertEqual(custom.displayTitle, "服务端标题")
    }

    func testCachedCatalogAndSearchErrorsFollowLanguageWithoutRetrying() async throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        LocalizationStore.shared.select(.english)
        let catalog = CatalogStore(repository: UnavailableLocalizedCatalog())
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                     sampleResponseClosure: { .networkError(URLError(.notConnectedToInternet) as NSError) },
                     method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: MoyaProvider.immediatelyStub)
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        let search = SearchStore(network: network)
        await catalog.reload()
        await search.loadHistory()
        XCTAssertEqual(catalog.errorMessage, "Series not found. Please refresh and try again.")
        XCTAssertEqual(search.historyError, "Connection failed. Please try again later.")

        LocalizationStore.shared.select(.traditionalChinese)
        XCTAssertEqual(catalog.errorMessage, "找不到此劇集，請重新整理後重試。")
        XCTAssertEqual(search.historyError, "網路連線失敗，請稍後重試。")
    }

}


@MainActor
private struct UnavailableLocalizedCatalog: DramaRepository {
    func fetchDramas() async throws -> [Drama] { throw CatalogError.notFound }
    func fetchEpisodes(dramaID: Drama.ID) async throws -> [Episode] { throw CatalogError.notFound }
    func playbackURL(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> URL { throw CatalogError.notFound }
}
