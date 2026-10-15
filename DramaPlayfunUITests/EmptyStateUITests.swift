import XCTest

final class EmptyStateUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEmptySearchKeepsHotDramasAvailableForPlayback() throws {
        let app = launchSearch()
        let field = app.textFields["search-input"]
        field.tap()
        field.typeText(" 不存在 ")
        app.buttons["search-submit"].tap()

        let empty = app.descendants(matching: .any)["search-empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(empty.label, "暫無更多內容")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["network-failure-retry"].exists)
        let hot = app.buttons["search-hot-31"]
        XCTAssertTrue(hot.isHittable)
        capture(app, name: "搜索结果为空")
        hot.tap()
        XCTAssertTrue(app.scrollViews["player-episode-feed"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSearchNetworkFailureRetriesSubmittedKeyword() throws {
        let app = launchSearch(arguments: ["-SearchFailureUITestFixture"])
        let field = app.textFields["search-input"]
        field.tap()
        field.typeText("我以异能斩规则")
        XCTAssertTrue(app.otherElements["search-suggestions"].waitForExistence(timeout: 5),
                      "联想请求不应消耗正式搜索的失败 fixture")
        app.buttons["search-submit"].tap()

        let retry = app.buttons["network-failure-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["網路不穩定，請重試"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["search-empty"].exists)
        capture(app, name: "搜索请求失败")
        retry.tap()

        XCTAssertTrue(app.buttons["search-result-801"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["search-results"].exists)
        XCTAssertEqual(field.value as? String, "我以异能斩规则")
        XCTAssertFalse(retry.exists)
    }

    @MainActor
    func testRankingCategoryFailureRetainsNavigationAndRetries() throws {
        let app = launchRankings(arguments: ["-RankingFailureUITestFixture"])
        assertRankingFailure(app)
        capture(app, name: "排行榜网络请求失败")
        app.buttons["network-failure-retry"].tap()

        XCTAssertTrue(app.staticTexts["榜单测试21"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["日榜"].isSelected)
        XCTAssertFalse(app.descendants(matching: .any)["network-failure-screen"].exists)
        app.buttons["首頁"].tap()
        XCTAssertTrue(app.buttons["home-search"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRankingFirstPageFailureRetriesLoadedCategory() throws {
        let app = launchRankings(arguments: ["-RankingPageFailureUITestFixture"])
        assertRankingFailure(app)
        app.buttons["network-failure-retry"].tap()

        XCTAssertTrue(app.staticTexts["榜单测试21"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["日榜"].isSelected)
        XCTAssertFalse(app.descendants(matching: .any)["network-failure-screen"].exists)
    }

    @MainActor private func launchSearch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SearchUITestFixture"] + arguments
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        XCTAssertTrue(app.buttons["home-search"].waitForExistence(timeout: 10))
        app.buttons["home-search"].tap()
        XCTAssertTrue(app.textFields["search-input"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func launchRankings(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FeedUITestFixture"] + arguments
        app.launchArguments.append(contentsOf: ["-profile.language.v1", "zh-Hant"])
        app.launch()
        let rankings = app.tabBars.buttons["排行榜"]
        XCTAssertTrue(rankings.waitForExistence(timeout: 10))
        rankings.tap()
        return app
    }

    @MainActor private func assertRankingFailure(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["network-failure-screen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["網路不穩定，請重試"].exists)
        XCTAssertTrue(app.buttons["network-failure-retry"].isHittable)
        XCTAssertTrue(app.buttons["首頁"].isHittable)
        XCTAssertTrue(app.buttons["排行榜"].isSelected)
        XCTAssertFalse(app.staticTexts["榜单测试21"].exists)
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
