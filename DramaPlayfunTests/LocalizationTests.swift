import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class LocalizationTests: XCTestCase {
    func testLanguageResolutionMigratesLegacyChineseAndFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), ["en", "zh-Hant"])
        XCTAssertEqual(AppLanguage.allCases.map(\.title), ["English", "繁體中文"])
        XCTAssertEqual(AppLanguage.resolve(saved: "zh", preferredLanguages: ["en"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(saved: "zh-Hans", preferredLanguages: ["en"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(saved: "en", preferredLanguages: ["zh-TW"]), .english)
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["zh-HK"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(saved: "ja", preferredLanguages: ["fr", "en-GB"]), .english)
        XCTAssertEqual(AppLanguage.resolve(saved: nil, preferredLanguages: ["ja"]), .english)
    }

    func testSelectionPersistsAcrossStoreCreation() throws {
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("zh", forKey: AppLanguage.preferenceKey)
        let store = LocalizationStore(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(store.language, .traditionalChinese)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "zh-Hant")
        store.select(.english)
        XCTAssertEqual(LocalizationStore(defaults: defaults, preferredLanguages: ["zh-TW"]).language, .english)
    }

    func testSystemErrorsUseAppLanguageAndServerMessagesRemainIntact() {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        let systemError = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                                  userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed."])
        LocalizationStore.shared.select(.traditionalChinese)
        XCTAssertEqual(L10n.errorMessage(systemError, fallback: "视频加载失败，请重试。"), "影片載入失敗，請重試。")
        XCTAssertEqual(APIError.business(401, "Server detail").appLocalizedDescription,
                       "伺服器傳回業務錯誤 401：Server detail")
        LocalizationStore.shared.select(.english)
        XCTAssertEqual(L10n.errorMessage(systemError, fallback: "视频加载失败，请重试。"), "The video could not load. Please try again.")
    }

    func testBothBundledTablesHaveTheSameKeysAndCompatibleFormatArguments() throws {
        func table(_ language: AppLanguage) throws -> [String: String] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                                   subdirectory: nil, localization: language.rawValue))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let english = try table(.english)
        let chinese = try table(.traditionalChinese)
        XCTAssertGreaterThan(english.count, 100)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let format = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+0 #]*(?:\d+|\*)?(?:\.(?:\d+|\*))?((?:ll|l|z)?[@diufg])"#)
        func arguments(_ value: String) -> [String] {
            format.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range(at: 1), in: value)!])
            }.sorted()
        }
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertFalse(chinese[key]?.isEmpty ?? true, key)
            XCTAssertEqual(arguments(value), arguments(chinese[key] ?? ""), key)
        }
        XCTAssertEqual(L10n.string("设置", language: .english), "Settings")
        XCTAssertEqual(L10n.string("设置", language: .traditionalChinese), "設定")
        XCTAssertEqual(L10n.string("第%d集", language: .english, arguments: [3]), "Episode 3")
        XCTAssertEqual(L10n.string("第%d集", language: .traditionalChinese, arguments: [3]), "第3集")
    }

    func testSettingsNeverRequestsDeprecatedLanguageListAndHeadersFollowSelection() async throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        var paths: [String] = []
        var languages: [String] = []
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            paths.append(target.path)
            languages.append(target.headers?["language"] ?? "")
            XCTAssertEqual(target.requestHeaders.keys.filter { $0.lowercased() == "language" }.count, 1)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, Data(#"{"code":200,"data":{}}"#.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: MoyaProvider.immediatelyStub)
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider, headerProvider: { _ in ["language": "ja", "LANGUAGE": "zh-Hans"] })
        let profile = ProfileStore(network: network)
        LocalizationStore.shared.select(.english)
        await profile.loadSettings()
        LocalizationStore.shared.select(.traditionalChinese)
        await profile.loadSettings()
        XCTAssertEqual(paths, [AppAPI.v1ClientAppConfig.path, AppAPI.v1ClientAppConfig.path])
        XCTAssertEqual(languages, ["en", "zh-Hant"])
    }

    func testLanguageChangeReplacesLocalizedStoresAndPreservesAccountState() throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        LocalizationStore.shared.select(.english)
        let repository = LocalizationTestRepository()
        let app = AppContainer(network: try localizedClient(), repository: repository, defaults: try isolatedDefaults())
        let originalStores = localizedStores(app)
        let network = app.network
        let session = app.guestSession
        let library = app.library
        let membership = app.membership
        let revision = app.contentRevision
        let progress = WatchProgress(dramaID: "1", episodeID: "11", episodeNumber: 1,
                                     seconds: 30, duration: 60, updatedAt: Date())
        library.setFavorite("1", isFavorite: true)
        library.save(progress)

        app.reloadLocalizedContent(for: .english)
        XCTAssertEqual(app.contentRevision, revision)
        for (old, current) in zip(originalStores, localizedStores(app)) { XCTAssertTrue(old === current) }

        LocalizationStore.shared.select(.traditionalChinese)
        app.reloadLocalizedContent(for: .traditionalChinese)
        XCTAssertNotEqual(app.contentRevision, revision)
        for (old, current) in zip(originalStores, localizedStores(app)) { XCTAssertFalse(old === current) }
        XCTAssertTrue(app.network === network)
        XCTAssertTrue(app.guestSession === session)
        XCTAssertTrue(app.library === library)
        XCTAssertTrue(app.membership === membership)
        XCTAssertTrue(app.repository as? LocalizationTestRepository === repository)
        XCTAssertEqual(app.library.favoriteIDs, ["1"])
        XCTAssertEqual(app.library.progress["1"], progress)

        let changedRevision = app.contentRevision
        let changedStores = localizedStores(app)
        app.reloadLocalizedContent(for: .traditionalChinese)
        XCTAssertEqual(app.contentRevision, changedRevision)
        for (old, current) in zip(changedStores, localizedStores(app)) { XCTAssertTrue(old === current) }
    }

    func testLanguageChangeClearsLoadedPagesAndReloadsSameIDsWithNewServerText() async throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        LocalizationStore.shared.select(.english)
        let app = AppContainer(network: try localizedClient(), defaults: try isolatedDefaults())
        await loadLocalizedPages(app)
        XCTAssertEqual(loadedTitles(app), Array(repeating: "English title", count: 10))
        XCTAssertEqual(app.profile.collections[.favorites]?.map(\.id), ["1"])
        XCTAssertEqual(app.wallet.balance, 100)
        XCTAssertTrue(app.welfare.hasLoaded)

        LocalizationStore.shared.select(.traditionalChinese)
        app.reloadLocalizedContent(for: .traditionalChinese)
        XCTAssertTrue(app.profile.collections.isEmpty)
        XCTAssertFalse(app.homeFeed.hasLoaded)
        XCTAssertTrue(app.homeFeed.banners.isEmpty)
        XCTAssertTrue(app.homeFeed.shelves.isEmpty)
        XCTAssertTrue(app.homeFeed.hotDramas.isEmpty)
        XCTAssertFalse(app.homeCategories.hasLoadedTabs)
        XCTAssertTrue(app.homeCategories.pages.isEmpty)
        XCTAssertFalse(app.rankings.hasLoadedTabs)
        XCTAssertTrue(app.rankings.pages.isEmpty)
        XCTAssertTrue(app.wallet.groups.isEmpty)
        XCTAssertNil(app.wallet.balance)
        XCTAssertFalse(app.welfare.hasLoaded)
        XCTAssertTrue(app.welfare.tasks.isEmpty)
        XCTAssertEqual(AppTab.profile.title, "我的")
        XCTAssertEqual(DramaFeedTab.featured.displayTitle, "精選")

        // Normal first-load methods must refetch even when the server IDs are unchanged.
        await loadLocalizedPages(app)
        XCTAssertEqual(loadedTitles(app), Array(repeating: "繁體標題", count: 10))
        XCTAssertEqual(app.profile.collections[.favorites]?.map(\.id), ["1"])
        XCTAssertEqual(app.homeFeed.hotDramas.map(\.id), ["1"])
        XCTAssertEqual(app.homeCategories.selectedPage.dramas.map(\.id), ["1"])
        XCTAssertEqual(app.rankings.selectedPage.dramas.map(\.id), ["1"])
        XCTAssertEqual(app.wallet.balance, 100)
        XCTAssertEqual(app.profile.profile.coinAmount, 100)
    }

    func testOldLanguageResponseCannotPopulateReplacementStore() async throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        LocalizationStore.shared.select(.english)
        let started = expectation(description: "English collection request started")
        let network = try localizedClient(delay: { target in
            if target.headers?["language"] == "en" {
                started.fulfill()
                return .delayed(seconds: 0.5)
            }
            return .immediate
        })
        let app = AppContainer(network: network, defaults: try isolatedDefaults())
        let retiredProfile = app.profile
        let oldRequest = _Concurrency.Task { await retiredProfile.load(.favorites) }
        await fulfillment(of: [started], timeout: 2)

        LocalizationStore.shared.select(.traditionalChinese)
        app.reloadLocalizedContent(for: .traditionalChinese)
        await app.profile.load(.favorites)
        XCTAssertEqual(app.profile.collections[.favorites]?.first?.drama.title, "繁體標題")
        XCTAssertNil(retiredProfile.collections[.favorites])
        await oldRequest.value
        XCTAssertEqual(retiredProfile.collections[.favorites]?.first?.drama.title, "English title")
        XCTAssertEqual(app.profile.collections[.favorites]?.map(\.drama.title), ["繁體標題"])
    }

    func testLanguageChangeClearsDramaRoutesAndKeepsCurrentSettingsDestination() {
        let drama = DemoDramaRepository.dramas[0]
        let router = AppRouter()
        router.selectedTab = .profile
        router.paths = [.home: [.search, .drama(drama)], .theater: [.shortDrama(drama)],
                        .profile: [.drama(drama), .settings]]
        router.openPlayback(drama)
        router.membershipPresented = true

        router.resetForLanguageChange()
        XCTAssertEqual(router.selectedTab, .profile)
        XCTAssertEqual(router.paths, [.profile: [.settings]])
        XCTAssertNil(router.playback)
        XCTAssertFalse(router.membershipPresented)

        router.selectedTab = .home
        router.paths[.home] = [.drama(drama)]
        router.resetForLanguageChange()
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertTrue(router.paths.isEmpty)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func localizedStores(_ app: AppContainer) -> [AnyObject] {
        [app.catalog, app.homeCategories, app.rankings, app.watchHistory, app.homeFeed,
         app.theaterFeed, app.profile, app.wallet, app.welfare, app.theaterPlayback]
    }

    private func loadLocalizedPages(_ app: AppContainer) async {
        await app.profile.load(.favorites)
        await app.homeFeed.loadIfNeeded()
        await app.homeCategories.loadTabsIfNeeded()
        app.homeCategories.selectedID = "tag-1"
        await app.homeCategories.loadSelectedIfNeeded()
        await app.rankings.loadTabsIfNeeded()
        await app.rankings.loadSelectedIfNeeded()
        await app.wallet.load(.recharge)
        await app.wallet.reloadBalance()
        await app.welfare.reload()
    }

    private func loadedTitles(_ app: AppContainer) -> [String?] {
        [app.profile.collections[.favorites]?.first?.drama.title, app.homeFeed.banners.first?.drama.title,
         app.homeFeed.shelves.first?.title, app.homeFeed.hotDramas.first?.title,
         app.homeCategories.tabs.last?.title, app.homeCategories.selectedPage.dramas.first?.title,
         app.rankings.tabs.first?.title, app.rankings.selectedPage.dramas.first?.title,
         app.wallet.groups[.recharge]?.first?.records.first?.title, app.welfare.tasks.first?.title]
    }

    private func localizedClient(delay: @escaping (APITarget) -> StubBehavior = { _ in .immediate }) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let title = target.headers?["language"] == "zh-Hant" ? "繁體標題" : "English title"
            let drama: [String: Any] = ["dramaId": 1, "dramaTitle": title]
            let data: [String: Any]
            switch target.path {
            case AppAPI.v1ClientMeFavorites.path, AppAPI.v1TheaterHomeHotPage.path,
                 AppAPI.v1DramaTagSeriesList.path, AppAPI.v2TheaterRankList.path:
                data = ["list": [drama], "page": 1, "hasMore": false]
            case AppAPI.v1TheaterHome.path:
                data = ["banners": [["id": 1, "dramaTitle": title]],
                        "list": [["categoryName": title, "list": [drama]]]]
            case AppAPI.v1DramaTagList.path:
                data = ["list": [["tagId": 1, "tagName": title]]]
            case AppAPI.v1DramaCategoryList.path:
                data = ["list": [["categoryId": 1, "categoryName": title]]]
            case AppAPI.v1OrderRechargeList.path:
                data = ["total": 1, "list": [["productName": title, "payAmount": 9,
                                              "currency": "USD", "transactionTime": 1789171200000]]]
            case AppAPI.v1WalletInfo.path:
                data = ["balanceCoin": 100]
            case AppAPI.v1WelfareTaskList.path:
                data = ["list": [["taskCode": "watch_drama", "taskName": title]]]
            case AppAPI.v1WelfareSignPopupStatus.path:
                data = ["shouldPopup": false, "hasReceivedToday": false]
            default:
                XCTFail("Unexpected request: \(target.path)")
                data = [:]
            }
            let response = try! JSONSerialization.data(withJSONObject: ["code": 200, "data": data])
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, response) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: delay)
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider)
    }
}

@MainActor
private final class LocalizationTestRepository: DramaRepository {
    func fetchDramas() async throws -> [Drama] { [] }
    func fetchEpisodes(dramaID: Drama.ID) async throws -> [Episode] { [] }
    func playbackURL(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> URL { throw CatalogError.notFound }
}
