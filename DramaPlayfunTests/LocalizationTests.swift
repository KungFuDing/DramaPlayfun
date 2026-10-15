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
}
